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
  "Format one ISSUE alist into a fixed-width dashboard row string."
  (let ((key      (or (alist-get 'key issue) "?"))
        (status   (or (alist-get 'status issue) ""))
        (assignee (or (alist-get 'assignee issue) "unassigned"))
        (summary  (or (alist-get 'summary issue) "")))
    (format "%-9s  %-13s  %-16s  %s"
            key
            (format "[%s]" status)
            (truncate-string-to-width assignee 16)
            summary)))

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

(defun decknix-support-dashboard-refresh ()
  "Refresh the dashboard from the DoS board and the alert feed (async).
Fetches issues, then alerts, then renders the composite; neither fetch blocks."
  (interactive)
  (let ((target (get-buffer-create decknix-support-dashboard-buffer-name)))
    (decknix--support-dashboard-fetch
     (lambda (issues issues-err)
       (decknix--support-dashboard-fetch-alerts
        (lambda (alerts alerts-err)
          (when (buffer-live-p target)
            (with-current-buffer target
              (let ((inhibit-read-only t)
                    (pos (point)))
                (erase-buffer)
                (insert (decknix--support-dashboard-render-full
                         issues issues-err alerts alerts-err
                         (format-time-string "%H:%M:%S")))
                (goto-char (min pos (point-max))))))))))))

(defun decknix--support-dashboard-visible-p ()
  "Return non-nil when the dashboard buffer exists and is displayed."
  (let ((buf (get-buffer decknix-support-dashboard-buffer-name)))
    (and buf (get-buffer-window buf t) t)))

(defun decknix--support-dashboard-tick ()
  "Auto-refresh entry point: refresh only while the dashboard is displayed.
Cheap when hidden (a single window lookup), so it is safe to run on a timer."
  (when (decknix--support-dashboard-visible-p)
    (decknix-support-dashboard-refresh)))

;;;###autoload
(defun decknix-support-dashboard ()
  "Open the live support monitoring dashboard (DoS board), and refresh it.
The buffer is read-only (`special-mode': `g' reverts, `q' buries)."
  (interactive)
  (let ((buf (get-buffer-create decknix-support-dashboard-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'special-mode)
        (special-mode))
      (setq-local revert-buffer-function
                  (lambda (&rest _) (decknix-support-dashboard-refresh))))
    (pop-to-buffer buf)
    (decknix-support-dashboard-refresh)))

(provide 'decknix-support-dashboard)
;;; decknix-support-dashboard.el ends here
