;;; decknix-support-dashboard.el --- Live support monitoring dashboard -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Keywords: decknix, support, techops, dashboard

;;; Commentary:
;;
;; A deterministic, script-fed "live monitoring dashboard" for the TechOps /
;; on-support rotation — no LLM required, so it is cheap and reliable to leave
;; open all day.  It polls the DoS Jira board (the rotation's worklist) via the
;; `atlassian-cli' binary and renders it into a read-only buffer that
;; auto-refreshes on a timer while displayed.
;;
;; Design: the parse/format/render layer is PURE (JSON string in, display
;; string out) so it is fully ERT-testable without a live Jira or a live
;; buffer.  The async fetch and the auto-refresh timer are the only
;; side-effecting parts; the timer itself is armed from the agent-shell
;; heredoc (AGENTS.md Rule 2).
;;
;; Additional data sources (weekly Techops report status, alert feed) are meant
;; to be added as further pure section-renderers composed into
;; `decknix--support-dashboard-render'.

;;; Code:

(require 'subr-x)
(require 'cl-lib)
(require 'seq)
(require 'transient)

(defvar decknix-support-dashboard-buffer-name "*decknix-support*"
  "Name of the support monitoring dashboard buffer.")

(defvar decknix-support-dashboard-status-order
  '("In Progress" "In Review" "Blocked" "To Do" "Selected for Development"
    "Backlog")
  "Preferred display order for status groups.
Statuses not listed here sort after the listed ones, alphabetically — so the
work you are actively on (In Progress) leads the board and the backlog trails.")

(defvar decknix-support-dashboard-atlassian-cli "atlassian-cli"
  "The atlassian-cli executable used to fetch Jira data.")

(defvar decknix-support-dashboard-jql
  "project = DOS AND statusCategory != Done ORDER BY status ASC, updated DESC"
  "JQL for the DoS worklist shown in the dashboard (open/in-progress issues).")

(defvar decknix-support-dashboard-limit 40
  "Maximum number of DoS issues to fetch.")

(defvar decknix-support-dashboard-jira-base-url "https://vmxproperty.atlassian.net"
  "Base Atlassian URL; `/browse/<KEY>' is appended to open an issue.")

(defvar decknix-support-dashboard-alert-response-command
  "/nc-alert-response:alert-response"
  "Agent slash-command that investigates an alert and comments on its ticket.
Referenced (as text) in the alert investigation prompt; override per workspace.")

(defvar decknix-support-dashboard-confluence-space "TechOps"
  "Confluence space key holding the weekly Techops report.")

(defvar decknix-support-dashboard-report-title-match "Weekly Techops Report"
  "Substring identifying the weekly report pages (titles are dated, e.g.
\"2026-07-28: Weekly Techops Report\").  The newest matching page is the
current week's report, so it resolves with zero weekly maintenance.")

(defvar decknix-support-dashboard-report-page-id nil
  "Explicit Confluence page id for the weekly report.
When nil (default) the current report is resolved by title via CQL (newest
matching `decknix-support-dashboard-report-title-match').  Set this to pin a
specific page.")

(defvar-local decknix--support-dashboard-issues nil
  "Last-fetched DoS issues, cached so status filtering redraws without re-fetch.")
(defvar-local decknix--support-dashboard-alerts nil
  "Last-fetched alerts, cached alongside the issues.")
(defvar-local decknix--support-dashboard-status-filter nil
  "When non-nil, only issues whose status equals this string are shown.")
(defvar-local decknix--support-dashboard-issues-err nil)
(defvar-local decknix--support-dashboard-alerts-err nil)
(defvar-local decknix--support-dashboard-updated nil)

(defvar decknix-support-dashboard-refresh-interval 120
  "Seconds between auto-refreshes while the dashboard buffer is displayed.")

;; ---------------------------------------------------------------------------
;; Pure layer (JSON string -> display string) — ERT-tested.
;; ---------------------------------------------------------------------------

(defun decknix--support-dashboard-parse (json-string)
  "Parse atlassian-cli JSON output JSON-STRING into a list of issue alists.
Handles a bare array (the default) and the `--envelope' {\"data\":[...]} form.
Returns nil for blank or invalid input rather than signalling, so a transient
CLI hiccup degrades to an empty dashboard instead of an error."
  (when (and (stringp json-string) (not (string-blank-p json-string)))
    (condition-case nil
        (let ((data (json-parse-string json-string
                                       :object-type 'alist
                                       :array-type 'list
                                       :null-object nil)))
          (if (and (consp data) (assq 'data data)
                   (listp (alist-get 'data data)))
              (alist-get 'data data)   ; envelope
            data))                     ; bare array (list of alists)
      (error nil))))

(defun decknix--support-dashboard-format-issue (issue)
  "Format one ISSUE alist into a fixed-width dashboard row string.
The row carries the issue key as the `decknix-issue-key' text property so
row-action commands (browse, assign, investigate) can target the row at point."
  (let* ((key      (or (alist-get 'key issue) "?"))
         (status   (or (alist-get 'status issue) ""))
         (assignee (or (alist-get 'assignee issue) "unassigned"))
         (summary  (or (alist-get 'summary issue) ""))
         (row (format "%-9s  %-13s  %-16s  %s"
                      key
                      (format "[%s]" status)
                      (truncate-string-to-width assignee 16)
                      summary)))
    (propertize row 'decknix-issue-key key)))

(defun decknix--support-dashboard-alert-prompt (key summary command browse-url)
  "Build the alert-investigation prompt for issue KEY (SUMMARY).
COMMAND is the alert-response slash-command; BROWSE-URL is the issue link.
Encodes the Playbook alert workflow: triage/investigate, comment on the
ticket, and the reminder that resolving the Jira ticket does NOT resolve the
GCP alert.  Pure -- returns the prompt string."
  (format (concat "%s %s\n\n"
                  "Investigate alert %s: %s\n"
                  "Open %s. Triage and diagnose the alert, determine impact "
                  "(outage / broken functionality / noise / recoverable?), and "
                  "post your findings as a comment on the ticket. Propose a "
                  "root-cause fix (not a silence). If it depends on other work, "
                  "mark it Blocked. Reminder: resolving the Jira ticket does NOT "
                  "resolve the GCP alert — resolve it in the GCP console too.")
          command key key (or summary "") browse-url))

(defun decknix--support-dashboard-group-by-status (issues)
  "Group ISSUES into a list of (STATUS . ISSUE-LIST) cells.
Cells are ordered by `decknix-support-dashboard-status-order' then
alphabetically; issues within a group keep their input order.  Pure."
  (let ((groups nil))
    (dolist (i issues)
      (let* ((s (or (alist-get 'status i) "Unknown"))
             (cell (assoc s groups)))
        (if cell
            (setcdr cell (cons i (cdr cell)))
          (push (cons s (list i)) groups))))
    (setq groups (mapcar (lambda (g) (cons (car g) (nreverse (cdr g)))) groups))
    (sort groups
          (lambda (a b)
            (let ((ia (cl-position (car a) decknix-support-dashboard-status-order
                                   :test #'equal))
                  (ib (cl-position (car b) decknix-support-dashboard-status-order
                                   :test #'equal)))
              (cond ((and ia ib) (< ia ib))
                    (ia t)
                    (ib nil)
                    (t (string< (car a) (car b)))))))))

(defun decknix--support-dashboard-render (issues &optional timestamp)
  "Render ISSUES (a list of issue alists) into the dashboard's buffer text.
Issues are grouped by status (In Progress first) with a per-group count header.
TIMESTAMP is an optional display string appended to the footer; when nil it is
omitted, which keeps this function pure for tests."
  (concat
   "NurtureCloud Support — DoS Board\n"
   (make-string 64 ?-) "\n"
   (if (null issues)
       "  (no open DoS issues)\n"
     (mapconcat
      (lambda (group)
        (concat (format "\n%s (%d)\n" (car group) (length (cdr group)))
                (mapconcat #'decknix--support-dashboard-format-issue
                           (cdr group) "\n")
                "\n"))
      (decknix--support-dashboard-group-by-status issues)
      ""))
   "\n"
   (format "%d open%s\n"
           (length issues)
           (if (and timestamp (not (string-empty-p timestamp)))
               (concat "   ·   updated " timestamp)
             ""))))

;; ---------------------------------------------------------------------------
;; Alert feed (Slack #nurturecloud-doit-collab) — pure parse/format/render.
;; ---------------------------------------------------------------------------
;;
;; The alert source is a command whose stdout is the Slack MCP
;; `conversations_history' CSV (first line `OK ...: <header>', then one row per
;; message; column order is fixed by the MCP: index 6 Text, 7 Time, 9 BotName).
;; Left nil in decknix (generic); a workspace sets it — see the module's
;; `decknix-support-dashboard-alert-command'.

(defvar decknix-support-dashboard-alert-command nil
  "Command (list of program + args) whose stdout is the Slack alert CSV.
When nil the alert feed is disabled and shown as not-configured — decknix stays
generic; a workspace (e.g. decknix-config) points this at its Slack MCP helper
and channel.  Example value:
  (list \"/path/to/slack-mcp-call.py\" \"conversations_history\"
        \"{\\\"channel_id\\\":\\\"C08A5P8PN2G\\\",\\\"limit\\\":\\\"8\\\"}\")")

(defun decknix--support-dashboard-parse-csv-line (line)
  "Parse a single CSV LINE into a list of fields.
Handles double-quoted fields with embedded commas and doubled \"\" escapes
\(RFC4180-ish), which the Slack MCP uses when a message contains commas."
  (let ((fields nil) (field "") (i 0) (n (length line)) (in-quote nil))
    (while (< i n)
      (let ((c (aref line i)))
        (cond
         (in-quote
          (cond
           ((and (eq c ?\") (< (1+ i) n) (eq (aref line (1+ i)) ?\"))
            (setq field (concat field "\"") i (1+ i)))
           ((eq c ?\") (setq in-quote nil))
           (t (setq field (concat field (char-to-string c))))))
         ((eq c ?\") (setq in-quote t))
         ((eq c ?,) (push field fields) (setq field ""))
         (t (setq field (concat field (char-to-string c)))))
        (setq i (1+ i))))
    (push field fields)
    (nreverse fields)))

(defun decknix--support-dashboard-parse-alerts (output)
  "Parse Slack conversations_history OUTPUT (CSV) into alert alists.
Drops the leading `OK ...: header' line; each alert carries `text', `time',
`bot'.  Degrades to nil on blank input or rows too short to hold a message."
  (when (and (stringp output) (not (string-blank-p output)))
    (let ((data (cdr (split-string output "\n" t))))  ; drop header line
      (delq nil
            (mapcar
             (lambda (line)
               (let ((f (decknix--support-dashboard-parse-csv-line line)))
                 (when (> (length f) 7)
                   (list (cons 'text (nth 6 f))
                         (cons 'time (nth 7 f))
                         (cons 'bot  (nth 9 f))))))
             data)))))

(defun decknix--support-dashboard-format-alert (alert)
  "Format one ALERT alist into a `HH:MM  text' row."
  (let* ((time (or (alist-get 'time alert) ""))
         (hhmm (if (string-match "T\\([0-9][0-9]:[0-9][0-9]\\)" time)
                   (match-string 1 time)
                 (truncate-string-to-width time 5)))
         (text (string-trim (or (alist-get 'text alert) ""))))
    (format "  %-5s  %s" hhmm text)))

(defun decknix--support-dashboard-render-alerts (alerts)
  "Render ALERTS (a list of alert alists) into the alert-feed section text."
  (concat "\nAlerts — #nurturecloud-doit-collab\n"
          (make-string 64 ?-) "\n"
          (if (null alerts)
              "  (no recent alerts)\n"
            (concat (mapconcat #'decknix--support-dashboard-format-alert
                               alerts "\n")
                    "\n"))))

(defun decknix--support-dashboard-render-full (issues issues-err alerts alerts-err
                                                      &optional timestamp)
  "Compose the full dashboard text: DoS section, alert section, timestamp.
Reuses `decknix--support-dashboard-render' for the DoS part (no refactor).
ISSUES-ERR / ALERTS-ERR render an error line for their section instead."
  (concat
   (if issues-err
       (format "NurtureCloud Support — DoS Board\n%s\nError: %s\n"
               (make-string 64 ?-) issues-err)
     (decknix--support-dashboard-render issues nil))
   (cond
    ((eq alerts-err 'unconfigured)
     (concat "\nAlerts — #nurturecloud-doit-collab\n" (make-string 64 ?-)
             "\n  (alert feed not configured)\n"))
    (alerts-err
     (format "\nAlerts — #nurturecloud-doit-collab\n%s\nError: %s\n"
             (make-string 64 ?-) alerts-err))
    (t (decknix--support-dashboard-render-alerts alerts)))
   (if (and timestamp (not (string-empty-p timestamp)))
       (format "\n%d open · %d alerts   ·   updated %s\n"
               (length issues) (length alerts) timestamp)
     "")))

;; ---------------------------------------------------------------------------
;; Weekly Techops report (Confluence) — pure resolve/draft, ERT-tested.
;; ---------------------------------------------------------------------------
;;
;; The current week's report is the newest page whose title matches
;; `decknix-support-dashboard-report-title-match' (titles are dated,
;; e.g. "2026-07-28: Weekly Techops Report"), resolved via CQL so there is
;; nothing to update week to week.  The draft daily-log entry is generated from
;; the live dashboard state and shown for review — never written silently.

(defun decknix--support-dashboard-title-date (title)
  "Return the leading YYYY-MM-DD date in TITLE as a sortable string, or nil."
  (when (and (stringp title)
             (string-match "\\`\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" title))
    (match-string 1 title)))

(defun decknix--support-dashboard-pick-report-page (pages)
  "Pick the current weekly report from PAGES (parsed CQL result alists).
Keeps only pages whose title contains
`decknix-support-dashboard-report-title-match', then returns the one with the
newest leading date (falling back to input order, which CQL already sorts
newest-first).  Returns the page alist (with `id' and `title') or nil.  Pure."
  (let ((matches
         (seq-filter
          (lambda (p)
            (let ((title (or (alist-get 'title p) "")))
              (string-match-p
               (regexp-quote decknix-support-dashboard-report-title-match) title)))
          pages)))
    (car
     (seq-sort
      (lambda (a b)
        (let ((da (decknix--support-dashboard-title-date (alist-get 'title a)))
              (db (decknix--support-dashboard-title-date (alist-get 'title b))))
          (cond ((and da db) (string> da db))
                (da t)
                (db nil)
                (t nil))))          ; stable: keep CQL's newest-first order
      matches))))

(defun decknix--support-dashboard-report-url (id)
  "Return the Confluence web URL for page ID."
  (format "%s/wiki/spaces/%s/pages/%s"
          (string-trim-right decknix-support-dashboard-jira-base-url "/")
          decknix-support-dashboard-confluence-space
          id))

(defun decknix--support-dashboard-daily-log-draft (issues alerts date)
  "Build a reviewable daily-log entry (Confluence wiki markup) from live state.
ISSUES and ALERTS are the cached dashboard data; DATE is a YYYY-MM-DD string.
Pure: no I/O, so it is fully ERT-testable.  The blank Service Health / Actions /
Follow-ups lines are intentional prompts for the reviewer to fill in."
  (let ((groups (decknix--support-dashboard-group-by-status issues)))
    (concat
     (format "h3. %s — Daily update (on-support)\n\n" date)
     "*Service Health:* (checked — note anomalies, else \"all nominal\")\n\n"
     (format "*DoS board:* %d open\n" (length issues))
     (if (null groups)
         "  (none)\n"
       (mapconcat
        (lambda (g)
          (format "  %s (%d): %s\n"
                  (car g) (length (cdr g))
                  (mapconcat (lambda (i) (or (alist-get 'key i) "?"))
                             (cdr g) ", ")))
        groups ""))
     (format "\n*Alerts:* %d recent\n" (length alerts))
     (if (null alerts)
         "  (none)\n"
       (concat (mapconcat #'decknix--support-dashboard-format-alert alerts "\n")
               "\n"))
     "\n*Actions taken:*\n-\n"
     "\n*Follow-ups / next:*\n-\n")))

;; ---------------------------------------------------------------------------
;; Side-effecting layer: async fetch + buffer refresh + command.
;; ---------------------------------------------------------------------------

(defun decknix--support-dashboard-fetch (callback)
  "Fetch the DoS worklist asynchronously; call CALLBACK with (ISSUES . ERR).
CALLBACK receives the parsed ISSUES list (nil on failure) and an ERR string
\(nil on success).  Never blocks the UI: runs `atlassian-cli' via `make-process'."
  (if (not (executable-find decknix-support-dashboard-atlassian-cli))
      (funcall callback nil
               (format "%s not found on PATH" decknix-support-dashboard-atlassian-cli))
    (let ((buf (generate-new-buffer " *decknix-support-fetch*")))
      (make-process
       :name "decknix-support-jira"
       :buffer buf
       :noquery t
       :connection-type 'pipe
       :command (list decknix-support-dashboard-atlassian-cli
                      "--format" "json" "jira" "issue" "search"
                      "--jql" decknix-support-dashboard-jql
                      "--limit" (number-to-string decknix-support-dashboard-limit))
       :sentinel
       (lambda (proc _event)
         (when (memq (process-status proc) '(exit signal))
           (let* ((out (and (buffer-live-p buf)
                            (with-current-buffer buf (buffer-string))))
                  (ok (and (eq (process-status proc) 'exit)
                           (= 0 (process-exit-status proc)))))
             (when (buffer-live-p buf) (kill-buffer buf))
             (funcall callback
                      (and ok (decknix--support-dashboard-parse out))
                      (unless ok (string-trim (or out "fetch failed")))))))))))

(defun decknix--support-dashboard-fetch-alerts (callback)
  "Fetch recent alerts asynchronously; call CALLBACK with (ALERTS ERR).
ERR is the symbol `unconfigured' when `decknix-support-dashboard-alert-command'
is nil, or an error string on failure.  Never blocks the UI."
  (let ((cmd decknix-support-dashboard-alert-command))
    (cond
     ((null cmd) (funcall callback nil 'unconfigured))
     ((not (executable-find (car cmd)))
      (funcall callback nil (format "%s not found" (car cmd))))
     (t
      (let ((buf (generate-new-buffer " *decknix-support-alerts*")))
        (make-process
         :name "decknix-support-alerts"
         :buffer buf
         :noquery t
         :connection-type 'pipe
         :command cmd
         :sentinel
         (lambda (proc _event)
           (when (memq (process-status proc) '(exit signal))
             (let* ((out (and (buffer-live-p buf)
                              (with-current-buffer buf (buffer-string))))
                    (ok (and (eq (process-status proc) 'exit)
                             (= 0 (process-exit-status proc)))))
               (when (buffer-live-p buf) (kill-buffer buf))
               (funcall callback
                        (and ok (decknix--support-dashboard-parse-alerts out))
                        (unless ok (string-trim (or out "alert fetch failed")))))))))))))

(defun decknix--support-dashboard-redraw ()
  "Re-render the dashboard buffer from cached data, applying the status filter.
Assumes `current-buffer' is the dashboard buffer.  Client-side, so filtering
never re-hits Jira."
  (let* ((filter decknix--support-dashboard-status-filter)
         (issues (if filter
                     (seq-filter (lambda (i)
                                   (equal filter (alist-get 'status i)))
                                 decknix--support-dashboard-issues)
                   decknix--support-dashboard-issues))
         (inhibit-read-only t)
         (pos (point)))
    (erase-buffer)
    (insert (decknix--support-dashboard-render-full
             issues decknix--support-dashboard-issues-err
             decknix--support-dashboard-alerts
             decknix--support-dashboard-alerts-err
             decknix--support-dashboard-updated))
    (when filter
      (insert (format "\n[filtered: status = %s — press / to clear]\n" filter)))
    (goto-char (min pos (point-max)))))

(defun decknix-support-dashboard-refresh ()
  "Refresh the dashboard from the DoS board and the alert feed (async).
Fetches issues, then alerts, caches both, then redraws; neither fetch blocks."
  (interactive)
  (let ((target (get-buffer-create decknix-support-dashboard-buffer-name)))
    (decknix--support-dashboard-fetch
     (lambda (issues issues-err)
       (decknix--support-dashboard-fetch-alerts
        (lambda (alerts alerts-err)
          (when (buffer-live-p target)
            (with-current-buffer target
              (setq decknix--support-dashboard-issues issues
                    decknix--support-dashboard-issues-err issues-err
                    decknix--support-dashboard-alerts alerts
                    decknix--support-dashboard-alerts-err alerts-err
                    decknix--support-dashboard-updated (format-time-string "%H:%M:%S"))
              (decknix--support-dashboard-redraw)))))))))

(defun decknix--support-dashboard-visible-p ()
  "Return non-nil when the dashboard buffer exists and is displayed."
  (let ((buf (get-buffer decknix-support-dashboard-buffer-name)))
    (and buf (get-buffer-window buf t) t)))

(defun decknix--support-dashboard-tick ()
  "Auto-refresh entry point: refresh only while the dashboard is displayed.
Cheap when hidden (a single window lookup), so it is safe to run on a timer."
  (when (decknix--support-dashboard-visible-p)
    (decknix-support-dashboard-refresh)))

;; ---------------------------------------------------------------------------
;; Row actions + mode/keymap/transient (the support "submenu").
;; ---------------------------------------------------------------------------

(defun decknix-support-dashboard-issue-key-at-point ()
  "Return the DoS issue key on the current row, or nil."
  (get-text-property (point) 'decknix-issue-key))

(defun decknix--support-dashboard-issue-at-point ()
  "Return the cached issue alist for the row at point, or nil."
  (let ((key (decknix-support-dashboard-issue-key-at-point)))
    (when key
      (seq-find (lambda (i) (equal key (alist-get 'key i)))
                decknix--support-dashboard-issues))))

(defun decknix-support-dashboard-browse ()
  "Open the DoS issue on the current row in the browser."
  (interactive)
  (let ((key (decknix-support-dashboard-issue-key-at-point)))
    (unless key (user-error "No issue on this row"))
    (browse-url (format "%s/browse/%s"
                        (string-trim-right decknix-support-dashboard-jira-base-url "/")
                        key))))

(defun decknix-support-dashboard-filter-status ()
  "Filter the DoS list by status (client-side); clear it if already filtered."
  (interactive)
  (if decknix--support-dashboard-status-filter
      (progn (setq decknix--support-dashboard-status-filter nil)
             (decknix--support-dashboard-redraw)
             (message "Status filter cleared"))
    (let ((statuses (delete-dups
                     (delq nil (mapcar (lambda (i) (alist-get 'status i))
                                       decknix--support-dashboard-issues)))))
      (if (null statuses)
          (message "No issues to filter")
        (setq decknix--support-dashboard-status-filter
              (completing-read "Filter status: " statuses nil t))
        (decknix--support-dashboard-redraw)))))

(defun decknix-support-dashboard-assign ()
  "Assign the DoS issue on the current row to someone via atlassian-cli (async)."
  (interactive)
  (let ((key (decknix-support-dashboard-issue-key-at-point)))
    (unless key (user-error "No issue on this row"))
    (let ((assignee (read-string (format "Assign %s to (email): " key))))
      (when (string-empty-p assignee) (user-error "No assignee given"))
      (message "Assigning %s to %s…" key assignee)
      (make-process
       :name "decknix-support-assign"
       :buffer (generate-new-buffer " *decknix-support-assign*")
       :noquery t
       :command (list decknix-support-dashboard-atlassian-cli
                      "jira" "issue" "assign" "--assignee" assignee key)
       :sentinel
       (lambda (proc _e)
         (when (eq (process-status proc) 'exit)
           (if (= 0 (process-exit-status proc))
               (progn (message "Assigned %s to %s" key assignee)
                      (decknix-support-dashboard-refresh))
             (message "Assign failed for %s" key))))))))

(defun decknix-support-dashboard-investigate ()
  "Start investigating the DoS issue on the current row with an agent.
Copies a ready investigation prompt (issue + summary + link) to the kill-ring
and, when available, opens a new agent-shell session to paste it into."
  (interactive)
  (let ((issue (decknix--support-dashboard-issue-at-point)))
    (unless issue (user-error "No issue on this row"))
    (let* ((key (alist-get 'key issue))
           (prompt (format (concat "Investigate %s: %s\n\nOpen %s/browse/%s, "
                                   "determine the root cause, and propose a fix "
                                   "or concrete next steps.")
                           key (or (alist-get 'summary issue) "")
                           (string-trim-right decknix-support-dashboard-jira-base-url "/")
                           key)))
      (kill-new prompt)
      (if (fboundp 'decknix-agent-session-new)
          (progn (call-interactively 'decknix-agent-session-new)
                 (message "Investigation prompt for %s on the kill-ring — yank it in"
                          key))
        (message "Investigation prompt for %s copied to kill-ring" key)))))

(defun decknix-support-dashboard-investigate-alert ()
  "Investigate the row at point AS AN ALERT (Playbook alert workflow).
Copies an alert-response prompt (triage → comment on ticket → root-cause fix,
with the resolve-in-GCP-console reminder) to the kill-ring and, when available,
opens a new agent-shell session to paste it into."
  (interactive)
  (let ((issue (decknix--support-dashboard-issue-at-point)))
    (unless issue (user-error "No issue on this row"))
    (let* ((key (alist-get 'key issue))
           (prompt (decknix--support-dashboard-alert-prompt
                    key (alist-get 'summary issue)
                    decknix-support-dashboard-alert-response-command
                    (format "%s/browse/%s"
                            (string-trim-right
                             decknix-support-dashboard-jira-base-url "/")
                            key))))
      (kill-new prompt)
      (if (fboundp 'decknix-agent-session-new)
          (progn (call-interactively 'decknix-agent-session-new)
                 (message "Alert-response prompt for %s on the kill-ring — yank it in"
                          key))
        (message "Alert-response prompt for %s copied to kill-ring" key)))))

(defun decknix--support-dashboard-resolve-report (callback)
  "Resolve the current weekly report page; call CALLBACK with (ID . TITLE).
If `decknix-support-dashboard-report-page-id' is set, use it directly.
Otherwise run a CQL title search via atlassian-cli (async) and pick the newest
matching page.  On failure CALLBACK gets (nil . ERR-STRING).  Never blocks."
  (if decknix-support-dashboard-report-page-id
      (funcall callback (cons decknix-support-dashboard-report-page-id nil))
    (if (not (executable-find decknix-support-dashboard-atlassian-cli))
        (funcall callback
                 (cons nil (format "%s not found on PATH"
                                   decknix-support-dashboard-atlassian-cli)))
      (let ((buf (generate-new-buffer " *decknix-support-report*"))
            (cql (format (concat "space = %s and title ~ \"%s\" "
                                 "and type = page order by created desc")
                         decknix-support-dashboard-confluence-space
                         decknix-support-dashboard-report-title-match)))
        (make-process
         :name "decknix-support-report"
         :buffer buf
         :noquery t
         :connection-type 'pipe
         :command (list decknix-support-dashboard-atlassian-cli
                        "--format" "json" "confluence" "search" "cql" cql
                        "--limit" "5")
         :sentinel
         (lambda (proc _e)
           (when (memq (process-status proc) '(exit signal))
             (let* ((out (and (buffer-live-p buf)
                              (with-current-buffer buf (buffer-string))))
                    (ok (and (eq (process-status proc) 'exit)
                             (= 0 (process-exit-status proc)))))
               (when (buffer-live-p buf) (kill-buffer buf))
               (if (not ok)
                   (funcall callback
                            (cons nil (string-trim (or out "report lookup failed"))))
                 (let ((page (decknix--support-dashboard-pick-report-page
                              (decknix--support-dashboard-parse out))))
                   (if page
                       (funcall callback (cons (alist-get 'id page)
                                               (alist-get 'title page)))
                     (funcall callback
                              (cons nil "no matching report page")))))))))))))

(defun decknix-support-dashboard-open-report ()
  "Open the current week's Weekly Techops Report in the browser.
Resolves the newest matching Confluence page by title (async)."
  (interactive)
  (message "Resolving weekly report…")
  (decknix--support-dashboard-resolve-report
   (lambda (result)
     (let ((id (car result)) (err (cdr result)))
       (if (not id)
           (message "Report lookup failed: %s" err)
         (browse-url (decknix--support-dashboard-report-url id))
         (message "Opened %s" (or err (decknix--support-dashboard-report-url id))))))))

(defun decknix-support-dashboard-draft-daily-log ()
  "Draft today's daily-log entry from live dashboard state for review.
Generates a Confluence-wiki-markup entry from the cached DoS issues and alerts,
shows it in a review buffer, and copies it to the kill-ring — it does NOT write
to Confluence.  Paste it into the weekly report (`r' opens it) after editing."
  (interactive)
  (let* ((src (get-buffer decknix-support-dashboard-buffer-name))
         (issues (and src (buffer-local-value
                           'decknix--support-dashboard-issues src)))
         (alerts (and src (buffer-local-value
                           'decknix--support-dashboard-alerts src)))
         (date (format-time-string "%Y-%m-%d"))
         (draft (decknix--support-dashboard-daily-log-draft issues alerts date))
         (buf (get-buffer-create "*decknix-daily-log-draft*")))
    (kill-new draft)
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert ";; Draft daily-log entry — review/edit, then paste into the\n"
                ";; weekly report ('r' in the dashboard opens it).  Also on the\n"
                ";; kill-ring.  Nothing has been written to Confluence.\n\n")
        (insert draft))
      (goto-char (point-min))
      (view-mode 1))
    (pop-to-buffer buf)
    (message "Daily-log draft ready (also on kill-ring) — review before pasting")))

(defun decknix-support-dashboard-open-workflow ()
  "Open the guided support workflow (the systematic daily work order)."
  (interactive)
  (if (fboundp 'decknix-support-workflow)
      (call-interactively 'decknix-support-workflow)
    (message "Support workflow not available")))

(transient-define-prefix decknix-support-dashboard-transient ()
  "Support dashboard actions."
  ["Row"
   ("b" "Browse to issue"        decknix-support-dashboard-browse)
   ("a" "Assign issue"           decknix-support-dashboard-assign)
   ("i" "Investigate with agent" decknix-support-dashboard-investigate)
   ("A" "Investigate as alert"   decknix-support-dashboard-investigate-alert)]
  ["List"
   ("/" "Filter by status"       decknix-support-dashboard-filter-status)
   ("g" "Refresh"                decknix-support-dashboard-refresh)]
  ["Weekly report"
   ("r" "Open weekly report"     decknix-support-dashboard-open-report)
   ("R" "Draft daily log"        decknix-support-dashboard-draft-daily-log)]
  ["Guide"
   ("w" "Support workflow (what to do, when)" decknix-support-dashboard-open-workflow)]
  [("q" "Close menu" transient-quit-one)])

(defvar decknix-support-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "b")   #'decknix-support-dashboard-browse)
    (define-key map (kbd "RET") #'decknix-support-dashboard-browse)
    (define-key map (kbd "/")   #'decknix-support-dashboard-filter-status)
    (define-key map (kbd "a")   #'decknix-support-dashboard-assign)
    (define-key map (kbd "i")   #'decknix-support-dashboard-investigate)
    (define-key map (kbd "A")   #'decknix-support-dashboard-investigate-alert)
    (define-key map (kbd "r")   #'decknix-support-dashboard-open-report)
    (define-key map (kbd "R")   #'decknix-support-dashboard-draft-daily-log)
    (define-key map (kbd "w")   #'decknix-support-dashboard-open-workflow)
    (define-key map (kbd "g")   #'decknix-support-dashboard-refresh)
    (define-key map (kbd "?")   #'decknix-support-dashboard-transient)
    (define-key map (kbd ".")   #'decknix-support-dashboard-transient)
    map)
  "Keymap for `decknix-support-dashboard-mode'.")

(define-derived-mode decknix-support-dashboard-mode special-mode "Support"
  "Major mode for the live support monitoring dashboard.
Row actions (submenu on `?'): `b' browse, `a' assign, `i' investigate;
list actions: `/' filter by status, `g' refresh, `q' bury;
weekly report: `r' open the current report, `R' draft today's daily log.
\\{decknix-support-dashboard-mode-map}"
  (setq-local revert-buffer-function
              (lambda (&rest _) (decknix-support-dashboard-refresh))))

;;;###autoload
(defun decknix-support-dashboard ()
  "Open the live support monitoring dashboard (DoS board + alerts), and refresh.
Read-only; press `?' for the action submenu (browse/filter/assign/investigate)."
  (interactive)
  (let ((buf (get-buffer-create decknix-support-dashboard-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'decknix-support-dashboard-mode)
        (decknix-support-dashboard-mode)))
    (pop-to-buffer buf)
    (decknix-support-dashboard-refresh)))

(provide 'decknix-support-dashboard)
;;; decknix-support-dashboard.el ends here
