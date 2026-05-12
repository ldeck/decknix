;;; decknix-agent-compose-queue.el --- Compose-queue policy resolver -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, compose, queue

;;; Commentary:
;;
;; Pure policy helper for the compose-buffer auto-submit queue
;; (PR B.79).  Carved out of `decknix--compose-queue-poll' so the
;; "should I cancel / submit / wait" decision can be exercised
;; without a comint buffer or a live timer.
;;
;; Public surface (one pure function):
;;
;;   (decknix--compose-queue-action QUEUED-PROMPT BUFFER-LIVE-P
;;                                   BUSY-P PROCESS-LIVE-P)
;;     -> (:action 'cancel-timer)              ; buffer killed
;;      | (:action 'submit :input STR)         ; idle + queued + alive
;;      | (:action 'wait)                      ; nothing to do
;;
;; The bulk caller `pcase's on `:action' and applies the
;; corresponding side-effect (cancel-timer / shell-maker-submit /
;; no-op).  Per AGENTS.md Rule 2 those side-effects stay in
;; main-bulk; this module is pure decision logic.
;;
;; Decision table (mirrors the original `if'/`when' nesting):
;;
;;   buffer-live? | queued? | busy? | process-live? | action
;;   -------------+---------+-------+---------------+----------------
;;   nil          |   *     |   *   |     *         | cancel-timer
;;   t            |  nil    |   *   |     *         | wait
;;   t            |  set    |   t   |     *         | wait
;;   t            |  set    |  nil  |    nil        | wait
;;   t            |  set    |  nil  |     t         | submit :input

;;; Code:

(defun decknix--compose-queue-action (queued-prompt buffer-live-p
                                                    busy-p process-live-p)
  "Return the next action for the compose-queue poller as a plist.

QUEUED-PROMPT is the pending prompt string (nil when nothing
queued).  BUFFER-LIVE-P, BUSY-P and PROCESS-LIVE-P are the
caller-evaluated predicates: whether the agent-shell buffer is
alive, whether `shell-maker--busy' is set, and whether the buffer
process is live.

Result:
  (:action cancel-timer)              -- buffer dead, drop the timer
  (:action submit :input STR)         -- idle + queued + alive
  (:action wait)                      -- otherwise (busy / no queue / no proc)

The caller is responsible for performing the side-effect
indicated by `:action'.  This function never touches a buffer,
timer, or process."
  (cond
   ((not buffer-live-p)
    (list :action 'cancel-timer))
   ((and queued-prompt
         (not busy-p)
         process-live-p)
    (list :action 'submit :input queued-prompt))
   (t
    (list :action 'wait))))

(provide 'decknix-agent-compose-queue)
;;; decknix-agent-compose-queue.el ends here
