;;; decknix-hub-sidebar-paint.el --- Coalesced idle repaint for the sidebar -*- lexical-binding: t -*-

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;;
;; The workspace sidebar repaints (erase + rebuild the whole buffer) on
;; an upstream 2-second `run-with-timer' tick, on every hub file-notify
;; event, and on many user actions -- all by calling
;; `agent-shell-workspace-sidebar-refresh' synchronously.  Even after the
;; render tick was made disk-free (see `decknix-hub-path-facts'), that
;; full repaint is ~100+ ms of consing, and firing it mid-keystroke is
;; felt as a hitch: you type, nothing moves, then it catches up.
;;
;; This module defers and COALESCES every repaint request onto a single
;; short-idle timer.  A burst of refresh calls (2 s tick + file-notify +
;; a user action, all within the same active moment) collapses to ONE
;; paint that fires the instant the user pauses -- never while a key is
;; pending.  Continuous typing therefore produces zero paints; a single
;; catch-up paint runs on the next idle gap.
;;
;; Correct-by-construction: each scheduled paint still runs the full,
;; unmodified `agent-shell-workspace-sidebar-refresh', so the rendered
;; content is never stale -- only its timing moves off the keystroke.
;;
;; Wiring lives in the heredoc (see `agent-shell.nix'): the named
;; `decknix--sidebar-refresh-debounce-advice' is attached as the
;; outermost `:around' advice on `agent-shell-workspace-sidebar-refresh'.
;; A named function keeps the advice idempotent across hot-reloads
;; (re-`advice-add' of the same symbol is a no-op), unlike an anonymous
;; lambda which would accumulate a new debounce layer on every reload.

;;; Code:

;; Provided by the upstream `agent-shell-workspace' package; only ever
;; called through the advice, so a forward declaration is enough.
(declare-function agent-shell-workspace-sidebar-refresh "ext:agent-shell-workspace")

(defvar decknix-sidebar-paint-idle-delay 0.6
  "Idle seconds to wait before repainting the sidebar after a request.
Small enough to feel near-immediate on a natural typing pause, large
enough that it never fires between two consecutive keystrokes.  Raised
from 0.3 to 0.6 so a brief think-pause mid-typing no longer triggers the
~100ms repaint in front of the next keystroke; the paint tick also
re-defers when input is pending (see `decknix--sidebar-paint-tick').")

(defvar decknix--sidebar-paint-timer nil
  "The single pending coalesced repaint timer, or nil when none is armed.")

(defvar decknix--sidebar-paint-in-progress nil
  "Non-nil only while the idle worker is driving the real repaint.
Bound dynamically by `decknix--sidebar-paint-now' so the debounce advice
lets that real paint through to the underlying refresh instead of
re-deferring it into another idle cycle.")

(defun decknix--sidebar-paint-through-p ()
  "Return non-nil when a refresh call must paint now instead of deferring."
  decknix--sidebar-paint-in-progress)

(defun decknix--sidebar-cancel-paint ()
  "Cancel any pending coalesced repaint and clear the timer slot."
  (when (timerp decknix--sidebar-paint-timer)
    (cancel-timer decknix--sidebar-paint-timer))
  (setq decknix--sidebar-paint-timer nil))

(defun decknix--sidebar-schedule-paint (paint-fn)
  "Coalesce a repaint: cancel any prior pending one and arm PAINT-FN on idle.
Because each request replaces the previous pending timer, a burst of
requests collapses to a single PAINT-FN invocation once the user pauses
for `decknix-sidebar-paint-idle-delay' seconds."
  (decknix--sidebar-cancel-paint)
  (setq decknix--sidebar-paint-timer
        (run-with-idle-timer decknix-sidebar-paint-idle-delay nil paint-fn)))

(defun decknix--sidebar-paint-now (refresh-fn)
  "Run REFRESH-FN as the real synchronous repaint.
Clears the pending-timer slot and holds `decknix--sidebar-paint-in-progress'
non-nil for the duration so the debounce advice paints through rather than
re-deferring.  Errors in REFRESH-FN are swallowed so a single bad paint
cannot leave the guard stuck."
  (setq decknix--sidebar-paint-timer nil)
  (let ((decknix--sidebar-paint-in-progress t))
    (ignore-errors (funcall refresh-fn))))

(defun decknix--sidebar-paint-tick ()
  "Idle-timer entry point: perform the real sidebar repaint.
If the user has resumed typing by the moment the idle timer fires
\(`input-pending-p'), re-defer onto a fresh idle timer rather than run
the ~100ms synchronous paint ahead of that queued keystroke.  The paint
then lands on the next genuine pause, so continuous typing yields zero
paints and never a visible input hitch."
  (if (input-pending-p)
      (decknix--sidebar-schedule-paint #'decknix--sidebar-paint-tick)
    (decknix--sidebar-paint-now #'agent-shell-workspace-sidebar-refresh)))

(defun decknix--sidebar-refresh-debounce-advice (orig-fn &rest args)
  "Around-advice for `agent-shell-workspace-sidebar-refresh'.
Paint through to ORIG-FN (with ARGS) when the idle worker is already
driving the real repaint; otherwise coalesce this request onto the
short-idle paint timer and return immediately, so no repaint ever runs
between keystrokes."
  (if (decknix--sidebar-paint-through-p)
      (apply orig-fn args)
    (decknix--sidebar-schedule-paint #'decknix--sidebar-paint-tick)))

(provide 'decknix-hub-sidebar-paint)
;;; decknix-hub-sidebar-paint.el ends here
