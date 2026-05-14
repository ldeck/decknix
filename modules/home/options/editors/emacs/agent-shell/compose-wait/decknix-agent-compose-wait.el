;;; decknix-agent-compose-wait.el --- Async wait for agent busy flag to clear -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, compose, wait

;;; Commentary:
;;
;; Async polling helper for the compose / review interrupt-then-
;; submit flows.  Previous versions slept a fixed 0.3 s after
;; `agent-shell-interrupt' before calling `shell-maker-submit',
;; which lost the race when the agent's interrupt acknowledgement
;; arrived after that budget -- the new prompt landed in the
;; agent-shell buffer ahead of the "[interrupted]" marker.
;;
;; This module polls `shell-maker--busy' (set by shell-maker on
;; turn-start, cleared on turn-end / interrupt-ack) and only fires
;; the supplied callback when the flag clears, with a safety-net
;; timeout so a wedged process can't strand the caller forever.
;;
;; Two public functions:
;;
;;   `decknix--compose-wait-decision' (BUSY-P ELAPSED BUDGET)
;;       Pure decision: returns `fire' or `continue' from the
;;       three caller-evaluated signals.  Carved out from the
;;       async function so the policy can be exercised by ERT
;;       without spinning up timers.
;;
;;   `decknix--compose-wait-not-busy' (TARGET ON-READY
;;                                     &optional TIMEOUT INTERVAL)
;;       Side-effecting wait.  Polls TARGET's buffer-local
;;       `shell-maker--busy' every INTERVAL seconds (default
;;       0.05); calls ON-READY once when the flag clears or
;;       once after TIMEOUT seconds (default 2.0), whichever
;;       comes first.  Returns the current timer object.
;;
;; Per AGENTS.md Rule 2 the decision is pure (testable in
;; isolation); the wait-and-fire wiring is the side-effecting
;; adapter that consumes it.

;;; Code:

(require 'cl-lib)

;; `shell-maker--busy' is a buffer-local from the external
;; shell-maker package; forward-declare so byte-compile stays
;; warning-clean.  Resolved at runtime in the daemon's load-path.
(defvar shell-maker--busy)

(defun decknix--compose-wait-decision (busy-p elapsed budget)
  "Return the next action for the wait-not-busy poller.

BUSY-P is the caller-evaluated `shell-maker--busy' state of the
target buffer.  ELAPSED is the seconds since the wait started.
BUDGET is the timeout ceiling in seconds.

Result:
  `fire'      -- ready: busy cleared, or budget reached
  `continue'  -- still busy and within budget; poll again

The caller is responsible for the side-effects (cancelling the
timer, invoking the callback, scheduling the next tick).  This
function never touches a timer, buffer, or process.

Decision table:

  busy-p | elapsed >= budget | result
  -------+-------------------+----------
  nil    |        *          | fire
  t      |        nil        | continue
  t      |        t          | fire"
  (cond
   ((not busy-p)        'fire)
   ((>= elapsed budget) 'fire)
   (t                   'continue)))

(defun decknix--compose-wait-not-busy (target on-ready
                                              &optional timeout interval)
  "Poll TARGET's `shell-maker--busy' flag, then call ON-READY.

TARGET is the agent-shell buffer (or buffer-name) whose busy
flag drives the wait.  ON-READY is a zero-arg function called
exactly once -- either when busy clears (the agent has
acknowledged the prior interrupt) or after TIMEOUT seconds have
elapsed (a safety net for a wedged process).  TIMEOUT defaults
to 2.0; INTERVAL (the poll cadence) defaults to 0.05.

Returns the active timer object.  Callers usually discard it --
the helper self-cancels on fire.

This replaces the fixed `sit-for 0.3' / `run-at-time 0.3' dance
in the three compose / review interrupt-then-submit flows so the
new prompt is guaranteed to be ordered AFTER the agent's
\"[interrupted]\" marker in the buffer."
  (let* ((budget (or timeout 2.0))
         (step   (or interval 0.05))
         (start  (float-time))
         (called nil)
         (timer  nil))
    (cl-labels
        ((tick ()
           (let* ((busy (and (buffer-live-p target)
                             (with-current-buffer target
                               (bound-and-true-p shell-maker--busy))))
                  (elapsed (- (float-time) start))
                  (decision (decknix--compose-wait-decision
                             busy elapsed budget)))
             (pcase decision
               ('fire
                (unless called
                  (setq called t)
                  (when (timerp timer)
                    (cancel-timer timer))
                  (funcall on-ready)))
               ('continue
                (setq timer (run-at-time step nil #'tick)))))))
      (setq timer (run-at-time 0 nil #'tick))
      timer)))

(provide 'decknix-agent-compose-wait)
;;; decknix-agent-compose-wait.el ends here
