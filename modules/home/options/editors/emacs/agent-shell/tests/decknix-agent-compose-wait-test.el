;;; decknix-agent-compose-wait-test.el --- Tests for compose async wait -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-compose-wait "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix-agent-compose-wait'.
;; The pure decision function is exercised directly; the async
;; wait function is exercised with `run-at-time' / `cancel-timer'
;; stubbed via `cl-letf' so the suite never blocks on real timers.
;;
;; Regression context: the three interrupt-then-submit call sites
;; (compose-submit interrupt branch, compose-interrupt-and-submit,
;; review-submit-to-agent interrupt branch) all used a fixed
;; `sit-for 0.3' / `run-at-time 0.3' delay between the interrupt
;; and the submit.  When the agent's interrupt acknowledgement
;; arrived after that budget, the new prompt landed in the agent-
;; shell buffer ahead of the "[interrupted]" marker -- a visible
;; ordering inversion.  Pinning the wait-not-busy contract here
;; means any future drift back to a fixed delay (or a missed
;; cancel-timer) fails the build before it reaches a user.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-compose-wait)

;; Re-declare with a value so the test's `setq-local'/`let'-bind
;; is dynamic -- the carved module's `(defvar X)' is only a
;; compiler hint, which would otherwise let-bind lexically and
;; never be visible to the byte-compiled helper.
(defvar shell-maker--busy nil)

;; -- pure decision -------------------------------------------------

(ert-deftest decknix-compose-wait-decision/not-busy-fires-immediately ()
  "BUSY-P nil short-circuits to `fire' regardless of elapsed/budget."
  (should (eq 'fire (decknix--compose-wait-decision nil 0.0 2.0)))
  (should (eq 'fire (decknix--compose-wait-decision nil 1.0 2.0)))
  (should (eq 'fire (decknix--compose-wait-decision nil 5.0 2.0))))

(ert-deftest decknix-compose-wait-decision/busy-under-budget-continues ()
  "BUSY-P t and ELAPSED < BUDGET keeps polling."
  (should (eq 'continue (decknix--compose-wait-decision t 0.0 2.0)))
  (should (eq 'continue (decknix--compose-wait-decision t 0.5 2.0)))
  (should (eq 'continue (decknix--compose-wait-decision t 1.99 2.0))))

(ert-deftest decknix-compose-wait-decision/busy-at-or-over-budget-fires ()
  "BUSY-P t past BUDGET fires (safety-net timeout)."
  (should (eq 'fire (decknix--compose-wait-decision t 2.0 2.0)))
  (should (eq 'fire (decknix--compose-wait-decision t 2.5 2.0)))
  (should (eq 'fire (decknix--compose-wait-decision t 60.0 2.0))))

;; -- async wait (timer stubs) --------------------------------------

(defmacro decknix-compose-wait-test--with-timer-stubs (scheduled-var
                                                       cancelled-var
                                                       &rest body)
  "Run BODY with `run-at-time' / `cancel-timer' stubbed.

Each `run-at-time' call pushes a (DELAY . FN) cons onto
SCHEDULED-VAR (newest first); each `cancel-timer' call increments
CANCELLED-VAR.  Stubbed `run-at-time' returns a sentinel cons that
`timerp' recognises via the `cancel-timer' stub.  BODY drives the
state machine by `funcall'ing scheduled FNs in order to simulate
tick events."
  (declare (indent 2))
  `(let ((,scheduled-var nil)
         (,cancelled-var 0))
     (cl-letf (((symbol-function 'run-at-time)
                (lambda (when _repeat fn &rest _)
                  (push (cons when fn) ,scheduled-var)
                  (cons 'mock-timer fn)))
               ((symbol-function 'cancel-timer)
                (lambda (_) (cl-incf ,cancelled-var)))
               ((symbol-function 'timerp)
                (lambda (obj)
                  (and (consp obj) (eq (car obj) 'mock-timer)))))
       ,@body)))

(ert-deftest decknix-compose-wait-not-busy/idle-fires-on-first-tick ()
  "Already-idle target fires ON-READY on the first scheduled tick."
  (let ((called 0))
    (decknix-compose-wait-test--with-timer-stubs scheduled cancelled
      (with-temp-buffer
        (setq-local shell-maker--busy nil)
        (decknix--compose-wait-not-busy
         (current-buffer) (lambda () (cl-incf called)) 2.0 0.05)
        ;; One tick scheduled at delay 0 (the initial tick).
        (should (= 1 (length scheduled)))
        (should (equal 0 (caar scheduled)))
        ;; Run it -- callback fires, no re-arm.
        (funcall (cdr (pop scheduled)))
        (should (= 1 called))
        (should (= 0 (length scheduled)))))))

(ert-deftest decknix-compose-wait-not-busy/busy-reschedules-then-fires ()
  "While busy, each tick re-arms; once cleared, the next tick fires."
  (let ((called 0))
    (decknix-compose-wait-test--with-timer-stubs scheduled cancelled
      (with-temp-buffer
        (setq-local shell-maker--busy t)
        (decknix--compose-wait-not-busy
         (current-buffer) (lambda () (cl-incf called)) 2.0 0.05)
        ;; Initial tick: busy, no fire, re-arms at INTERVAL.
        (funcall (cdr (pop scheduled)))
        (should (= 0 called))
        (should (= 1 (length scheduled)))
        (should (equal 0.05 (caar scheduled)))
        ;; Still busy on the second tick.
        (funcall (cdr (pop scheduled)))
        (should (= 0 called))
        (should (= 1 (length scheduled)))
        ;; Clear the flag; the next tick fires.
        (setq-local shell-maker--busy nil)
        (funcall (cdr (pop scheduled)))
        (should (= 1 called))))))

(ert-deftest decknix-compose-wait-not-busy/fires-once-only ()
  "ON-READY is invoked exactly once even if extra ticks land."
  (let ((called 0))
    (decknix-compose-wait-test--with-timer-stubs scheduled cancelled
      (with-temp-buffer
        (setq-local shell-maker--busy nil)
        (decknix--compose-wait-not-busy
         (current-buffer) (lambda () (cl-incf called)) 2.0 0.05)
        ;; Tick the first scheduled call -- fires.
        (let ((tick (cdr (pop scheduled))))
          (funcall tick)
          (should (= 1 called))
          ;; Replay the same tick (simulates a stray scheduled run);
          ;; the `called' guard means the callback can't double-fire.
          (funcall tick)
          (should (= 1 called)))))))

(ert-deftest decknix-compose-wait-not-busy/dead-target-fires ()
  "If TARGET is killed mid-wait, the next tick still fires ON-READY.
The caller is responsible for buffer-live-p checks; the wait helper
treats `not buffer-live-p' as `not busy' so the callback can run
its own dead-target bail-out."
  (let ((called 0)
        (buf (generate-new-buffer " *decknix-wait-test*")))
    (decknix-compose-wait-test--with-timer-stubs scheduled cancelled
      (with-current-buffer buf
        (setq-local shell-maker--busy t))
      (decknix--compose-wait-not-busy
       buf (lambda () (cl-incf called)) 2.0 0.05)
      ;; First tick: busy, re-arms.
      (funcall (cdr (pop scheduled)))
      (should (= 0 called))
      ;; Kill the buffer; the next tick sees buffer-live-p nil ->
      ;; treats as not-busy and fires.
      (kill-buffer buf)
      (funcall (cdr (pop scheduled)))
      (should (= 1 called)))))

(provide 'decknix-agent-compose-wait-test)
;;; decknix-agent-compose-wait-test.el ends here
