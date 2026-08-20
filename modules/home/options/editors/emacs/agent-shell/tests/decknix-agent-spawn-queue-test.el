;;; decknix-agent-spawn-queue-test.el --- Tests for the spawn throttle -*- lexical-binding: t -*-

(require 'ert)
(require 'decknix-agent-spawn-queue)
(require 'cl-lib)

(defmacro decknix-agent-spawn-test--with-stubbed-timer (&rest body)
  "Run BODY with `run-with-timer' stubbed so drains never auto-fire.
Each queue/timer var is reset first, and the stub records that a timer was
requested by returning a sentinel handle (so `decknix--agent-spawn-timer'
becomes non-nil, matching production)."
  `(let ((decknix--agent-spawn-queue nil)
         (decknix--agent-spawn-timer nil)
         (decknix-agent-spawn-stagger 0.01))
     (cl-letf (((symbol-function 'run-with-timer)
                (lambda (&rest _) 'stub-timer)))
       ,@body)))

(ert-deftest decknix-agent-spawn-first-launches-immediately ()
  "Enqueueing into an idle queue launches the thunk at once."
  (decknix-agent-spawn-test--with-stubbed-timer
   (let ((fired nil))
     (decknix-agent-spawn-enqueue (lambda () (setq fired t)))
     (should fired)
     (should (= (decknix-agent-spawn-pending-count) 0)))))

(ert-deftest decknix-agent-spawn-burst-drains-fifo-one-at-a-time ()
  "A synchronous burst launches the first immediately, then one per tick,
in FIFO order — the throttle must engage even when enqueues arrive
back-to-back (the real dispatch-loop case)."
  (decknix-agent-spawn-test--with-stubbed-timer
   (let ((order '()))
     (dolist (i '(1 2 3 4))
       (decknix-agent-spawn-enqueue (lambda () (push i order))))
     ;; First fired on enqueue; 2..4 held behind the cooldown timer.
     (should (equal order '(1)))
     (should (= (decknix-agent-spawn-pending-count) 3))
     (should decknix--agent-spawn-timer)
     ;; Simulate the cooldown timer firing until drained.
     (decknix--agent-spawn-tick)      ; -> 2
     (decknix--agent-spawn-tick)      ; -> 3
     (decknix--agent-spawn-tick)      ; -> 4
     (should (equal (nreverse order) '(1 2 3 4)))
     (should (= (decknix-agent-spawn-pending-count) 0))
     ;; One trailing cooldown remains armed after the last launch; the next
     ;; tick finds nothing and goes idle.
     (decknix--agent-spawn-tick)
     (should-not decknix--agent-spawn-timer))))

(ert-deftest decknix-agent-spawn-tick-empty-is-safe ()
  "Ticking an empty queue clears the timer and launches nothing."
  (decknix-agent-spawn-test--with-stubbed-timer
   (decknix--agent-spawn-tick)
   (should-not decknix--agent-spawn-timer)
   (should (= (decknix-agent-spawn-pending-count) 0))))

(ert-deftest decknix-agent-spawn-thunk-error-does-not-halt-drain ()
  "A throwing thunk is swallowed so the rest of the burst still launches."
  (decknix-agent-spawn-test--with-stubbed-timer
   (let ((ran '()))
     (decknix-agent-spawn-enqueue (lambda () (error "boom")))     ; launches, errors
     (decknix-agent-spawn-enqueue (lambda () (push 'ok ran)))     ; queued
     (should (= (decknix-agent-spawn-pending-count) 1))
     (decknix--agent-spawn-tick)
     (should (equal ran '(ok))))))

(ert-deftest decknix-agent-spawn-clear-drops-pending-only ()
  "`decknix-agent-spawn-clear' empties the queue and cancels the timer."
  (decknix-agent-spawn-test--with-stubbed-timer
   (cl-letf (((symbol-function 'cancel-timer) (lambda (&rest _) nil)))
     (dolist (i '(1 2 3))
       (decknix-agent-spawn-enqueue (lambda () (ignore i))))
     (should (= (decknix-agent-spawn-pending-count) 2))
     (should (= (decknix-agent-spawn-clear) 2))
     (should (= (decknix-agent-spawn-pending-count) 0))
     (should-not decknix--agent-spawn-timer))))

;;; decknix-agent-spawn-queue-test.el ends here
