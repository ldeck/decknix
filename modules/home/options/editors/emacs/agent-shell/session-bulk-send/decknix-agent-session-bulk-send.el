;;; decknix-agent-session-bulk-send.el --- Pure planner for bulk prompt dispatch -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix

;;; Commentary:
;;
;; Pure planning helper for multi-session bulk send.  Takes a list of
;; live agent-shell buffers and a caller-supplied busy predicate, and
;; returns a partition of those buffers into two groups:
;;
;;   :send-now  — buffers whose agent is currently idle; the caller
;;                should submit the prompt immediately via
;;                `decknix--compose-submit-after-wait'.
;;   :enqueue   — buffers whose agent is busy; the caller should
;;                queue the prompt via `decknix--compose-enqueue-prompt'
;;                so it fires automatically when the agent becomes idle.
;;
;; Staggering the dispatch this way avoids saturating the upload link
;; with simultaneous large context payloads — the root cause of 408
;; Request Timeout responses when many sessions are sending at once.
;;
;; This module has no side effects: it does not touch any buffer, timer,
;; or global state.  The split-and-dispatch pattern lets the
;; characterisation tests exercise the routing logic via `cl-letf'
;; without spinning up real agent processes or timers.
;;
;; Call site (main-bulk):
;;
;;   (let* ((plan (decknix--session-bulk-send-plan bufs #'my-busy-p))
;;          (idle  (plist-get plan :send-now))
;;          (busy  (plist-get plan :enqueue)))
;;     (dolist (b idle)  (decknix--compose-submit-after-wait b input))
;;     (dolist (b busy)  (decknix--compose-enqueue-prompt    b input)))

;;; Code:

(defun decknix--session-bulk-send-plan (bufs busy-fn)
  "Partition BUFS into send-now and enqueue lists based on BUSY-FN.
BUFS is a list of live agent-shell buffers.  BUSY-FN is a
one-argument predicate called with each buffer: non-nil means the
agent in that buffer is currently busy.

Returns a plist (:send-now LIST :enqueue LIST).  Dead buffers are
dropped from both lists."
  (let (send-now enqueue)
    (dolist (buf bufs)
      (when (buffer-live-p buf)
        (if (funcall busy-fn buf)
            (push buf enqueue)
          (push buf send-now))))
    (list :send-now (nreverse send-now)
          :enqueue  (nreverse enqueue))))

(provide 'decknix-agent-session-bulk-send)
;;; decknix-agent-session-bulk-send.el ends here
