;;; decknix-session-watch-test.el --- Tests for session watches -*- lexical-binding: t -*-

;;; Commentary:
;; Pure-core tests for the watch registry, the `checks-complete' condition,
;; the fire/expire partition, and the `watching' status refinement.

;;; Code:

(require 'ert)
(require 'decknix-session-watch)

;; -- terminal CI classification ---------------------------------------

(ert-deftest decknix-watch-ci-terminal--pass-and-fail-are-terminal ()
  (should (decknix-session-watch-ci-terminal-p "pass"))
  (should (decknix-session-watch-ci-terminal-p "fail"))
  (should (decknix-session-watch-ci-terminal-p "soft_fail"))
  (should (decknix-session-watch-ci-terminal-p "partial_fail")))

(ert-deftest decknix-watch-ci-terminal--running-and-none-are-not ()
  (should-not (decknix-session-watch-ci-terminal-p "running"))
  (should-not (decknix-session-watch-ci-terminal-p "none"))
  (should-not (decknix-session-watch-ci-terminal-p nil)))

;; -- the checks-complete condition ------------------------------------

(ert-deftest decknix-watch-fired--fires-on-running-to-terminal ()
  "A watch set while CI was running fires when it finishes."
  (let ((w (decknix-session-watch-make "ck" "r#1" 'checks-complete "running" 100)))
    (should-not (decknix-session-watch-fired-p w "running"))
    (should (decknix-session-watch-fired-p w "pass"))
    (should (decknix-session-watch-fired-p w "fail"))))

(ert-deftest decknix-watch-fired--already-terminal-does-not-fire-immediately ()
  "A PR green at registration waits for the NEXT transition, not now.
Otherwise every watch on a settled PR fires the instant it is set."
  (let ((w (decknix-session-watch-make "ck" "r#1" 'checks-complete "pass" 100)))
    (should-not (decknix-session-watch-fired-p w "pass"))))

(ert-deftest decknix-watch-fired--unknown-condition-never-fires ()
  (let ((w (decknix-session-watch-make "ck" "r#1" 'some-future-condition "running" 100)))
    (should-not (decknix-session-watch-fired-p w "pass"))))

;; -- expiry -----------------------------------------------------------

(ert-deftest decknix-watch-expired--dead-session-expires ()
  "A watch whose session is gone is reaped, never fired into thin air."
  (let ((w (decknix-session-watch-make "gone" "r#1" 'checks-complete "running" 100)))
    (should (decknix-session-watch-expired-p w 200 9999 '("alive")))
    (should-not (decknix-session-watch-expired-p w 200 9999 '("gone" "alive")))))

(ert-deftest decknix-watch-expired--past-ttl-expires ()
  (let ((w (decknix-session-watch-make "ck" "r#1" 'checks-complete "running" 100)))
    (should (decknix-session-watch-expired-p w 100000 3600 '("ck")))
    (should-not (decknix-session-watch-expired-p w 200 3600 '("ck")))))

;; -- the partition (fire / keep, expiry first) ------------------------

(ert-deftest decknix-watch-partition--fires-completed-keeps-running ()
  (let* ((w1 (decknix-session-watch-make "a" "r#1" 'checks-complete "running" 100))
         (w2 (decknix-session-watch-make "b" "r#2" 'checks-complete "running" 100))
         (ci (lambda (k) (pcase k ("r#1" "pass") ("r#2" "running"))))
         (out (decknix-session-watch-partition (list w1 w2) ci 200 9999 '("a" "b"))))
    (should (equal '("r#1") (mapcar (lambda (w) (alist-get 'pr-key w)) (nth 0 out))))
    (should (equal '("r#2") (mapcar (lambda (w) (alist-get 'pr-key w)) (nth 1 out))))))

(ert-deftest decknix-watch-partition--expiry-wins-over-firing ()
  "A watch whose PR just completed but whose SESSION is gone is dropped,
not fired: firing into a dead session is the leak the TTL exists to stop."
  (let* ((w (decknix-session-watch-make "gone" "r#1" 'checks-complete "running" 100))
         (ci (lambda (_k) "pass"))
         (out (decknix-session-watch-partition (list w) ci 200 9999 '("other"))))
    (should-not (nth 0 out))
    (should-not (nth 1 out))))

;; -- the watching status ----------------------------------------------

(ert-deftest decknix-watch-status--ready-with-a-watch-is-watching ()
  (should (equal "watching" (decknix-session-watch-status "ready" t)))
  (should (equal "watching" (decknix-session-watch-status "finished" t))))

(ert-deftest decknix-watch-status--no-watch-is-unchanged ()
  (should (equal "ready" (decknix-session-watch-status "ready" nil))))

(ert-deftest decknix-watch-status--a-live-or-blocked-turn-is-never-masked ()
  "A watch must not hide `working' or `asking' -- those are more urgent."
  (should (equal "working" (decknix-session-watch-status "working" t)))
  (should (equal "asking" (decknix-session-watch-status "asking" t))))


;; -- persistence + registry round-trip --------------------------------

(ert-deftest decknix-watch-persistence--round-trips ()
  "A written watch list reads back equal."
  (let* ((decknix-session-watch-file (make-temp-file "sw-test-"))
         (decknix-session-watches nil))
    (unwind-protect
        (progn
          (decknix-session-watch-add "ck" "r#1" 'checks-complete "running")
          (should (decknix-session-watch-for-conv-key "ck"))
          (let ((decknix-session-watches nil))
            (decknix-session-watch-load)
            (should (decknix-session-watch-for-conv-key "ck"))
            (should (equal "r#1" (alist-get 'pr-key (car decknix-session-watches))))))
      (delete-file decknix-session-watch-file))))

(ert-deftest decknix-watch-add--rewatch-replaces-not-stacks ()
  "Watching the same PR again resets the baseline, one record not two."
  (let* ((decknix-session-watch-file (make-temp-file "sw-test-"))
         (decknix-session-watches nil))
    (unwind-protect
        (progn
          (decknix-session-watch-add "ck" "r#1" 'checks-complete "running")
          (decknix-session-watch-add "ck" "r#1" 'checks-complete "pass")
          (should (= 1 (length decknix-session-watches)))
          (should (alist-get 'baseline-terminal (car decknix-session-watches))))
      (delete-file decknix-session-watch-file))))

(ert-deftest decknix-watch-evaluate--fires-notifies-and-clears ()
  "A completed watch notifies once and is removed; a running one stays."
  (let* ((decknix-session-watch-file (make-temp-file "sw-test-"))
         (decknix-session-watches nil)
         (notified nil))
    (unwind-protect
        (progn
          (decknix-session-watch-add "a" "r#1" 'checks-complete "running")
          (decknix-session-watch-add "b" "r#2" 'checks-complete "running")
          (let ((n (decknix-session-watch-evaluate
                    (lambda (k) (pcase k ("r#1" "pass") ("r#2" "running")))
                    '("a" "b")
                    (lambda (w) (push (alist-get 'pr-key w) notified)))))
            (should (= 1 n))
            (should (equal '("r#1") notified))
            (should-not (decknix-session-watch-for-conv-key "a"))
            (should (decknix-session-watch-for-conv-key "b"))))
      (delete-file decknix-session-watch-file))))

(ert-deftest decknix-watch-remove--drops-the-conv-key ()
  (let* ((decknix-session-watch-file (make-temp-file "sw-test-"))
         (decknix-session-watches nil))
    (unwind-protect
        (progn
          (decknix-session-watch-add "ck" "r#1" 'checks-complete "running")
          (decknix-session-watch-remove "ck")
          (should-not (decknix-session-watch-for-conv-key "ck")))
      (delete-file decknix-session-watch-file))))

(provide 'decknix-session-watch-test)
;;; decknix-session-watch-test.el ends here
