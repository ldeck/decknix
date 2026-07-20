;;; decknix-support-workflow.el --- Guided TechOps support daily workflow -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Keywords: decknix, support, techops, workflow

;;; Commentary:
;;
;; A guided, systematic checklist for the TechOps / on-support rotation — the
;; "what to do, when, and how" distilled from the Techops Playbook work order:
;;
;;   Incidents (take priority over ALL work)
;;     -> Daily Checks    (before any other task; ~10 min each)
;;          Build Health, Service Health, update the Weekly Report
;;     -> Scheduled/Periodic Actions (~60 min; on stipulated days)
;;          Deployments (Tue & Thu by noon), Dependabot / Repo / Compass audits
;;     -> Work Items      (in priority order)
;;          Alerts (top priority) -> Operational Health -> DoS Tasks & Fixes
;;          -> Engineering Health
;;
;; The buffer is a live, day-aware checklist: each item shows its cadence,
;; time-box and how-to, and `RET' runs the item's action (open the service
;; dashboards, open the report, open the alerts view, ...).  Scheduled items
;; that don't apply today are dimmed.  Press `?' for the action menu.
;;
;; Design mirrors `decknix-support-dashboard': the render layer is PURE (data
;; in, display string out) and ERT-tested; only the action commands and the
;; buffer command touch the world.  The activity list and the org-specific
;; URLs are plain defvars so a workspace can override them.

;;; Code:

(require 'subr-x)
(require 'cl-lib)
(require 'seq)
(require 'transient)

(defvar decknix-support-workflow-buffer-name "*decknix-support-workflow*"
  "Name of the guided support-workflow buffer.")

;; -- Org-specific endpoints (overridable) -----------------------------------

(defvar decknix-support-workflow-playbook-url
  "https://vmxproperty.atlassian.net/wiki/spaces/TechOps/pages/4720230406/Techops+Playbook"
  "URL of the Techops Playbook (the authoritative process doc).")

(defvar decknix-support-workflow-board-url
  "https://vmxproperty.atlassian.net/jira/software/c/projects/DOS/boards/757"
  "URL of the DoS Jira board (the rotation worklist).")

(defvar decknix-support-workflow-alert-trends-url
  "https://vmxproperty.atlassian.net/jira/dashboards/10338"
  "URL of the alert-trends Jira dashboard (Created vs. Resolved).")

(defvar decknix-support-workflow-triage-logs-url
  "https://console.cloud.google.com/run/jobs/details/australia-southeast1/ai-automations-alert-triage/executions?project=upside-ci"
  "URL of the AI alert-triage Cloud Run job logs (verify dedupe ran).")

(defvar decknix-support-workflow-teamcity-url
  "https://upside-ci.com.au"
  "Base TeamCity URL for the Build Health check.")

(defvar decknix-support-workflow-shared-services
  '("Monolith" "DAPI (ANZ, UK)" "Listing-Perf (ANZ)" "ETL Functions"
    "Nct Monolith Outbox" "Noser" "Photo upload" "Decompressor" "Beholder")
  "Shared services deployed on the Tue/Thu cadence (deploy Monolith first).")

(defvar decknix-support-workflow-service-dashboards-command
  "nc-open-service-dashboards"
  "Executable that opens every shared service's Compass dashboards.")

(defvar decknix-support-workflow-alert-response-command
  "/nc-alert-response:alert-response"
  "Agent slash-command used to investigate an alert and comment on its ticket.")

;; -- The work order (data; overridable) -------------------------------------
;;
;; Each activity is a plist:
;;   :id       symbol (stable key; carried as a text property for row actions)
;;   :phase    one of incident daily scheduled work
;;   :title    short heading
;;   :when     cadence phrase ("daily", "Tue & Thu by noon", ...)
;;   :timebox  time budget ("10 min") or nil
;;   :how      one-paragraph how-to
;;   :days     list of weekday numbers (0=Sun .. 6=Sat) this applies on, or
;;             nil for every day (used to dim non-applicable scheduled items)
;;   :action   interactive command symbol to run on RET, or nil
;;   :url      fallback URL to open when there is no :action

(defvar decknix-support-workflow-activities
  '((:id incident :phase incident
     :title "Production incidents take priority over ALL work"
     :when "if an incident is active" :timebox nil
     :how "If an incident is active you own coordination: keep comms moving and shepherd a fix or rollback to prod (the owning squad writes the fix). Everything below is parked until it is resolved and a PIR is scheduled."
     :action decknix-support-workflow-open-board)

    (:id build-health :phase daily
     :title "Build Health — TeamCity (shared services)"
     :when "daily · before anything else" :timebox "10 min"
     :how "Expand EVERY shared-service TC project/env; wait for grey to settle. No red builds. Check for failed AND out-of-date prod deploys (click each prod deploy + publish build). Flag red builds to the owning squad; fix ownerless ones (e.g. compass) yourself. Ignore Db Config Terraform plans."
     :action decknix-support-workflow-build-health)

    (:id service-health :phase daily
     :title "Service Health — Compass dashboards (shared services)"
     :when "daily · before anything else" :timebox "10 min"
     :how "Open every shared-service dashboard and scan for anomalies/spikes; attribute the cause (usually migration). If a dashboard is missing or unclear, raise a DoS ticket."
     :action decknix-support-workflow-open-service-dashboards)

    (:id update-report :phase daily
     :title "Update the Weekly Techops Report"
     :when "daily" :timebox nil
     :how "Keep the report current — it guides your workload and is how the rotation is measured. Draft today's entry from the live dashboard (R in the dashboard), review it, then paste into the report."
     :action decknix-support-workflow-open-report)

    (:id deployments :phase scheduled
     :title "Deployments — ship all shared services"
     :when "Tue & Thu · by noon" :timebox "60 min" :days (2 4)
     :how "Ensure latest main is in prod for every shared service (Monolith first). Contact devs with unpromoted changes; deploy dependabot changes yourself; ping the chapter before a bulk deploy. Skip during incidents. Ignore Db terraform plans + contracts publish."
     :action decknix-support-workflow-deployments)

    (:id dependabot :phase scheduled
     :title "Dependabot Checks"
     :when "periodic" :timebox nil
     :how "Run the dependabot check command, interpret the results, and copy the generated tables into the report."
     :action nil)

    (:id repo-audit :phase scheduled
     :title "Repository Audit"
     :when "periodic" :timebox nil
     :how "Run the repository audit; add the reported standards non-conformances into the report."
     :action nil)

    (:id compass-audit :phase scheduled
     :title "Compass Audit"
     :when "periodic" :timebox nil
     :how "Run the compass audit; export to markdown and paste the table into the report."
     :action nil)

    (:id alerts :phase work
     :title "Alerts  ⚑ TOP PRIORITY"
     :when "after daily + scheduled checks" :timebox nil
     :how "Two sources: the DoS board Alerts swimlane + cost alerts on #nurturecloud-doit-collab. Triage ToDo alerts (no ai-triaged label = not triaged); move squad-related ones to the squad board; investigate with the alert-response command and comment on the ticket. Fix imminent risks now, else prioritise. NOTE: resolving the Jira ALR- ticket does NOT resolve the GCP alert — resolve it in the GCP console too."
     :action decknix-support-workflow-alerts)

    (:id op-health :phase work
     :title "Operational Health"
     :when "after alerts" :timebox nil
     :how "DoS-board swimlane: keep metrics, dashboards and alerts in good shape. Great for kicking off several AI investigations in parallel."
     :action decknix-support-workflow-open-board)

    (:id dos-tasks :phase work
     :title "DoS Tasks & Fixes"
     :when "after operational health" :timebox nil
     :how "Pick up tasks and bugs from the DoS swimlanes; run parallel AI agents on unrelated items."
     :action decknix-support-workflow-open-board)

    (:id eng-health :phase work
     :title "Engineering Health"
     :when "when everything else is clear" :timebox nil
     :how "If all rotation items are done, ask the Chapter Lead for engineering-health items that take under two days."
     :action nil))
  "Ordered TechOps support work order rendered by the workflow buffer.")

;; -- Buffer-local state -----------------------------------------------------

(defvar-local decknix--support-workflow-done nil
  "List of activity ids checked off this session (reset when the buffer dies).")

;; ---------------------------------------------------------------------------
;; Pure layer (data -> display string) — ERT-tested.
;; ---------------------------------------------------------------------------

(defconst decknix--support-workflow-phase-order '(incident daily scheduled work)
  "Render order of the workflow phases.")

(defun decknix--support-workflow-phase-title (phase)
  "Return the display heading for PHASE."
  (pcase phase
    ('incident  "0 · Incidents (drop everything)")
    ('daily     "1 · Daily Checks (before any other task)")
    ('scheduled "2 · Scheduled / Periodic Actions")
    ('work      "3 · Work Items (in priority order)")
    (_          (format "%s" phase))))

(defun decknix--support-workflow-activity-today-p (activity dow)
  "Return non-nil when ACTIVITY applies on weekday DOW (0=Sun..6=Sat).
An activity with no `:days' applies every day; otherwise it applies only when
DOW is a member of its `:days' list.  Pure."
  (let ((days (plist-get activity :days)))
    (or (null days) (and (integerp dow) (memq dow days)))))

(defun decknix--support-workflow-wrap (text prefix width)
  "Word-wrap TEXT to WIDTH columns, prefixing every line with PREFIX.  Pure."
  (let ((words (split-string (or text "") "[ \n]+" t))
        (lines nil) (line ""))
    (dolist (w words)
      (if (and (> (length line) 0)
               (> (+ (length line) 1 (length w)) width))
          (progn (push line lines) (setq line w))
        (setq line (if (string-empty-p line) w (concat line " " w)))))
    (unless (string-empty-p line) (push line lines))
    (mapconcat (lambda (l) (concat prefix l)) (nreverse lines) "\n")))

(defun decknix--support-workflow-format-activity (activity dow done)
  "Format ACTIVITY into a display block for weekday DOW.
DONE is non-nil when the item is checked off.  The block carries the activity
id in the `decknix-workflow-id' text property so row actions can target it.
Scheduled items that don't apply today are marked `(not today)'.  Pure."
  (let* ((id     (plist-get activity :id))
         (title  (plist-get activity :title))
         (when-   (plist-get activity :when))
         (timebox (plist-get activity :timebox))
         (how    (plist-get activity :how))
         (has-action (and (plist-get activity :action) t))
         (today  (decknix--support-workflow-activity-today-p activity dow))
         (mark   (cond (done "[x]") ((not today) "[-]") (t "[ ]")))
         (meta   (concat when-
                         (when timebox (format " · %s" timebox))
                         (unless today "   (not today)")))
         (row (concat
               (format "%s %s\n" mark title)
               (format "      %s\n" meta)
               (decknix--support-workflow-wrap how "      " 72)
               "\n"
               (if has-action
                   "      RET: run · o: open link · SPC: done\n"
                 "      o: open link · SPC: done\n"))))
    (propertize row 'decknix-workflow-id id)))

(defun decknix--support-workflow-render (activities dow done-ids)
  "Render ACTIVITIES into the workflow buffer text for weekday DOW.
DONE-IDS is a list of checked-off activity ids.  Groups activities by phase in
`decknix--support-workflow-phase-order'.  Pure."
  (concat
   "NurtureCloud TechOps — Support Workflow\n"
   (make-string 72 ?-) "\n"
   "Follow top-to-bottom. Incidents first; then daily checks before ALL else;\n"
   "then scheduled actions; then work items in priority order. Update the\n"
   "Weekly Report as you go.  Press ? for the menu.\n"
   (mapconcat
    (lambda (phase)
      (let ((items (seq-filter
                    (lambda (a) (eq (plist-get a :phase) phase))
                    activities)))
        (when items
          (concat
           (format "\n%s\n" (decknix--support-workflow-phase-title phase))
           (make-string 72 ?·) "\n"
           (mapconcat
            (lambda (a)
              (decknix--support-workflow-format-activity
               a dow (and (memq (plist-get a :id) done-ids) t)))
            items "\n")))))
    decknix--support-workflow-phase-order
    "")
   "\n"
   (make-string 72 ?-) "\n"
   "Legend:  [ ] to do   [x] done   [-] not scheduled today\n"
   "Keys:    n/p move · RET run · o open link · SPC toggle done · g refresh\n"
   "         d dashboard · P playbook · b board · ? menu · q bury\n"))

;; ---------------------------------------------------------------------------
;; Side-effecting layer: action commands.
;; ---------------------------------------------------------------------------

(defun decknix--support-workflow-run-async (command &rest args)
  "Run COMMAND with ARGS asynchronously (non-blocking); message on completion.
Returns nil and messages if COMMAND is not on PATH."
  (if (not (executable-find command))
      (message "%s not found on PATH" command)
    (message "Running %s…" command)
    (make-process
     :name (format "decknix-workflow-%s" command)
     :buffer (generate-new-buffer (format " *decknix-workflow-%s*" command))
     :noquery t
     :command (cons command args)
     :sentinel
     (lambda (proc _e)
       (when (memq (process-status proc) '(exit signal))
         (message "%s finished (exit %s)" command (process-exit-status proc)))))))

(defun decknix-support-workflow-open-service-dashboards ()
  "Open every shared service's Compass dashboards (Service Health check)."
  (interactive)
  (decknix--support-workflow-run-async
   decknix-support-workflow-service-dashboards-command))

(defun decknix-support-workflow-open-report ()
  "Open the current Weekly Techops Report (delegates to the dashboard command)."
  (interactive)
  (if (fboundp 'decknix-support-dashboard-open-report)
      (call-interactively 'decknix-support-dashboard-open-report)
    (message "Open the report from the dashboard (C-c A D, then r)")))

(defun decknix-support-workflow-open-board ()
  "Open the DoS Jira board in the browser."
  (interactive)
  (browse-url decknix-support-workflow-board-url))

(defun decknix-support-workflow-alerts ()
  "Jump to alert triage: open the live support dashboard and the DoS board.
The dashboard shows the DoS worklist + the #nurturecloud-doit-collab alert
feed; the board opens on the Alerts swimlane for triage/move actions."
  (interactive)
  (when (fboundp 'decknix-support-dashboard)
    (save-window-excursion (call-interactively 'decknix-support-dashboard)))
  (browse-url decknix-support-workflow-board-url)
  (message "Alerts: dashboard refreshed + DoS board opened. Triage ToDo, investigate with %s, resolve GCP too."
           decknix-support-workflow-alert-response-command))

(defun decknix-support-workflow-build-health ()
  "Start the Build Health check: copy an agent prompt + open TeamCity.
Puts a ready investigation prompt on the kill-ring (needs TEAMCITY_TOKEN in the
environment) and opens the TeamCity site so you can expand shared-service
projects."
  (interactive)
  (kill-new
   (concat "Check TeamCity build health for our shared services. "
           "For each shared-service project expand every environment, report any "
           "RED builds and any FAILED or OUT-OF-DATE prod deploys (failed deploys "
           "AND deploys where prod is behind main). Ignore Db Config Terraform "
           "plans. For each problem name the responsible squad/committer. "
           "Use the TEAMCITY_TOKEN env var for API access."))
  (browse-url decknix-support-workflow-teamcity-url)
  (message "Build Health: prompt on kill-ring (paste into an agent), TeamCity opened"))

(defun decknix-support-workflow-deployments ()
  "Start the Tue/Thu deployment sweep: copy a prompt listing shared services."
  (interactive)
  (kill-new
   (concat "Deployment sweep for shared services (deploy by noon). "
           "For each of: "
           (mapconcat #'identity decknix-support-workflow-shared-services ", ")
           " — ensure the latest main is deployed to prod (Monolith first). "
           "List services with unpromoted changes and who pushed them; deploy "
           "dependabot-only changes directly. Skip during incidents. Ignore Db "
           "terraform plans and contracts publish."))
  (message "Deployments: sweep prompt on kill-ring (%d shared services)"
           (length decknix-support-workflow-shared-services)))

;; ---------------------------------------------------------------------------
;; Buffer: render + row actions + mode/keymap/transient.
;; ---------------------------------------------------------------------------

(defun decknix--support-workflow-redraw ()
  "Re-render the workflow buffer from the activity list and today's weekday.
Assumes `current-buffer' is the workflow buffer; preserves point."
  (let ((inhibit-read-only t)
        (pos (point))
        (dow (nth 6 (decode-time))))
    (erase-buffer)
    (insert (decknix--support-workflow-render
             decknix-support-workflow-activities
             dow decknix--support-workflow-done))
    (goto-char (min pos (point-max)))))

(defun decknix-support-workflow-refresh ()
  "Refresh the workflow buffer (re-evaluates today's applicable items)."
  (interactive)
  (when (get-buffer decknix-support-workflow-buffer-name)
    (with-current-buffer decknix-support-workflow-buffer-name
      (decknix--support-workflow-redraw))))

(defun decknix--support-workflow-id-at-point ()
  "Return the activity id on the current row, or nil."
  (get-text-property (point) 'decknix-workflow-id))

(defun decknix--support-workflow-activity-at-point ()
  "Return the activity plist for the row at point, or nil."
  (let ((id (decknix--support-workflow-id-at-point)))
    (when id
      (seq-find (lambda (a) (eq id (plist-get a :id)))
                decknix-support-workflow-activities))))

(defun decknix-support-workflow-run-at-point ()
  "Run the action for the activity on the current row (or open its link)."
  (interactive)
  (let ((activity (decknix--support-workflow-activity-at-point)))
    (unless activity (user-error "No activity on this row"))
    (let ((action (plist-get activity :action))
          (url (plist-get activity :url)))
      (cond
       ((and action (fboundp action)) (call-interactively action))
       (url (browse-url url))
       (t (message "No action for %s — see the how-to above"
                   (plist-get activity :title)))))))

(defun decknix-support-workflow-open-link-at-point ()
  "Open the fallback URL for the activity on the current row, if any."
  (interactive)
  (let ((activity (decknix--support-workflow-activity-at-point)))
    (unless activity (user-error "No activity on this row"))
    (let ((url (plist-get activity :url)))
      (if url (browse-url url)
        (message "No link for this item")))))

(defun decknix-support-workflow-toggle-done ()
  "Toggle the checked-off state of the activity on the current row."
  (interactive)
  (let ((id (decknix--support-workflow-id-at-point)))
    (unless id (user-error "No activity on this row"))
    (setq decknix--support-workflow-done
          (if (memq id decknix--support-workflow-done)
              (delq id decknix--support-workflow-done)
            (cons id decknix--support-workflow-done)))
    (decknix--support-workflow-redraw)))

(defun decknix-support-workflow-next ()
  "Move point to the next activity row."
  (interactive)
  (let ((start (point)))
    (forward-line 1)
    (while (and (not (eobp)) (not (decknix--support-workflow-id-at-point)))
      (forward-line 1))
    (unless (decknix--support-workflow-id-at-point) (goto-char start))))

(defun decknix-support-workflow-prev ()
  "Move point to the previous activity row."
  (interactive)
  (let ((start (point)))
    (forward-line -1)
    (while (and (not (bobp)) (not (decknix--support-workflow-id-at-point)))
      (forward-line -1))
    (unless (decknix--support-workflow-id-at-point) (goto-char start))))

(defun decknix-support-workflow-open-playbook ()
  "Open the Techops Playbook in the browser."
  (interactive)
  (browse-url decknix-support-workflow-playbook-url))

(defun decknix-support-workflow-open-dashboard ()
  "Open the live support dashboard, if available."
  (interactive)
  (if (fboundp 'decknix-support-dashboard)
      (call-interactively 'decknix-support-dashboard)
    (message "Support dashboard not available")))

(transient-define-prefix decknix-support-workflow-transient ()
  "Support workflow actions."
  ["Row"
   ("RET" "Run this item"     decknix-support-workflow-run-at-point)
   ("o"   "Open its link"     decknix-support-workflow-open-link-at-point)
   ("SPC" "Toggle done"       decknix-support-workflow-toggle-done)]
  ["Jump to"
   ("d" "Live dashboard"      decknix-support-workflow-open-dashboard)
   ("b" "DoS board"           decknix-support-workflow-open-board)
   ("P" "Techops Playbook"    decknix-support-workflow-open-playbook)
   ("a" "Alerts (top priority)" decknix-support-workflow-alerts)]
  ["List"
   ("n" "Next item"           decknix-support-workflow-next :transient t)
   ("p" "Previous item"       decknix-support-workflow-prev :transient t)
   ("g" "Refresh"             decknix-support-workflow-refresh)]
  [("q" "Close menu" transient-quit-all)])

(defvar decknix-support-workflow-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'decknix-support-workflow-run-at-point)
    (define-key map (kbd "o")   #'decknix-support-workflow-open-link-at-point)
    (define-key map (kbd "SPC") #'decknix-support-workflow-toggle-done)
    (define-key map (kbd "n")   #'decknix-support-workflow-next)
    (define-key map (kbd "p")   #'decknix-support-workflow-prev)
    (define-key map (kbd "g")   #'decknix-support-workflow-refresh)
    (define-key map (kbd "d")   #'decknix-support-workflow-open-dashboard)
    (define-key map (kbd "b")   #'decknix-support-workflow-open-board)
    (define-key map (kbd "P")   #'decknix-support-workflow-open-playbook)
    (define-key map (kbd "a")   #'decknix-support-workflow-alerts)
    (define-key map (kbd "?")   #'decknix-support-workflow-transient)
    (define-key map (kbd ".")   #'decknix-support-workflow-transient)
    map)
  "Keymap for `decknix-support-workflow-mode'.")

(define-derived-mode decknix-support-workflow-mode special-mode "Support-WF"
  "Major mode for the guided TechOps support workflow checklist.
Move with `n'/`p'; `RET' runs the item's action, `o' opens its link, `SPC'
toggles done; `d' dashboard, `b' board, `P' playbook, `a' alerts, `?' menu.
\\{decknix-support-workflow-mode-map}")

;;;###autoload
(defun decknix-support-workflow ()
  "Open the guided TechOps support workflow checklist.
A day-aware, top-to-bottom guide to the rotation's work order; press `?' for
the action menu."
  (interactive)
  (let ((buf (get-buffer-create decknix-support-workflow-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'decknix-support-workflow-mode)
        (decknix-support-workflow-mode))
      (decknix--support-workflow-redraw)
      (goto-char (point-min)))
    (pop-to-buffer buf)))

(provide 'decknix-support-workflow)
;;; decknix-support-workflow.el ends here
