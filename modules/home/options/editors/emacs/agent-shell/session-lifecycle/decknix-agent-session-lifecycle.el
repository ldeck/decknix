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

;; --- windows a closing session leaves behind ---------------------------
;;
;; `kill-buffer' hands each window that showed the buffer to
;; `switch-to-prev-buffer', which happily picks a buffer another window
;; already shows.  A session opened from the Review Board splits off a
;; window whose only history is the board, so closing it put the board in
;; that window too.  And `decknix-agent-session-quit' then switched the
;; SELECTED window to another session, which from the auto-close timer is
;; whatever window you happen to be in: usually the board itself.

(declare-function agent-shell-workspace--agent-buffer-p "agent-shell-workspace" (buffer))
(declare-function agent-shell-workspace--in-agents-tab-p "agent-shell-workspace" ())
(defvar agent-shell-workspace--isolation-active)

(defun decknix-session-lifecycle-pick-buffer (candidates doomed elsewhere allowed-p)
  "Return the first of CANDIDATES a window can show once DOOMED is gone.  Pure.
Skips DOOMED, killed buffers, buffers in ELSEWHERE (shown by another
window of the same frame) and buffers ALLOWED-P rejects."
  (seq-find (lambda (b)
              (and (buffer-live-p b)
                   (not (eq b doomed))
                   (not (memq b elsewhere))
                   (funcall allowed-p b)))
            candidates))

(defun decknix-session-lifecycle--allowed-p ()
  "Return the predicate for buffers a released window may show.
Inside the isolated Agents tab only agent buffers, the rule its own
`switch-to-buffer' advice enforces and `set-window-buffer' would bypass."
  (if (and (bound-and-true-p agent-shell-workspace--isolation-active)
           (fboundp 'agent-shell-workspace--in-agents-tab-p)
           (fboundp 'agent-shell-workspace--agent-buffer-p)
           (agent-shell-workspace--in-agents-tab-p))
      #'agent-shell-workspace--agent-buffer-p
    (lambda (b) (not (string-prefix-p " " (buffer-name b))))))

(defun decknix-session-lifecycle--split-for-p (window buffer)
  "Non-nil when WINDOW was split off to show BUFFER and has shown nothing else."
  (let ((quit-restore (window-parameter window 'quit-restore)))
    (and (eq (car quit-restore) 'window)
         (eq (nth 3 quit-restore) buffer)
         (not (seq-some (lambda (entry)
                          (and (buffer-live-p (car entry))
                               (not (eq (car entry) buffer))))
                        (window-prev-buffers window)))
         (eq t (window-deletable-p window)))))

(defun decknix-session-lifecycle--show (window buffer)
  "Show BUFFER in WINDOW where WINDOW last left it, if it showed it before."
  (let ((entry (assq buffer (window-prev-buffers window))))
    (if entry
        (set-window-buffer-start-and-point window buffer (nth 1 entry) (nth 2 entry))
      (set-window-buffer window buffer))))

(defun decknix-session-lifecycle-release-windows (buffer &optional sessions)
  "Move every window showing BUFFER off it, ahead of killing BUFFER.

A window split off for BUFFER that has shown nothing else is deleted, as
`quit-window' would.  Any other window goes back to what it showed before
BUFFER, else to the first of SESSIONS (live sessions, most recent first),
skipping anything another window of its frame already shows.  Only when
every session is already on screen may one be shown twice; a non-session
buffer, the Review Board above all, never is.  Windows not showing BUFFER
are never touched, so closing a session in the background moves nothing."
  (let ((allowed (decknix-session-lifecycle--allowed-p)))
    (dolist (win (get-buffer-window-list buffer 'nomini t))
      (when (window-live-p win)
        (if (decknix-session-lifecycle--split-for-p win buffer)
            (delete-window win)
          (let* ((elsewhere (delq nil (mapcar (lambda (w)
                                                (unless (eq w win) (window-buffer w)))
                                              (window-list (window-frame win) 'nomini))))
                 (prev (mapcar #'car (window-prev-buffers win)))
                 (next (or (decknix-session-lifecycle-pick-buffer
                            (append prev sessions) buffer elsewhere allowed)
                           (decknix-session-lifecycle-pick-buffer
                            sessions buffer nil allowed)
                           (other-buffer buffer nil (window-frame win)))))
            (decknix-session-lifecycle--show win next)))))))

(defun decknix-session-lifecycle--other-sessions (buffers)
  "Return the live agent sessions not in BUFFERS, most recent first."
  (when (fboundp 'agent-shell-buffers)
    (seq-remove (lambda (b) (memq b buffers)) (agent-shell-buffers))))

(defun decknix-session-lifecycle-kill-buffer (buffer &optional sessions)
  "Kill BUFFER without asking, first moving its windows somewhere sensible.

SESSIONS are the sessions its windows may fall back to (see
`decknix-session-lifecycle-release-windows'); by default every other live
one.  `kill-buffer-query-functions' is suppressed because the caller has
already confirmed the whole set: a per-buffer prompt after a bulk
confirmation is the drift that made the two boards behave differently."
  (when (buffer-live-p buffer)
    (ignore-errors
      (decknix-session-lifecycle-release-windows
       buffer (or sessions (decknix-session-lifecycle--other-sessions (list buffer))))))
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
                       live (decknix-session-lifecycle--broker-alist)))
              (spared (decknix-session-lifecycle--other-sessions live)))
          (dolist (buf live)
            (let ((key (decknix-session-lifecycle--broker-key buf)))
              (when (and key
                         (fboundp 'decknix--agent-broker-stop-p)
                         (decknix--agent-broker-stop-p key others))
                (ignore-errors (decknix-agent-broker-stop key))))
            (decknix-session-lifecycle-kill-buffer buf spared)))
        (length live)))))

(defun decknix-session-lifecycle-detach (buffers)
  "Detach BUFFERS, leaving their agents running.  Returns the number detached.

No confirmation: detaching is reversible and the agent keeps working, which
is the whole difference from quitting."
  (let* ((live (seq-filter #'buffer-live-p buffers))
         (spared (decknix-session-lifecycle--other-sessions live)))
    (dolist (buf live) (decknix-session-lifecycle-kill-buffer buf spared))
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
