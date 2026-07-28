;;; decknix-agent-acp-trace.el --- Default-off ACP turn/status trace -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, acp, diagnostics

;;; Commentary:
;;
;; A DEFAULT-OFF diagnostic that records the ACP event stream and the
;; agent-shell turn boundaries for a session, so we can see exactly WHEN a
;; provider (esp. Claude) signals that a prompt turn has returned versus when
;; agent-shell flips the buffer's busy/idle status.  It is the observation step
;; for ldeck/decknix#150 (session-state detection): turn Claude's "super buggy
;; status" into a precise, timestamped signal before changing any turn-detection
;; logic.
;;
;; It records three kinds of event, each stamped with a monotonic time:
;;   * every ACP `session/update' notification (kind + a short detail) — the
;;     live stream (message / thought chunks, tool calls, plan, permission,
;;     available-commands, session-info),
;;   * TURN-START  — when agent-shell starts the busy heartbeat (turn begins),
;;   * TURN-END    — when agent-shell stops it (agent-shell's view of "returned").
;;
;; The gap between the last meaningful ACP event and TURN-END (or a missing
;; TURN-END) is the tell: a leaked/never-fired turn-end, or a premature one.
;;
;; Nothing is hooked destructively: the advices are `:before' (return value
;; ignored) and cheap no-ops while disabled, so leaving the package loaded costs
;; nothing until you toggle it on.  Events go to an in-memory ring AND an
;; append-only log file (so a freeze/kill still leaves the trace on disk).
;;
;; Usage:
;;   M-x decknix-agent-acp-trace-toggle   ; turn recording on (off by default)
;;   ... run one normal Claude prompt ...
;;   M-x decknix-agent-acp-trace-show     ; read the timeline, newest first
;;   M-x decknix-agent-acp-trace-clear
;;
;; Pure (ERT-tested) surface: `decknix--agent-acp-trace-summarize',
;; `decknix--agent-acp-trace-detail', `decknix--agent-acp-trace-short',
;; `decknix--agent-acp-trace-format'.  The ring, file I/O, and advice callbacks
;; are the impure shell.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)

(declare-function decknix--agent-buffer-session-id "decknix-agent-buffer-lookup" (&optional buf))

(defvar decknix-agent-acp-trace-enable nil
  "When non-nil, record ACP notifications + turn start/stop for diagnosis.
Default off; toggle with `decknix-agent-acp-trace-toggle'.  While nil every
callback is a cheap no-op.")

(defconst decknix-agent-acp-trace-max 1000
  "Maximum number of events retained in the in-memory ring.")

(defvar decknix-agent-acp-trace-log-file
  (expand-file-name "decknix/agent-acp-trace.log"
                    (or (getenv "XDG_CONFIG_HOME") (expand-file-name "~/.config")))
  "Append-only ACP trace log, written only while tracing is enabled.")

(defvar decknix--agent-acp-trace-ring nil
  "In-memory list of trace events, newest first.")

;; ── Pure layer ─────────────────────────────────────────────────────────

(defun decknix--agent-acp-trace-short (session)
  "Return a compact form of SESSION id (first 8 chars), or \"\" when absent."
  (if (and session (stringp session) (not (string-empty-p session)))
      (substring session 0 (min 8 (length session)))
    ""))

(defun decknix--agent-acp-trace-detail (kind update)
  "Return a short human detail string for a session/update of KIND.
UPDATE is the notification's `update' alist.  Pure; nil-safe."
  (pcase kind
    ("agent_message_chunk"       "message")
    ("agent_thought_chunk"       "thought")
    ("user_message_chunk"        "user-echo")
    ("tool_call"
     (string-trim
      (format "tool %s %s"
              (or (alist-get 'title update) (alist-get 'kind update) "?")
              (or (alist-get 'status update) ""))))
    ("tool_call_update"
     (string-trim
      (format "tool# %s %s"
              (or (alist-get 'toolCallId update) "?")
              (or (alist-get 'status update) ""))))
    ("plan"                       "plan")
    ("available_commands_update"  "commands")
    ("current_mode_update"
     (format "mode=%s" (or (alist-get 'currentModeId update) "?")))
    ("session_info_update"        "info")
    ((pred null)                  "")
    (_ (format "%s" kind))))

(defun decknix--agent-acp-trace-summarize (notification)
  "Summarize an ACP NOTIFICATION alist into a plist, or nil.
Returns (:label L :session S :detail D): L is the sessionUpdate kind for a
`session/update', else the JSON-RPC method; S the sessionId; D a short detail.
Pure: no I/O."
  (let* ((method (alist-get 'method notification))
         (params (alist-get 'params notification))
         (update (alist-get 'update params))
         (kind (and update (alist-get 'sessionUpdate update)))
         (session (alist-get 'sessionId params)))
    (when method
      (list :label (or kind method)
            :session session
            :detail (decknix--agent-acp-trace-detail kind update)))))

(defun decknix--agent-acp-trace-format (event)
  "Format a trace EVENT plist (:time :label :session :detail) as one line."
  (let ((time (plist-get event :time))
        (label (or (plist-get event :label) "?"))
        (session (plist-get event :session))
        (detail (or (plist-get event :detail) "")))
    (format "%s  %-26s %-9s %s"
            (format-time-string "%H:%M:%S.%3N" (seconds-to-time (or time 0)))
            label
            (let ((s (decknix--agent-acp-trace-short session)))
              (if (string-empty-p s) "" (concat "sid=" s)))
            detail)))

;; ── Impure shell: ring + file + advice callbacks ───────────────────────

(defun decknix--agent-acp-trace-record (label &optional session detail)
  "Record a trace event (LABEL, optional SESSION, DETAIL) — ring + log file."
  (when decknix-agent-acp-trace-enable
    (let ((event (list :time (float-time) :label label
                       :session session :detail detail)))
      (push event decknix--agent-acp-trace-ring)
      (when (> (length decknix--agent-acp-trace-ring) decknix-agent-acp-trace-max)
        (setq decknix--agent-acp-trace-ring
              (seq-take decknix--agent-acp-trace-ring decknix-agent-acp-trace-max)))
      (ignore-errors
        (write-region (concat (decknix--agent-acp-trace-format event) "\n")
                      nil decknix-agent-acp-trace-log-file 'append 'silent)))))

(defun decknix--agent-acp-trace--buffer-session ()
  "Best-effort session id for the current agent-shell buffer, or nil."
  (or (and (fboundp 'decknix--agent-buffer-session-id)
           (ignore-errors (decknix--agent-buffer-session-id)))
      nil))

(defun decknix--agent-acp-trace-on-notification (&rest args)
  "`:before' advice for `agent-shell--on-notification': record the event.
ARGS is the `&key' plist; a no-op while disabled.  Returns nil (advice value
ignored) so it never affects the notification handler's control flow."
  (when decknix-agent-acp-trace-enable
    (ignore-errors
      (let ((s (decknix--agent-acp-trace-summarize (plist-get args :notification))))
        (when s
          (decknix--agent-acp-trace-record
           (plist-get s :label) (plist-get s :session) (plist-get s :detail))))))
  nil)

(defun decknix--agent-acp-trace-on-heartbeat-start (&rest _)
  "`:before' advice for `agent-shell-heartbeat-start': mark a turn beginning."
  (when decknix-agent-acp-trace-enable
    (ignore-errors
      (decknix--agent-acp-trace-record
       "TURN-START" (decknix--agent-acp-trace--buffer-session) (buffer-name))))
  nil)

(defun decknix--agent-acp-trace-on-heartbeat-stop (&rest _)
  "`:before' advice for `agent-shell-heartbeat-stop': mark a turn ending.
This is agent-shell's view of \"the prompt returned\"; compare its timing with
the last real ACP event to spot a mis-detected turn boundary."
  (when decknix-agent-acp-trace-enable
    (ignore-errors
      (decknix--agent-acp-trace-record
       "TURN-END" (decknix--agent-acp-trace--buffer-session) (buffer-name))))
  nil)

;; ── Commands ───────────────────────────────────────────────────────────

;;;###autoload
(defun decknix-agent-acp-trace-toggle ()
  "Toggle ACP turn/status tracing (default off).  Prints where the log lands."
  (interactive)
  (setq decknix-agent-acp-trace-enable (not decknix-agent-acp-trace-enable))
  (if decknix-agent-acp-trace-enable
      (message "decknix ACP trace ON → %s  (run a prompt, then M-x decknix-agent-acp-trace-show)"
               decknix-agent-acp-trace-log-file)
    (message "decknix ACP trace OFF (%d events retained)"
             (length decknix--agent-acp-trace-ring))))

;;;###autoload
(defun decknix-agent-acp-trace-show ()
  "Show the recorded ACP trace timeline (newest first) in a buffer."
  (interactive)
  (let ((buf (get-buffer-create "*decknix ACP trace*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "decknix ACP trace — %d events, newest first%s\n"
                        (length decknix--agent-acp-trace-ring)
                        (if decknix-agent-acp-trace-enable " (recording)" " (stopped)")))
        (insert (format "log: %s\n\n" decknix-agent-acp-trace-log-file))
        (if decknix--agent-acp-trace-ring
            (dolist (e decknix--agent-acp-trace-ring)
              (insert (decknix--agent-acp-trace-format e) "\n"))
          (insert "(no events — toggle on with M-x decknix-agent-acp-trace-toggle)\n")))
      (goto-char (point-min))
      (view-mode 1))
    (pop-to-buffer buf)))

;;;###autoload
(defun decknix-agent-acp-trace-clear ()
  "Clear the in-memory ACP trace ring (the log file is left intact)."
  (interactive)
  (setq decknix--agent-acp-trace-ring nil)
  (message "decknix ACP trace ring cleared"))

(provide 'decknix-agent-acp-trace)
;;; decknix-agent-acp-trace.el ends here
