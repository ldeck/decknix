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
         (decknix-sidebar-paint-idle-delay 0.3)
         (decknix--sidebar-paint-last-duration 0)
         (decknix--sidebar-paint-last-end 0)
         (decknix--sidebar-paint-pending nil)
         (decknix--sidebar-idle-last-fingerprint 'unset)
         (decknix--sidebar-idle-last-paint 0))
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

(ert-deftest decknix-sidebar-paint--defer-p-input-or-minibuffer ()
  "Paint defers while input is pending OR a minibuffer is active."
  (cl-letf (((symbol-function 'input-pending-p) (lambda () nil))
            ((symbol-function 'active-minibuffer-window) (lambda () nil)))
    (should-not (decknix--sidebar-paint-defer-p)))
  (cl-letf (((symbol-function 'input-pending-p) (lambda () t))
            ((symbol-function 'active-minibuffer-window) (lambda () nil)))
    (should (decknix--sidebar-paint-defer-p)))
  (cl-letf (((symbol-function 'input-pending-p) (lambda () nil))
            ((symbol-function 'active-minibuffer-window) (lambda () 'win)))
    (should (decknix--sidebar-paint-defer-p))))

(ert-deftest decknix-sidebar-paint--tick-redefers-when-minibuffer-active ()
  "The tick re-schedules (never paints) while a minibuffer/picker is open —
this is the fix for the multi-second freeze on up/down/RET in `C-c b'."
  (let ((scheduled 0) (painted 0))
    (cl-letf (((symbol-function 'input-pending-p) (lambda () nil))
              ((symbol-function 'active-minibuffer-window) (lambda () 'win))
              ((symbol-function 'decknix--sidebar-schedule-paint)
               (lambda (_fn) (cl-incf scheduled)))
              ((symbol-function 'decknix--sidebar-paint-now)
               (lambda (_fn) (cl-incf painted))))
      (decknix--sidebar-paint-tick)
      (should (= scheduled 1))
      (should (= painted 0)))))

;; -- One status per session per paint -------------------------------

(defun decknix-sidebar-memo-test--counting-status (calls)
  "Return a fake status ORIG that counts calls per buffer into CALLS."
  (lambda (buffer &rest _)
    (puthash buffer (1+ (gethash buffer calls 0)) calls)
    (if (equal (buffer-name buffer) " memo-b") nil "working")))

(ert-deftest decknix-sidebar-memo--outside-a-paint-every-call-is-fresh ()
  "Auto-close, reattach and the picker's fallback act on a status; none
of them may be handed a remembered one."
  (let ((decknix--agent-status-memo nil)
        (calls (make-hash-table :test 'eq))
        (buf (generate-new-buffer " memo-a")))
    (unwind-protect
        (let ((orig (decknix-sidebar-memo-test--counting-status calls)))
          (dotimes (_ 3) (decknix--agent-status-memo-advice orig buf))
          (should (= 3 (gethash buf calls))))
      (kill-buffer buf))))

(ert-deftest decknix-sidebar-memo--inside-a-scope-each-buffer-is-asked-once ()
  "Needs you, Reviews, WIP, the snapshot and the fingerprint each asked
every session again, and each ask ran the whole advice chain."
  (let ((decknix--agent-status-memo nil)
        (calls (make-hash-table :test 'eq))
        (a (generate-new-buffer " memo-a"))
        (b (generate-new-buffer " memo-b")))
    (unwind-protect
        (let ((orig (decknix-sidebar-memo-test--counting-status calls)))
          (decknix--sidebar-with-status-memo
            (dotimes (_ 4)
              (should (equal "working" (decknix--agent-status-memo-advice orig a)))
              ;; A nil status is an answer too, and is not re-asked.
              (should-not (decknix--agent-status-memo-advice orig b))))
          (should (= 1 (gethash a calls)))
          (should (= 1 (gethash b calls)))
          ;; The scope ends with the paint.
          (decknix--agent-status-memo-advice orig a)
          (should (= 2 (gethash a calls))))
      (kill-buffer a) (kill-buffer b))))

(ert-deftest decknix-sidebar-memo--a-nested-scope-joins-the-outer-one ()
  (let ((decknix--agent-status-memo nil)
        (calls (make-hash-table :test 'eq))
        (a (generate-new-buffer " memo-a")))
    (unwind-protect
        (let ((orig (decknix-sidebar-memo-test--counting-status calls)))
          (decknix--sidebar-with-status-memo
            (decknix--agent-status-memo-advice orig a)
            (decknix--sidebar-with-status-memo
              (decknix--agent-status-memo-advice orig a)))
          (should (= 1 (gethash a calls))))
      (kill-buffer a))))

(ert-deftest decknix-sidebar-memo--the-post-paint-fingerprint-reuses-the-paint ()
  "The fingerprint taken right after a paint read every status afresh,
straight after the paint had computed them all."
  (decknix-sidebar-paint-test--isolated
    (let ((decknix--agent-status-memo nil)
          (calls (make-hash-table :test 'eq))
          (a (generate-new-buffer " memo-a")))
      (unwind-protect
          (let ((orig (decknix-sidebar-memo-test--counting-status calls)))
            (cl-letf (((symbol-function 'decknix--sidebar-idle-fingerprint)
                       (lambda () (decknix--agent-status-memo-advice orig a)))
                      ((symbol-function 'decknix--sidebar-state-write) #'ignore))
              (decknix--sidebar-paint-now
               (lambda () (decknix--agent-status-memo-advice orig a)))
              (should (= 1 (gethash a calls)))))
        (kill-buffer a)))))

(ert-deftest decknix-sidebar-memo--each-paint-starts-a-new-generation ()
  (decknix-sidebar-paint-test--isolated
    (let ((decknix--sidebar-paint-generation 7))
      (cl-letf (((symbol-function 'decknix--sidebar-idle-fingerprint) #'ignore)
                ((symbol-function 'decknix--sidebar-state-write) #'ignore))
        (decknix--sidebar-paint-now #'ignore))
      (should (= 8 decknix--sidebar-paint-generation)))))

;; -- Paint pacing ---------------------------------------------------

(defmacro decknix-sidebar-pace-test--tick (spec &rest body)
  "Run BODY with paint-now, schedule and run-with-timer recorded per SPEC.
SPEC is (PAINTED SCHEDULED TIMED)."
  (declare (indent 1))
  (let ((painted (nth 0 spec)) (scheduled (nth 1 spec)) (timed (nth 2 spec)))
    `(let ((,painted nil) (,scheduled nil) (,timed nil))
       (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) nil))
                 ((symbol-function 'active-minibuffer-window) (lambda () nil))
                 ((symbol-function 'decknix--sidebar-paint-now)
                  (lambda (fn) (setq ,painted fn)))
                 ((symbol-function 'decknix--sidebar-schedule-paint)
                  (lambda (fn) (setq ,scheduled fn)))
                 ((symbol-function 'run-with-timer)
                  (lambda (secs _rep fn &rest args)
                    (setq ,timed (list secs fn args)) 'gap-timer)))
         ,@body))))

(ert-deftest decknix-sidebar-pace--a-hidden-sidebar-is-marked-not-painted ()
  "A sidebar in another tab was repainted in full every couple of seconds."
  (decknix-sidebar-paint-test--isolated
    (let ((decknix-sidebar-idle-force-interval 60)
          (decknix--sidebar-idle-last-paint (float-time)))
      (decknix-sidebar-pace-test--tick (painted scheduled timed)
        (cl-letf (((symbol-function 'decknix--sidebar-paint-hidden-p) (lambda () t)))
          (decknix--sidebar-paint-tick)
          (should-not painted)
          (should-not scheduled)
          (should-not timed)
          (should decknix--sidebar-paint-pending))))))

(ert-deftest decknix-sidebar-pace--a-hidden-sidebar-still-paints-per-force-interval ()
  "Its side effects (linked-prs.json, persisted toggles) must not go stale
for as long as it stays hidden."
  (decknix-sidebar-paint-test--isolated
    (let ((decknix-sidebar-idle-force-interval 60)
          (decknix--sidebar-idle-last-paint (- (float-time) 61)))
      (decknix-sidebar-pace-test--tick (painted _scheduled _timed)
        (cl-letf (((symbol-function 'decknix--sidebar-paint-hidden-p) (lambda () t)))
          (decknix--sidebar-paint-tick)
          (should painted))))))

(ert-deftest decknix-sidebar-pace--a-pending-paint-lands-when-shown ()
  (decknix-sidebar-paint-test--isolated
    (let ((decknix--sidebar-paint-pending t)
          (refreshed nil))
      (cl-letf (((symbol-function 'decknix--sidebar-paint-hidden-p) (lambda () nil))
                ((symbol-function 'agent-shell-workspace-sidebar-refresh)
                 (lambda () (setq refreshed t)))
                ((symbol-function 'decknix--sidebar-idle-fingerprint)
                 (lambda () (error "No fingerprint needed for a pending paint"))))
        (decknix--sidebar-idle-tick)
        (should refreshed)))))

(ert-deftest decknix-sidebar-pace--a-slow-paint-spaces-out-the-next ()
  "A two-second paint re-armed on every pause left no idle time unpainted."
  (decknix-sidebar-paint-test--isolated
    (let ((decknix-sidebar-paint-spacing-factor 3)
          (decknix-sidebar-paint-max-spacing 10)
          (decknix--sidebar-paint-last-duration 2.0)
          (decknix--sidebar-paint-last-end (- (float-time) 1.0)))
      (decknix-sidebar-pace-test--tick (painted _scheduled timed)
        (cl-letf (((symbol-function 'decknix--sidebar-paint-hidden-p) (lambda () nil)))
          (decknix--sidebar-paint-tick)
          (should-not painted)
          ;; 3 x 2 s after it ended, of which 1 s has passed.
          (should (< 4.9 (nth 0 timed) 5.1))
          ;; And then it waits for idle again, never painting off a plain timer.
          (should (eq #'decknix--sidebar-schedule-paint (nth 1 timed)))
          (should (eq 'gap-timer decknix--sidebar-paint-timer)))))))

(ert-deftest decknix-sidebar-pace--the-gap-is-capped ()
  (decknix-sidebar-paint-test--isolated
    (let ((decknix-sidebar-paint-spacing-factor 3)
          (decknix-sidebar-paint-max-spacing 10)
          (decknix--sidebar-paint-last-duration 60.0)
          (decknix--sidebar-paint-last-end 100.0))
      (should (= 10 (decknix--sidebar-paint-wait 100.0)))
      (should (= 0 (decknix--sidebar-paint-wait 111.0))))))

(ert-deftest decknix-sidebar-pace--a-fast-paint-adds-no-gap ()
  (decknix-sidebar-paint-test--isolated
    (let ((decknix--sidebar-paint-last-duration 0.01)
          (decknix--sidebar-paint-last-end (- (float-time) 0.6)))
      (decknix-sidebar-pace-test--tick (painted _scheduled _timed)
        (cl-letf (((symbol-function 'decknix--sidebar-paint-hidden-p) (lambda () nil)))
          (decknix--sidebar-paint-tick)
          (should painted))))))

(ert-deftest decknix-sidebar-pace--checkpoint-throws-only-on-input-in-a-paint ()
  (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) t)))
    (let ((decknix--sidebar-paint-abortable nil))
      (should-not (catch 'decknix--sidebar-paint-abort
                    (decknix--sidebar-paint-checkpoint) nil)))
    (let ((decknix--sidebar-paint-abortable t))
      (should (catch 'decknix--sidebar-paint-abort
                (decknix--sidebar-paint-checkpoint) nil))))
  (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) nil)))
    (let ((decknix--sidebar-paint-abortable t))
      (should-not (catch 'decknix--sidebar-paint-abort
                    (decknix--sidebar-paint-checkpoint) nil)))))

(ert-deftest decknix-sidebar-pace--an-abandoned-render-leaves-the-sidebar-alone ()
  "Half a paint must never reach the screen."
  (let ((target (generate-new-buffer " pace-target"))
        (decknix--sidebar-paint-aborted nil)
        (decknix--sidebar-paint-abortable t))
    (unwind-protect
        (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) t)))
          (with-current-buffer target (insert "old\n"))
          (with-current-buffer target
            (decknix--sidebar-diff-render
             (lambda ()
               (insert "new first section\n")
               (decknix--sidebar-paint-checkpoint)
               (insert "never reached\n"))))
          (should decknix--sidebar-paint-aborted)
          (should (equal "old\n" (with-current-buffer target (buffer-string)))))
      (kill-buffer target))))

(ert-deftest decknix-sidebar-pace--an-abandoned-paint-is-retried-not-recorded ()
  (decknix-sidebar-paint-test--isolated
    (let ((scheduled nil) (wrote nil) (fp nil))
      (cl-letf (((symbol-function 'decknix--sidebar-schedule-paint)
                 (lambda (fn) (setq scheduled fn)))
                ((symbol-function 'decknix--sidebar-state-write)
                 (lambda () (setq wrote t)))
                ((symbol-function 'decknix--sidebar-idle-fingerprint)
                 (lambda () (setq fp t) 'fp)))
        (decknix--sidebar-paint-now
         (lambda () (setq decknix--sidebar-paint-aborted t)))
        (should (eq scheduled #'decknix--sidebar-paint-tick))
        (should-not fp)
        (should-not wrote)
        (should (eq 'unset decknix--sidebar-idle-last-fingerprint))
        (should (= 0 decknix--sidebar-paint-last-duration))))))

(ert-deftest decknix-sidebar-pace--a-completed-paint-records-its-duration ()
  (decknix-sidebar-paint-test--isolated
    (cl-letf (((symbol-function 'decknix--sidebar-state-write) #'ignore)
              ((symbol-function 'decknix--sidebar-idle-fingerprint) (lambda () 'fp)))
      (decknix--sidebar-paint-now (lambda () (sleep-for 0.02)))
      (should (>= decknix--sidebar-paint-last-duration 0.015))
      (should (eq 'fp decknix--sidebar-idle-last-fingerprint)))))

(provide 'decknix-hub-sidebar-paint-test)
;;; decknix-hub-sidebar-paint-test.el ends here
