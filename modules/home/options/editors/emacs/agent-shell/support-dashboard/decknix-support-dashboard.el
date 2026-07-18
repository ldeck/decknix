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

(defvar decknix-support-dashboard-buffer-name "*decknix-support*"
  "Name of the support monitoring dashboard buffer.")

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

(defun decknix--support-dashboard-render (issues &optional timestamp)
  "Render ISSUES (a list of issue alists) into the dashboard's buffer text.
TIMESTAMP is an optional display string appended to the footer; when nil it is
omitted, which keeps this function pure for tests."
  (concat
   "NurtureCloud Support — DoS Board\n"
   (make-string 64 ?-) "\n"
   (if (null issues)
       "  (no open DoS issues)\n"
     (concat (mapconcat #'decknix--support-dashboard-format-issue issues "\n")
             "\n"))
   "\n"
   (format "%d open%s\n"
           (length issues)
           (if (and timestamp (not (string-empty-p timestamp)))
               (concat "   ·   updated " timestamp)
             ""))))

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

(defun decknix-support-dashboard-refresh ()
  "Refresh the support dashboard buffer from Jira (async, non-blocking)."
  (interactive)
  (let ((target (get-buffer-create decknix-support-dashboard-buffer-name)))
    (decknix--support-dashboard-fetch
     (lambda (issues err)
       (when (buffer-live-p target)
         (with-current-buffer target
           (let ((inhibit-read-only t)
                 (pos (point)))
             (erase-buffer)
             (insert (if err
                         (format "NurtureCloud Support — DoS Board\n%s\nError: %s\n"
                                 (make-string 64 ?-) err)
                       (decknix--support-dashboard-render
                        issues (format-time-string "%H:%M:%S"))))
             (goto-char (min pos (point-max))))))))))

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
