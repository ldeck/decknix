;;; decknix-perf-hitch-test.el --- Tests for the hitch profiler -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Tests for the pure-ish helpers of the background hitch profiler: the
;; SAFE function label (must never serialise a closure into a huge
;; string) and the log tally.  The advice/hook installation is exercised
;; live; only the data helpers are unit-tested here.

;;; Code:

(require 'ert)
(require 'decknix-perf-hitch)

(ert-deftest decknix-perf-hitch--label-symbol ()
  "A symbol yields its bare name."
  (should (equal (decknix--perf-hitch-fn-label 'self-insert-command)
                 "self-insert-command"))
  (should (equal (decknix--perf-hitch-fn-label nil) "nil")))

(ert-deftest decknix-perf-hitch--label-closure-is-bounded ()
  "A closure capturing large state is bounded, never dumped whole."
  (let* ((big (make-list 5000 'x))
         (fn (lambda () big))
         (label (decknix--perf-hitch-fn-label fn)))
    ;; must be short and must not contain thousands of x's
    (should (<= (length label) 71))
    (should-not (string-match-p "x x x x x x x x x x" label))))

(ert-deftest decknix-perf-hitch--tally-groups-and-sums ()
  "The tally counts, sums, and maxes ms per label from the log buffer."
  (let ((buf (get-buffer-create "*decknix-hitches*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (erase-buffer)
            (insert "09:00:00.000    120ms  CMD self-insert-command\n")
            (insert "09:00:01.000     80ms  CMD self-insert-command\n")
            (insert "09:00:02.000  21032ms  TIMER foo\n"))
          (let* ((rows (decknix--perf-hitch-tally))
                 (cmd (assoc "CMD self-insert-command" rows))
                 (tmr (assoc "TIMER foo" rows)))
            (should (equal (cdr cmd) (list 2 200 120)))
            (should (equal (cdr tmr) (list 1 21032 21032)))))
      (kill-buffer buf))))

(provide 'decknix-perf-hitch-test)
;;; decknix-perf-hitch-test.el ends here
