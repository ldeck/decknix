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

(provide 'decknix-agent-session-lifecycle)
;;; decknix-agent-session-lifecycle.el ends here
