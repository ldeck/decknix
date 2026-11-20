;;; decknix-agent-session-export.el --- Export live session state for the CLI -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-cache-write "0.1"))
;; Keywords: agent, agent-shell, decknix, status

;;; Commentary:
;;
;; Writes what each live agent-shell session is doing to one small JSON
;; file per session, so `decknix session status' can answer an agent
;; (typically a coordinator driving several lane sessions) without asking
;; Emacs anything:
;;
;;   $XDG_STATE_HOME/decknix/sessions/   (0700)
;;     _emacs.json      heartbeat: pid, time, interval, dispatch receiver on?,
;;                      who armed it and when, control watcher on?
;;     <session>.json   state, busy since, last activity, current tool,
;;                      closing text tail, queue depth, last delivery,
;;                      tags as the sidebar resolves them
;;
;; Before this a coordinator saw a single busy bit only through a message
;; expiring.  A lane whose agent had gone silent for half an hour, its
;; prompt held open by a background task it had started, was
;; indistinguishable from one producing output, so two messages expired
;; and the human had to cancel the turn and paste them by hand.  The
;; `background' state names exactly that case.
;;
;; Cost: the notification observer stores a timestamp and, only for tool
;; call updates, touches a short alist.  A self-pacing sweep builds each
;; snapshot and hands it to `decknix-hub-cache-write-string', which skips
;; the disk when the text is unchanged; `last_activity' is bucketed so a
;; streaming turn does not rewrite its file on every sweep.  The heartbeat
;; is the only file rewritten unconditionally, every
;; `decknix-agent-session-export-heartbeat-interval' seconds.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)
(require 'decknix-hub-cache-write)

(defvar shell-maker--busy)
(defvar agent-shell--state)
(defvar decknix-agent-dispatch-mode)
(defvar decknix-agent-dispatch-control-mode)
(defvar decknix-agent-dispatch-remote-control)
(defvar decknix-agent-session-export-mode)
(defvar decknix--agent-turn-message-tail)

(declare-function agent-shell-buffers "agent-shell")
(declare-function agent-shell-workspace--buffer-status "agent-shell-workspace" (buffer))
(declare-function decknix--agent-buffer-session-id "decknix-agent-buffer-lookup"
                  (&optional buf))
(declare-function decknix-agent-turn-closing-text "decknix-agent-turn-signals"
                  (&optional buffer))
(declare-function decknix--compose-queue-count "decknix-agent-shell-main-compose" (target))
(declare-function decknix-agent-dispatch-waiting-count "decknix-agent-dispatch" (sid))
(declare-function decknix-agent-dispatch-last-delivered "decknix-agent-dispatch" (sid))
(declare-function decknix-agent-dispatch-state "decknix-agent-dispatch" ())
(declare-function decknix--agent-tags-resolve "decknix-agent-tags-read" (conv-key session-id))
(declare-function decknix--agent-current-conv-key "decknix-agent-buffer-lookup" ())

(defgroup decknix-agent-session-export nil
  "Export live agent session state to files for the decknix CLI."
  :group 'tools)

(defvar decknix-agent-session-export-dir
  (expand-file-name "decknix/sessions"
                    (or (getenv "XDG_STATE_HOME") "~/.local/state"))
  "Directory the session state files are written to.")

(defcustom decknix-agent-session-export-interval 5
  "Minimum seconds between sweeps.  A slow sweep pushes the next one out."
  :type 'number :group 'decknix-agent-session-export)

(defcustom decknix-agent-session-export-heartbeat-interval 30
  "Seconds between heartbeat writes; readers call a heartbeat stale at 3x."
  :type 'number :group 'decknix-agent-session-export)

(defcustom decknix-agent-session-export-background-seconds 120
  "Quiet seconds after which an open turn with no tool in flight is `background'."
  :type 'number :group 'decknix-agent-session-export)

(defvar decknix-agent-session-export-activity-bucket 15
  "Granularity in seconds of the exported `last_activity'.")

(defvar decknix-agent-session-export-tail-chars 300
  "Characters of closing text exported per session.")

(defvar decknix-agent-session-export-buffers-function
  (lambda () (and (fboundp 'agent-shell-buffers) (agent-shell-buffers)))
  "Returns the agent-shell buffers to export.")

(defvar decknix-agent-session-export-session-id-function
  (lambda (buf) (and (fboundp 'decknix--agent-buffer-session-id)
                     (decknix--agent-buffer-session-id buf)))
  "Called with a buffer; returns its session id or nil.")

(defvar decknix-agent-session-export-status-function
  (lambda (buf)
    (if (fboundp 'agent-shell-workspace--buffer-status)
        (agent-shell-workspace--buffer-status buf)
      (if (buffer-local-value 'shell-maker--busy buf) "working" "ready")))
  "Called with a buffer; returns its sidebar status string.")

(defvar decknix-agent-session-export-tags-function
  #'decknix-agent-session-export--sidebar-tags
  "Called with (BUFFER SESSION-ID); returns the session's tags or nil.")

(declare-function decknix-agent-turn-plan "decknix-agent-turn-signals" (&optional buffer))

(defvar decknix-agent-session-export-plan-function
  (lambda (buf) (and (fboundp 'decknix-agent-turn-plan) (decknix-agent-turn-plan buf)))
  "Function of a buffer returning its last ACP plan progress plist, or nil.")

(defvar decknix-agent-session-export-write-function #'decknix-hub-cache-write-string
  "Called with (FILE TEXT &optional FORCE); writes only when TEXT changed.")

(defvar-local decknix-agent-session-export--last-activity nil
  "`float-time' of the last ACP update this buffer received.")
(defvar-local decknix-agent-session-export--tools nil
  "In-flight tool calls, newest first: (ID TITLE . SINCE).")
(defvar-local decknix-agent-session-export--busy-since nil)
(defvar-local decknix-agent-session-export--state nil)
(defvar-local decknix-agent-session-export--state-since nil)

(defvar decknix-agent-session-export--timer nil)
(defvar decknix-agent-session-export--heartbeat-at 0)
(defvar decknix-agent-session-export--written (make-hash-table :test 'equal)
  "Session id -> last snapshot plist written by this Emacs.")

(defconst decknix-agent-session-export--max-tools 32)

;; -- pure ------------------------------------------------------------

(defun decknix-agent-session-export-state (status busy tools quiet)
  "Return the exported state for sidebar STATUS.
BUSY is `shell-maker--busy', TOOLS the in-flight tool calls and QUIET the
seconds since the last ACP update (nil when unknown)."
  (pcase status
    ("waiting" "waiting-permission")
    ("asking" "asking")
    ("netfail" "netfail")
    ("killed" "dead")
    ("initializing" "starting")
    (_ (cond
        ((not (or busy (equal status "working"))) "idle")
        ((and (null tools) quiet
              (>= quiet decknix-agent-session-export-background-seconds))
         "background")
        (t "working")))))

(defun decknix-agent-session-export--tail (text)
  (when (and (stringp text) (not (string-empty-p (string-trim text))))
    (let ((text (string-trim text)))
      (substring text (max 0 (- (length text) decknix-agent-session-export-tail-chars))))))

(defun decknix-agent-session-export--tool-update (tools update now)
  "Return TOOLS after ACP tool UPDATE (an alist) at NOW."
  (let* ((id (map-elt update 'toolCallId))
         (status (map-elt update 'status))
         (title (map-elt update 'title))
         (old (assoc id tools)))
    (cond
     ((null id) tools)
     ((member status '("completed" "failed"))
      (assoc-delete-all id tools))
     (old
      (if (stringp title)
          (cons (cons id (cons title (cddr old))) (assoc-delete-all id tools))
        tools))
     ((equal (map-elt update 'sessionUpdate) "tool_call")
      (seq-take (cons (cons id (cons (or title "tool") now)) tools)
                decknix-agent-session-export--max-tools))
     (t tools))))

(defun decknix-agent-session-export--bucket (time)
  (and time (* decknix-agent-session-export-activity-bucket
               (floor time decknix-agent-session-export-activity-bucket))))

(defun decknix-agent-session-export--json-value (v)
  (if (null v) :null v))

;; -- capture -----------------------------------------------------------

(defun decknix-agent-session-export-observe-notification (&rest args)
  "Note activity from an ACP notification; `:before' advice on
`agent-shell--on-notification'.  Runs on every streamed chunk, so it only
stores a time, and edits the tool list only for tool call updates."
  (let* ((state (plist-get args :state))
         (buf (map-elt state :buffer)))
    (when (buffer-live-p buf)
      (let ((notification (plist-get args :acp-notification))
            (now (float-time)))
        (with-current-buffer buf
          (setq decknix-agent-session-export--last-activity now)
          (when (equal (map-elt notification 'method) "session/update")
            (let ((update (map-nested-elt notification '(params update))))
              (when (member (map-elt update 'sessionUpdate) '("tool_call" "tool_call_update"))
                (setq decknix-agent-session-export--tools
                      (decknix-agent-session-export--tool-update
                       decknix-agent-session-export--tools update now))))))))))

(defun decknix-agent-session-export-observe-event (&rest args)
  "Track turn boundaries; `:before' advice on `agent-shell--emit-event'."
  (when (derived-mode-p 'agent-shell-mode)
    (pcase (plist-get args :event)
      ('input-submitted
       (setq decknix-agent-session-export--busy-since (float-time)
             decknix-agent-session-export--last-activity (float-time)
             decknix-agent-session-export--tools nil))
      ('turn-complete
       (setq decknix-agent-session-export--busy-since nil
             decknix-agent-session-export--tools nil)))))

(defun decknix-agent-session-export-background-p (buf)
  "Non-nil when BUF's turn is open but only waiting on background work."
  (and (buffer-live-p buf)
       (with-current-buffer buf
         (and (bound-and-true-p shell-maker--busy)
              (null decknix-agent-session-export--tools)
              decknix-agent-session-export--last-activity
              (>= (- (float-time) decknix-agent-session-export--last-activity)
                  decknix-agent-session-export-background-seconds)))))

;; -- snapshot ----------------------------------------------------------

(defun decknix-agent-session-export--agent (buf)
  (ignore-errors
    (let ((id (map-nested-elt (buffer-local-value 'agent-shell--state buf)
                              '(:agent-config :identifier))))
      (and id (format "%s" id)))))

(defun decknix-agent-session-export--closing (buf)
  (ignore-errors
    (or (and (fboundp 'decknix-agent-turn-closing-text)
             (decknix-agent-turn-closing-text buf))
        (buffer-local-value 'decknix--agent-turn-message-tail buf))))

(defun decknix-agent-session-export--sidebar-tags (buf sid)
  "Tags of BUF holding SID, resolved as the sidebar resolves them.
The CLI otherwise sees only store entries that already LIST the session
id, and a fresh or resumed session is often filed under a conv-key whose
entry has not gained it yet, so the CLI read it as untagged while the
sidebar showed its tags.  The store read is cached, so this costs a hash
lookup per sweep."
  (when (fboundp 'decknix--agent-tags-resolve)
    (with-current-buffer buf
      (decknix--agent-tags-resolve
       (and (fboundp 'decknix--agent-current-conv-key)
            (decknix--agent-current-conv-key))
       sid))))

(defun decknix-agent-session-export--tags (buf sid)
  "Exported tag vector for BUF holding SID; empty when the lookup fails."
  (vconcat (seq-filter #'stringp
                       (condition-case nil
                           (funcall decknix-agent-session-export-tags-function buf sid)
                         (error nil)))))

(defun decknix-agent-session-export--plan (buf)
  "BUF's plan as exported: {current, next, done, total}, or :null."
  (let ((p (ignore-errors (funcall decknix-agent-session-export-plan-function buf))))
    (if (and p (plist-get p :total))
        (list :current (decknix-agent-session-export--json-value (plist-get p :current))
              :next (decknix-agent-session-export--json-value (plist-get p :next))
              :done (or (plist-get p :completed) 0)
              :total (plist-get p :total))
      :null)))

(defun decknix-agent-session-export-snapshot (buf sid now)
  "Return the exported plist for BUF holding session SID at NOW."
  (with-current-buffer buf
    (let* ((busy (and (bound-and-true-p shell-maker--busy) t))
           (proc (get-buffer-process buf))
           (status (if (and proc (process-live-p proc))
                       (or (ignore-errors
                             (funcall decknix-agent-session-export-status-function buf))
                           "unknown")
                     "killed"))
           (tools decknix-agent-session-export--tools)
           (activity decknix-agent-session-export--last-activity)
           (quiet (and activity (- now activity)))
           (state (decknix-agent-session-export-state status busy tools quiet))
           (delivered (and (fboundp 'decknix-agent-dispatch-last-delivered)
                           (decknix-agent-dispatch-last-delivered sid)))
           (tool (car tools)))
      (when busy
        (unless decknix-agent-session-export--busy-since
          (setq decknix-agent-session-export--busy-since now)))
      (unless busy (setq decknix-agent-session-export--busy-since nil))
      (unless (equal state decknix-agent-session-export--state)
        (setq decknix-agent-session-export--state state
              decknix-agent-session-export--state-since now))
      (list :v 1 :id sid :buffer (buffer-name buf)
            :agent (decknix-agent-session-export--json-value
                    (decknix-agent-session-export--agent buf))
            :cwd (expand-file-name default-directory)
            :tags (decknix-agent-session-export--tags buf sid)
            :emacs_pid (emacs-pid)
            :state state :status status
            :busy (if busy t :false)
            :busy_since (decknix-agent-session-export--json-value
                         (and decknix-agent-session-export--busy-since
                              (floor decknix-agent-session-export--busy-since)))
            :state_since (floor decknix-agent-session-export--state-since)
            :last_activity (decknix-agent-session-export--json-value
                            (decknix-agent-session-export--bucket activity))
            :tool (if tool
                      (list :name (truncate-string-to-width (cadr tool) 120)
                            :since (floor (cddr tool)))
                    :null)
            :tools_in_flight (length tools)
            :tail (decknix-agent-session-export--json-value
                   (decknix-agent-session-export--tail
                    (decknix-agent-session-export--closing buf)))
            :plan (decknix-agent-session-export--plan buf)
            :queued (list :compose (or (and (fboundp 'decknix--compose-queue-count)
                                            (ignore-errors (decknix--compose-queue-count buf)))
                                       0)
                          :dispatch (or (and (fboundp 'decknix-agent-dispatch-waiting-count)
                                             (decknix-agent-dispatch-waiting-count sid))
                                        0))
            :last_delivered (if delivered
                                (list :id (plist-get delivered :id)
                                      :at (plist-get delivered :at)
                                      :from (decknix-agent-session-export--json-value
                                             (plist-get delivered :from)))
                              :null)))))

(defun decknix-agent-session-export--dead (snapshot now)
  "SNAPSHOT of a session whose buffer has gone, as written once at NOW."
  (let ((s (copy-sequence snapshot)))
    (setq s (plist-put s :state "dead"))
    (setq s (plist-put s :status "killed"))
    (setq s (plist-put s :busy :false))
    (setq s (plist-put s :busy_since :null))
    (setq s (plist-put s :tool :null))
    (setq s (plist-put s :tools_in_flight 0))
    (plist-put s :state_since (floor now))))

;; -- writing -----------------------------------------------------------

(defun decknix-agent-session-export--file (name)
  (expand-file-name name decknix-agent-session-export-dir))

(defun decknix-agent-session-export--ensure-dir ()
  (unless (file-directory-p decknix-agent-session-export-dir)
    (make-directory decknix-agent-session-export-dir t))
  (set-file-modes decknix-agent-session-export-dir #o700))

(defun decknix-agent-session-export--write (name plist &optional force)
  (with-file-modes #o600
    (funcall decknix-agent-session-export-write-function
             (decknix-agent-session-export--file name)
             (concat (json-serialize plist) "\n")
             force)))

(defun decknix-agent-session-export--heartbeat (now)
  (setq decknix-agent-session-export--heartbeat-at now)
  (let ((state (and (fboundp 'decknix-agent-dispatch-state)
                    (ignore-errors (decknix-agent-dispatch-state))))
        (bool (lambda (v) (if v t :false))))
    (decknix-agent-session-export--write
     "_emacs.json"
     (list :v 1 :pid (emacs-pid) :at (floor now)
           :interval decknix-agent-session-export-heartbeat-interval
           :receiver (funcall bool (bound-and-true-p decknix-agent-dispatch-mode))
           :armed_at (or (plist-get state :armed_at) :null)
           :armed_by (or (plist-get state :armed_by) :null)
           :control (funcall bool (bound-and-true-p decknix-agent-dispatch-control-mode))
           :remote_control (funcall bool (and (boundp 'decknix-agent-dispatch-remote-control)
                                              decknix-agent-dispatch-remote-control)))
     t)))

(defun decknix-agent-session-export-heartbeat-now ()
  "Rewrite the heartbeat at once, so a CLI waiting on a receiver change sees it.
Run from `decknix-agent-dispatch-mode-hook'; does nothing while the export
is off."
  (when (bound-and-true-p decknix-agent-session-export-mode)
    (ignore-errors
      (decknix-agent-session-export--ensure-dir)
      (decknix-agent-session-export--heartbeat (float-time)))))

(defun decknix-agent-session-export-sweep (&optional now)
  "Write every live session's state file that changed, and the heartbeat."
  (let ((now (or now (float-time)))
        (live nil))
    (decknix-agent-session-export--ensure-dir)
    (dolist (buf (funcall decknix-agent-session-export-buffers-function))
      (when (buffer-live-p buf)
        (let ((sid (ignore-errors
                     (funcall decknix-agent-session-export-session-id-function buf))))
          (when (and (stringp sid) (string-match-p "\\`[0-9a-zA-Z_-]+\\'" sid))
            (condition-case err
                (let ((snap (decknix-agent-session-export-snapshot buf sid now)))
                  (push sid live)
                  (decknix-agent-session-export--write (concat sid ".json") snap)
                  (puthash sid snap decknix-agent-session-export--written))
              (error (message "decknix-agent-session-export: %s: %s"
                              (buffer-name buf) (error-message-string err))))))))
    (maphash (lambda (sid snap)
               (unless (member sid live)
                 (unless (equal "dead" (plist-get snap :state))
                   (let ((dead (decknix-agent-session-export--dead snap now)))
                     (ignore-errors
                       (decknix-agent-session-export--write (concat sid ".json") dead))
                     (puthash sid dead decknix-agent-session-export--written)))))
             decknix-agent-session-export--written)
    (when (>= (- now decknix-agent-session-export--heartbeat-at)
              decknix-agent-session-export-heartbeat-interval)
      (decknix-agent-session-export--heartbeat now))
    live))

(defun decknix-agent-session-export--next-delay (duration)
  "Seconds until the next sweep after one that took DURATION seconds."
  (max decknix-agent-session-export-interval (* 20 duration)))

(defun decknix-agent-session-export--run ()
  (let ((start (float-time)))
    (condition-case err
        (decknix-agent-session-export-sweep start)
      (error (message "decknix-agent-session-export: sweep failed: %s"
                      (error-message-string err))))
    (when decknix-agent-session-export-mode
      (setq decknix-agent-session-export--timer
            (run-with-timer (decknix-agent-session-export--next-delay
                             (- (float-time) start))
                            nil #'decknix-agent-session-export--run)))))

(defun decknix-agent-session-export--pid-live-p (pid)
  (and (integerp pid) (> pid 0)
       (or (= pid (emacs-pid))
           (memq pid (list-system-processes)))))

(defun decknix-agent-session-export--prune ()
  "Delete state files left by an Emacs that is no longer running."
  (dolist (f (directory-files decknix-agent-session-export-dir t "\\`[^_.].*\\.json\\'"))
    (let ((pid (ignore-errors
                 (with-temp-buffer
                   (insert-file-contents f)
                   (plist-get (json-parse-string (buffer-string) :object-type 'plist)
                              :emacs_pid)))))
      (unless (and pid (not (= pid (emacs-pid)))
                   (decknix-agent-session-export--pid-live-p pid))
        (ignore-errors (delete-file f))))))

;;;###autoload
(define-minor-mode decknix-agent-session-export-mode
  "Export live agent session state to `decknix-agent-session-export-dir'.
Read-only observability for `decknix session status': nothing is sent to
any session, and turning the mode off stops the writes."
  :global t
  :lighter nil
  :group 'decknix-agent-session-export
  (when (timerp decknix-agent-session-export--timer)
    (cancel-timer decknix-agent-session-export--timer))
  (setq decknix-agent-session-export--timer nil)
  (when decknix-agent-session-export-mode
    (decknix-agent-session-export--ensure-dir)
    (ignore-errors (decknix-agent-session-export--prune))
    (clrhash decknix-agent-session-export--written)
    (setq decknix-agent-session-export--heartbeat-at 0)
    (setq decknix-agent-session-export--timer
          (run-with-timer 1 nil #'decknix-agent-session-export--run))))

(provide 'decknix-agent-session-export)
;;; decknix-agent-session-export.el ends here
