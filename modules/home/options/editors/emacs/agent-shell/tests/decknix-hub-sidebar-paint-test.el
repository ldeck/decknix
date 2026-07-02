;;; decknix-hub-sidebar-paint-test.el --- Coalesced idle-paint contract -*- lexical-binding: t -*-

;; Package-Requires: ((emacs "29.1") (decknix-hub-sidebar-paint "0.1"))

;;; Commentary:
;;
;; Pins the debounce/coalesce contract for `decknix-hub-sidebar-paint':
;;   * `-paint-through-p' mirrors the in-progress guard,
;;   * `-schedule-paint' coalesces (cancels the prior pending timer),
;;   * `-paint-now' binds the guard t across the real paint and clears
;;     the pending-timer slot, and
;;   * `-refresh-debounce-advice' defers (schedules, no orig-fn) when
;;     idle but paints through (orig-fn with args, no schedule) when the
;;     idle worker is already driving the real paint.
;;
;; Timers are stubbed via `cl-letf' so the suite is deterministic and
;; performs no real scheduling.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-hub-sidebar-paint)

(defmacro decknix-sidebar-paint-test--isolated (&rest body)
  "Run BODY with fresh paint state (no timer, guard clear)."
  (declare (indent 0))
  `(let ((decknix--sidebar-paint-timer nil)
         (decknix--sidebar-paint-in-progress nil)
         (decknix-sidebar-paint-idle-delay 0.3))
     ,@body))

;; -- Guard predicate ------------------------------------------------

(ert-deftest decknix-sidebar-paint--through-p-reflects-guard ()
  "`-paint-through-p' is nil normally, non-nil while the guard is set."
  (let ((decknix--sidebar-paint-in-progress nil))
    (should-not (decknix--sidebar-paint-through-p)))
  (let ((decknix--sidebar-paint-in-progress t))
    (should (decknix--sidebar-paint-through-p))))

;; -- Coalescing scheduler -------------------------------------------

(ert-deftest decknix-sidebar-paint--schedule-coalesces ()
  "A second schedule cancels the first pending timer before arming a new one."
  (decknix-sidebar-paint-test--isolated
    (let ((cancelled nil)
          (n 0))
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_delay _repeat _fn)
                   (setq n (1+ n))
                   (intern (format "timer-%d" n))))
                ((symbol-function 'timerp)
                 (lambda (x) (and x (symbolp x)
                                  (string-prefix-p "timer-" (symbol-name x)))))
                ((symbol-function 'cancel-timer)
                 (lambda (tm) (push tm cancelled))))
        (decknix--sidebar-schedule-paint #'ignore)
        (should (eq decknix--sidebar-paint-timer 'timer-1))
        (should (null cancelled))
        (decknix--sidebar-schedule-paint #'ignore)
        (should (eq decknix--sidebar-paint-timer 'timer-2))
        (should (equal cancelled '(timer-1)))))))

(ert-deftest decknix-sidebar-paint--cancel-clears-slot ()
  "`-cancel-paint' cancels a live timer and nils the slot."
  (decknix-sidebar-paint-test--isolated
    (let ((cancelled nil))
      (setq decknix--sidebar-paint-timer 'timer-x)
      (cl-letf (((symbol-function 'timerp) (lambda (_x) t))
                ((symbol-function 'cancel-timer)
                 (lambda (tm) (push tm cancelled))))
        (decknix--sidebar-cancel-paint)
        (should (equal cancelled '(timer-x)))
        (should (null decknix--sidebar-paint-timer))))))

;; -- The real paint runs with the guard set -------------------------

(ert-deftest decknix-sidebar-paint--now-binds-guard-and-clears-timer ()
  "`-paint-now' clears the timer slot and holds the guard t across REFRESH-FN."
  (decknix-sidebar-paint-test--isolated
    (let ((observed 'unset))
      (setq decknix--sidebar-paint-timer 'stale)
      (decknix--sidebar-paint-now
       (lambda () (setq observed decknix--sidebar-paint-in-progress)))
      (should (eq observed t))
      (should (null decknix--sidebar-paint-timer))
      (should-not decknix--sidebar-paint-in-progress))))

(ert-deftest decknix-sidebar-paint--now-restores-guard-on-error ()
  "An error in REFRESH-FN still restores the guard and clears the slot."
  (decknix-sidebar-paint-test--isolated
    (setq decknix--sidebar-paint-timer 'stale)
    (decknix--sidebar-paint-now (lambda () (error "boom")))
    (should (null decknix--sidebar-paint-timer))
    (should-not decknix--sidebar-paint-in-progress)))

;; -- Paint tick: yields to pending input ----------------------------

(ert-deftest decknix-sidebar-paint--tick-paints-when-no-input ()
  "With no input pending the tick runs the real paint and does not reschedule."
  (decknix-sidebar-paint-test--isolated
    (let ((painted nil) (scheduled nil))
      (cl-letf (((symbol-function 'input-pending-p) (lambda () nil))
                ((symbol-function 'decknix--sidebar-paint-now)
                 (lambda (fn) (setq painted fn)))
                ((symbol-function 'decknix--sidebar-schedule-paint)
                 (lambda (fn) (setq scheduled fn))))
        (decknix--sidebar-paint-tick)
        (should (eq painted #'agent-shell-workspace-sidebar-refresh))
        (should-not scheduled)))))

(ert-deftest decknix-sidebar-paint--tick-redefers-on-pending-input ()
  "When input is pending the tick re-defers and does NOT paint in front of it."
  (decknix-sidebar-paint-test--isolated
    (let ((painted nil) (scheduled nil))
      (cl-letf (((symbol-function 'input-pending-p) (lambda () t))
                ((symbol-function 'decknix--sidebar-paint-now)
                 (lambda (fn) (setq painted fn)))
                ((symbol-function 'decknix--sidebar-schedule-paint)
                 (lambda (fn) (setq scheduled fn))))
        (decknix--sidebar-paint-tick)
        (should (eq scheduled #'decknix--sidebar-paint-tick))
        (should-not painted)))))

;; -- Debounce advice: defer vs paint-through ------------------------

(ert-deftest decknix-sidebar-paint--advice-defers-when-idle ()
  "When not in progress the advice schedules and never calls ORIG-FN."
  (decknix-sidebar-paint-test--isolated
    (let ((scheduled nil)
          (orig-called nil))
      (cl-letf (((symbol-function 'decknix--sidebar-schedule-paint)
                 (lambda (fn) (setq scheduled fn))))
        (decknix--sidebar-refresh-debounce-advice
         (lambda (&rest _) (setq orig-called t)))
        (should scheduled)
        (should-not orig-called)))))

(ert-deftest decknix-sidebar-paint--advice-paints-through-when-in-progress ()
  "While the guard is set the advice calls ORIG-FN with ARGS, no schedule."
  (decknix-sidebar-paint-test--isolated
    (let ((decknix--sidebar-paint-in-progress t)
          (scheduled nil)
          (got-args 'unset))
      (cl-letf (((symbol-function 'decknix--sidebar-schedule-paint)
                 (lambda (fn) (setq scheduled fn))))
        (decknix--sidebar-refresh-debounce-advice
         (lambda (&rest args) (setq got-args args))
         'a 'b)
        (should (equal got-args '(a b)))
        (should-not scheduled)))))

(provide 'decknix-hub-sidebar-paint-test)
;;; decknix-hub-sidebar-paint-test.el ends here
