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

(defun decknix--compose-wait-decision (busy-p elapsed budget &optional min-settle)
  "Return the next action for the wait-not-busy poller.

BUSY-P is the caller-evaluated `shell-maker--busy' state of the
target buffer.  ELAPSED is the seconds since the wait started.
BUDGET is the timeout ceiling in seconds.  MIN-SETTLE (default 0)
is a floor: after an interrupt we must give the agent a real gap
to process the ACP cancel before the new prompt is sent.

This matters because `agent-shell-interrupt' clears
`shell-maker--busy' SYNCHRONOUSLY (via `shell-maker-interrupt'),
so a plain not-busy check fires on the very first poll — sending
the new prompt in the same instant as the cancel, which the agent
can conflate (the message appears to be posted, THEN interrupted).
The MIN-SETTLE floor holds the submit for a beat so the cancel
lands first.

Result:
  `fire'      -- ready: budget reached, or (not busy AND settled)
  `continue'  -- still busy, or not yet settled; poll again

The caller is responsible for the side-effects (cancelling the
timer, invoking the callback, scheduling the next tick).  This
function never touches a timer, buffer, or process.

Decision table:

  elapsed >= budget | busy-p | elapsed >= min-settle | result
  ------------------+--------+-----------------------+----------
        t           |   *    |          *            | fire
        nil         |  nil   |          t            | fire
        nil         |  nil   |         nil           | continue
        nil         |   t    |          *            | continue"
  (cond
   ((>= elapsed budget)                          'fire)
   ((and (not busy-p) (>= elapsed (or min-settle 0))) 'fire)
   (t                                            'continue)))

(defvar decknix-compose-interrupt-settle 0.6
  "Seconds to hold a post-interrupt submit after the agent reports idle.
`agent-shell-interrupt' clears `shell-maker--busy' synchronously, so without a
floor the new prompt is sent in the same instant as the ACP cancel and the
agent can action it before the interrupt lands.  This gap lets the cancel be
processed first, so the sequence is interrupt-then-submit.  The 2 s wait budget
still caps the total delay.")

(defun decknix--compose-wait-not-busy (target on-ready
                                              &optional timeout interval min-settle)
  "Poll TARGET's `shell-maker--busy' flag, then call ON-READY.

TARGET is the agent-shell buffer (or buffer-name) whose busy
flag drives the wait.  ON-READY is a zero-arg function called
exactly once -- either when busy clears AND MIN-SETTLE seconds
have elapsed (so the agent has processed the prior interrupt) or
after TIMEOUT seconds (a safety net for a wedged process).
TIMEOUT defaults to 2.0; INTERVAL (the poll cadence) defaults to
0.05; MIN-SETTLE defaults to `decknix-compose-interrupt-settle'.

Returns the active timer object.  Callers usually discard it --
the helper self-cancels on fire.

This replaces the fixed `sit-for 0.3' / `run-at-time 0.3' dance
in the three compose / review interrupt-then-submit flows.  The
settle floor is essential: `shell-maker-interrupt' clears
`shell-maker--busy' synchronously, so a plain not-busy check
would fire immediately and race the cancel."
  (let* ((budget (or timeout 2.0))
         (step   (or interval 0.05))
         (settle (or min-settle decknix-compose-interrupt-settle))
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
                             busy elapsed budget settle)))
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
