;;; decknix-agent-spawn-queue.el --- Throttle bursty session spawns -*- lexical-binding: t; -*-

;; Spawning many agent sessions at once (e.g. auto-review dispatching one per
;; pending PR on a single hub refresh) cold-starts that many node+claude
;; processes simultaneously.  The thundering herd thrashes CPU/IO — so each
;; session takes far longer to initialise — and the burst of init-time output
;; floods Emacs's single main thread, freezing the UI.
;;
;; This queue paces launches: the first enqueued thunk (when idle) fires
;; immediately, and the rest drip out one per `decknix-agent-spawn-stagger'
;; seconds.  Sparse/single spawns pay no penalty (they launch at once); only
;; bursts get spread, which keeps both per-session init fast and the UI
;; responsive.
;;
;; The drain core is synchronous and testable; only the inter-launch delay uses
;; a timer.

;;; Code:

(defgroup decknix-agent-spawn-queue nil
  "Throttle bursty agent-session spawns."
  :group 'tools)

(defcustom decknix-agent-spawn-stagger 2.0
  "Seconds between throttled session launches.
The first spawn in an idle queue fires immediately; each subsequent
queued spawn waits this long after the previous one.  Tuned to let a
node+claude cold-start settle before the next begins, so a burst of
reviews no longer thrashes the machine or freezes Emacs."
  :type 'number
  :group 'decknix-agent-spawn-queue)

(defvar decknix--agent-spawn-queue nil
  "FIFO list of pending zero-arg spawn thunks.")

(defvar decknix--agent-spawn-timer nil
  "Pending `run-with-timer' handle for the next drain, or nil when idle.")

(defun decknix-agent-spawn-pending-count ()
  "Number of spawns still waiting in the throttle queue."
  (length decknix--agent-spawn-queue))

(defun decknix--agent-spawn-launch (thunk)
  "Run THUNK now and arm the cooldown timer that drains the next spawn.
Arming the timer unconditionally (even when the queue is momentarily
empty) is what enforces the minimum gap: a synchronous burst of enqueues
arriving during the cooldown is queued rather than fired, because
`decknix--agent-spawn-timer' is already set."
  (when thunk
    (ignore-errors (funcall thunk)))
  (setq decknix--agent-spawn-timer
        (run-with-timer decknix-agent-spawn-stagger nil
                        #'decknix--agent-spawn-tick)))

(defun decknix--agent-spawn-tick ()
  "Cooldown-timer callback: launch the next queued spawn, if any.
When the queue has drained, clear the timer so the next enqueue fires
immediately again (single/sparse spawns pay no throttle)."
  (setq decknix--agent-spawn-timer nil)
  (when decknix--agent-spawn-queue
    (decknix--agent-spawn-launch (pop decknix--agent-spawn-queue))))

(defun decknix-agent-spawn-enqueue (thunk)
  "Enqueue THUNK (a zero-arg function that starts a session), throttled.
When the queue is idle the THUNK launches immediately and starts a
cooldown; while a launch is in cooldown, THUNK waits its turn — one per
`decknix-agent-spawn-stagger' seconds, in FIFO order.  Returns the number
of spawns queued behind this call (0 when it launched immediately)."
  (if decknix--agent-spawn-timer
      ;; A launch is in cooldown: queue and let the tick drain it.
      (progn
        (setq decknix--agent-spawn-queue
              (append decknix--agent-spawn-queue (list thunk)))
        (length decknix--agent-spawn-queue))
    ;; Idle: launch immediately and open the cooldown window.
    (decknix--agent-spawn-launch thunk)
    0))

(defun decknix-agent-spawn-clear ()
  "Cancel any pending throttled launches and empty the queue.
The launch already in flight is unaffected; this only drops what is still
waiting.  A safety valve if a dispatch storm needs to be aborted."
  (interactive)
  (when decknix--agent-spawn-timer
    (cancel-timer decknix--agent-spawn-timer)
    (setq decknix--agent-spawn-timer nil))
  (let ((n (length decknix--agent-spawn-queue)))
    (setq decknix--agent-spawn-queue nil)
    (when (called-interactively-p 'interactive)
      (message "Cleared %d pending session spawn(s)" n))
    n))

(provide 'decknix-agent-spawn-queue)
;;; decknix-agent-spawn-queue.el ends here
