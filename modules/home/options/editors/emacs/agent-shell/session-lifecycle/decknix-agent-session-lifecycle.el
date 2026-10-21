;;; decknix-agent-session-lifecycle.el --- Shared bulk quit/detach -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, sessions

;;; Commentary:
;;
;; One implementation of "end these sessions" and "detach these sessions",
;; shared by the Review Board and the Session Board.
;;
;; The two boards are duals rather than duplicates -- the Review Board's rows
;; are PRs (and it has an `idle' lane for PRs with no session at all), the
;; Session Board's rows are sessions -- so neither subsumes the other.  What
;; WAS duplicated is this: the broker-stop rule, the confirmation, and the
;; kill.  Two copies of a destructive routine is one too many, and they had
;; already drifted: the Review Board suppressed
;; `kill-buffer-query-functions' while the Session Board did not, so the same
;; bulk action prompted per buffer from one board and not the other.
;;
;; The broker rule is the part that must not be re-derived. Under brokering a
;; buffer's process is only the socat client, so `kill-buffer' DETACHES and
;; leaves the agent running -- one was found alive two hours after its buffer
;; closed. Quitting therefore stops the broker as well, but only when no
;; OTHER live session is attached to it.
;;
;; Discard is the same quit offered as a command on one session (the
;; sidebar row, the current buffer, or ones picked by name), because the
;; broker a plain kill leaves running is reattached on the next start.

;;; Code:

(require 'seq)

(declare-function agent-shell-buffers "agent-shell" ())

;; Owned by the broker layer.  Declared AND read through
;; `decknix-session-lifecycle--broker-key', because `buffer-local-value'
;; SIGNALS void-variable when the variable has no value -- which it does not
;; in an isolated package build, where nothing has loaded the broker. The
;; full suite hid that: other modules were loaded, so the variable existed.
(defvar decknix--agent-broker-key)
(declare-function decknix-agent-broker-stop "decknix-agent-shell-main" (key))
(declare-function decknix--agent-broker-stop-p
                  "decknix-agent-session-broker" (key others))

;; --- pure ------------------------------------------------------------

(defun decknix-session-lifecycle-surviving-keys (doomed all)
  "Return the broker keys still in use once DOOMED is gone.

ALL is an alist of (BUFFER . BROKER-KEY) for every live session; DOOMED a
list of buffers about to be quit.  Pure, so the rule that decides whether a
broker is shared can be tested without processes.

Nil keys are dropped: a session with no broker contributes no claim, and
keeping nil in the list would make `decknix--agent-broker-stop-p' compare
against it."
  (delete-dups
   (delq nil
         (mapcar (lambda (cell)
                   (unless (memq (car cell) doomed) (cdr cell)))
                 all))))

(defun decknix-session-lifecycle-prompt (n)
  "Return the confirmation prompt for quitting N sessions."
  (format "Quit %d session%s and terminate their brokers? "
          n (if (= 1 n) "" "s")))

;; --- side effects -----------------------------------------------------

(defun decknix-session-lifecycle--broker-key (buffer)
  "Return BUFFER's broker key, or nil when it has none.

`local-variable-p' rather than a bare `buffer-local-value': the latter
signals `void-variable' when nothing has defined the variable, so a session
with no broker -- or a build where the broker layer is absent -- became an
error instead of a nil."
  (and (buffer-live-p buffer)
       (local-variable-p 'decknix--agent-broker-key buffer)
       (buffer-local-value 'decknix--agent-broker-key buffer)))

(defun decknix-session-lifecycle--broker-alist ()
  "Return (BUFFER . BROKER-KEY) for every live agent session."
  (when (fboundp 'agent-shell-buffers)
    (mapcar (lambda (b) (cons b (decknix-session-lifecycle--broker-key b)))
            (agent-shell-buffers))))

(defun decknix-session-lifecycle-kill-buffer (buffer)
  "Kill BUFFER without asking.

`kill-buffer-query-functions' is suppressed because the caller has already
confirmed the whole set: a per-buffer prompt after a bulk confirmation is
the drift that made the two boards behave differently."
  (let ((kill-buffer-query-functions nil))
    (ignore-errors (kill-buffer buffer))))

(defun decknix-session-lifecycle-quit (buffers &optional noconfirm)
  "Quit BUFFERS, terminating each broker no other session is attached to.

Confirms with a count unless NOCONFIRM.  Returns the number quit, or nil
when the user declined -- so a caller can tell a refusal from an empty set
and report accordingly."
  (let ((live (seq-filter #'buffer-live-p buffers)))
    (when live
      (if (and (not noconfirm)
               (not (yes-or-no-p (decknix-session-lifecycle-prompt (length live)))))
          nil
        (let ((others (decknix-session-lifecycle-surviving-keys
                       live (decknix-session-lifecycle--broker-alist))))
          (dolist (buf live)
            (let ((key (decknix-session-lifecycle--broker-key buf)))
              (when (and key
                         (fboundp 'decknix--agent-broker-stop-p)
                         (decknix--agent-broker-stop-p key others))
                (ignore-errors (decknix-agent-broker-stop key))))
            (decknix-session-lifecycle-kill-buffer buf)))
        (length live)))))

(defun decknix-session-lifecycle-detach (buffers)
  "Detach BUFFERS, leaving their agents running.  Returns the number detached.

No confirmation: detaching is reversible and the agent keeps working, which
is the whole difference from quitting."
  (let ((live (seq-filter #'buffer-live-p buffers)))
    (dolist (buf live) (decknix-session-lifecycle-kill-buffer buf))
    (length live)))

;; --- discard: the interactive face of quit ----------------------------
;;
;; `kill-buffer' (C-x k) keeps detach semantics on purpose: stepping away
;; from a session must not end the agent.  But the broker it leaves running
;; is reattached by the next daemon start, so a session killed that way
;; comes back after every restart.  Discard is the explicit "I am done with
;; this one": broker stopped, buffer gone, nothing to reattach.

(declare-function agent-shell-workspace-sidebar--buffer-at-point
                  "agent-shell-workspace" ())
(declare-function agent-shell-workspace-sidebar-refresh
                  "agent-shell-workspace" ())

(defun decknix-session-lifecycle-discard-prompt (buffers)
  "Return the confirmation prompt for discarding BUFFERS.  Pure."
  (format "Discard %s? Its agent is stopped and will not reattach on restart. "
          (if (cdr buffers)
              (format "%d sessions" (length buffers))
            (buffer-name (car buffers)))))

(defun decknix-session-lifecycle-discard (buffers)
  "Confirm, then quit BUFFERS and stop their brokers.  Returns the count.
Nil when declined or when nothing is live."
  (let ((live (seq-filter #'buffer-live-p buffers)))
    (when (and live (yes-or-no-p (decknix-session-lifecycle-discard-prompt live)))
      (prog1 (decknix-session-lifecycle-quit live t)
        (when (fboundp 'agent-shell-workspace-sidebar-refresh)
          (ignore-errors (agent-shell-workspace-sidebar-refresh)))))))

(defun decknix-session-lifecycle--report-discard (n)
  (message (if n (format "decknix: discarded %d session%s" n (if (= n 1) "" "s"))
             "decknix: nothing discarded")))

;;;###autoload
(defun decknix-agent-session-discard (buffers)
  "Discard BUFFERS: stop each one's agent broker and kill the buffer.
Interactively the current session, or sessions chosen from the live ones
when not in a session buffer.  Unlike \\[kill-buffer], which only
detaches and leaves the agent to be reattached on the next start, a
discarded session is gone for good."
  (interactive
   (list (if (derived-mode-p 'agent-shell-mode)
             (list (current-buffer))
           (let ((names (completing-read-multiple
                         "Discard sessions: "
                         (mapcar #'buffer-name
                                 (and (fboundp 'agent-shell-buffers) (agent-shell-buffers)))
                         nil t)))
             (or (delq nil (mapcar #'get-buffer names))
                 (user-error "No session chosen"))))))
  (decknix-session-lifecycle--report-discard
   (decknix-session-lifecycle-discard buffers)))

;;;###autoload
(defun decknix-sidebar-discard-at-point ()
  "Discard the session on the sidebar row at point.
See `decknix-agent-session-discard'.  Reads the row through
`agent-shell-workspace-sidebar--buffer-at-point', which decknix
overrides to read the sidebar buffer itself: the `a' menu has already
moved focus to the main window when this runs."
  (interactive)
  (let ((buf (and (fboundp 'agent-shell-workspace-sidebar--buffer-at-point)
                  (agent-shell-workspace-sidebar--buffer-at-point))))
    (unless (buffer-live-p buf)
      (user-error "No live session on this row"))
    (decknix-session-lifecycle--report-discard
     (decknix-session-lifecycle-discard (list buf)))))

(provide 'decknix-agent-session-lifecycle)
;;; decknix-agent-session-lifecycle.el ends here
