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

;; -- Dirty-checked idle tick decision --------------------------------

(ert-deftest decknix-sidebar-paint--idle-paints-when-fingerprint-changed ()
  "A changed fingerprint forces a repaint even inside the force window."
  (should (decknix--sidebar-idle-should-paint-p
           '(:b) '(:a) 100.0 100.5 60)))

(ert-deftest decknix-sidebar-paint--idle-skips-when-unchanged-in-window ()
  "Same fingerprint within the force window -> skip (no repaint)."
  (should-not (decknix--sidebar-idle-should-paint-p
               '(:a) '(:a) 100.0 130.0 60)))

(ert-deftest decknix-sidebar-paint--idle-forces-after-interval ()
  "Same fingerprint but past the force interval -> repaint (relative times)."
  (should (decknix--sidebar-idle-should-paint-p
           '(:a) '(:a) 100.0 161.0 60)))

(ert-deftest decknix-sidebar-paint--idle-force-boundary-is-inclusive ()
  "Exactly FORCE-INTERVAL seconds elapsed repaints (>= boundary)."
  (should (decknix--sidebar-idle-should-paint-p
           '(:a) '(:a) 100.0 160.0 60)))

(ert-deftest decknix-sidebar-paint--idle-unset-baseline-paints ()
  "The initial `unset' baseline never equals a real fingerprint -> paints."
  (should (decknix--sidebar-idle-should-paint-p
           '(nil nil) 'unset 0 0.0 60)))

;; -- Incremental diff render -----------------------------------------

(ert-deftest decknix-sidebar-diff--split-lines-keeps-newlines ()
  "Lines retain their trailing newline; last line only if present."
  (should (equal (decknix--sidebar-split-lines "a\nb\nc") '("a\n" "b\n" "c")))
  (should (equal (decknix--sidebar-split-lines "a\nb\n") '("a\n" "b\n")))
  (should (equal (decknix--sidebar-split-lines "") '())))

(ert-deftest decknix-sidebar-diff--identical-is-nil ()
  "Identical inputs produce no edit."
  (should-not (decknix--sidebar-line-diff '("a\n" "b\n" "c") '("a\n" "b\n" "c"))))

(ert-deftest decknix-sidebar-diff--middle-line-changed ()
  "A single changed middle line: keep prefix + suffix, replace the middle."
  (let ((d (decknix--sidebar-line-diff '("a\n" "OLD\n" "c") '("a\n" "NEW\n" "c"))))
    (should (equal (plist-get d :prefix-chars) 2))   ; "a\n"
    (should (equal (plist-get d :suffix-chars) 1))   ; "c"
    (should (equal (plist-get d :middle) "NEW\n"))))

(ert-deftest decknix-sidebar-diff--inserted-line ()
  "A line inserted in the middle replaces the minimal span."
  (let ((d (decknix--sidebar-line-diff '("a\n" "c") '("a\n" "b\n" "c"))))
    (should (equal (plist-get d :prefix-chars) 2))
    (should (equal (plist-get d :suffix-chars) 1))
    (should (equal (plist-get d :middle) "b\n"))))

(ert-deftest decknix-sidebar-diff--face-only-change-counts ()
  "A same-text, different-face line is treated as changed (property-aware)."
  (let* ((old (propertize "row\n" 'face 'default))
         (new (propertize "row\n" 'face 'error))
         (d (decknix--sidebar-line-diff (list old) (list new))))
    (should d)
    (should (equal-including-properties (plist-get d :middle) new))))

(ert-deftest decknix-sidebar-diff--apply-updates-buffer ()
  "`decknix--sidebar-diff-apply' rewrites only the changed middle."
  (let ((target (get-buffer-create " *decknix-diff-target*"))
        (src (get-buffer-create " *decknix-diff-src*")))
    (unwind-protect
        (progn
          (with-current-buffer target (erase-buffer) (insert "a\nOLD\nc"))
          (with-current-buffer src (erase-buffer) (insert "a\nNEW\nc"))
          (decknix--sidebar-diff-apply target src)
          (should (equal (with-current-buffer target (buffer-string)) "a\nNEW\nc")))
      (kill-buffer target)
      (kill-buffer src))))

(ert-deftest decknix-sidebar-diff--apply-noop-when-identical ()
  "Identical content makes zero buffer edits (redisplay saver)."
  (let ((target (get-buffer-create " *decknix-diff-target*"))
        (src (get-buffer-create " *decknix-diff-src*")))
    (unwind-protect
        (progn
          (with-current-buffer target (erase-buffer) (insert "a\nb\nc"))
          (with-current-buffer src (erase-buffer) (insert "a\nb\nc"))
          (let ((tick (with-current-buffer target (buffer-chars-modified-tick))))
            (decknix--sidebar-diff-apply target src)
            (should (= tick (with-current-buffer target
                              (buffer-chars-modified-tick))))))
      (kill-buffer target)
      (kill-buffer src))))

;; -- Live-section render cache ---------------------------------------

(require 'cl-lib)

(ert-deftest decknix-sidebar-live-cache--miss-renders-then-hit-reuses ()
  "First call renders (miss); a same-fingerprint call reuses the cached
text without calling ORIG again."
  (let ((decknix--sidebar-live-render-cache nil)
        (calls 0))
    (cl-letf (((symbol-function 'decknix--sidebar-live-render-fingerprint)
               (lambda (&rest _) 'FP)))
      (with-temp-buffer
        (let ((n (decknix--sidebar-render-live-cached
                  (lambda (ln &rest _) (setq calls (1+ calls)) (insert "LIVE") (+ ln 2))
                  0 nil nil nil 10)))
          (should (= calls 1)) (should (= n 2))
          (should (equal (buffer-string) "LIVE")))
        (erase-buffer)
        ;; hit: orig must NOT run again; cached "LIVE" re-inserted
        (let ((n (decknix--sidebar-render-live-cached
                  (lambda (ln &rest _) (setq calls (1+ calls)) (insert "NOPE") (+ ln 99))
                  0 nil nil nil 10)))
          (should (= calls 1))
          (should (= n 2))
          (should (equal (buffer-string) "LIVE")))))))

(ert-deftest decknix-sidebar-live-cache--fingerprint-change-re-renders ()
  "A changed fingerprint bypasses the cache and re-renders."
  (let ((decknix--sidebar-live-render-cache nil)
        (calls 0)
        (fp 'A))
    (cl-letf (((symbol-function 'decknix--sidebar-live-render-fingerprint)
               (lambda (&rest _) fp)))
      (with-temp-buffer
        (decknix--sidebar-render-live-cached
         (lambda (ln &rest _) (setq calls (1+ calls)) (insert "x") (+ ln 1)) 0 nil nil nil 1)
        (setq fp 'B)                    ; input changed
        (erase-buffer)
        (decknix--sidebar-render-live-cached
         (lambda (ln &rest _) (setq calls (1+ calls)) (insert "y") (+ ln 1)) 0 nil nil nil 1)
        (should (= calls 2))))))        ; both rendered

(provide 'decknix-hub-sidebar-paint-test)
;;; decknix-hub-sidebar-paint-test.el ends here
