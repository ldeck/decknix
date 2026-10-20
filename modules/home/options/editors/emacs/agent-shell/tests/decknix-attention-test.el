;;; decknix-attention-test.el --- Tests for the attention definition -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Pins the order sessions are visited in, the edge that focus-steal and
;; the counter rely on, and that the jump selects the tab holding a
;; session rather than dragging it into the current window.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-attention)

(defmacro decknix-attention-test--with-buffers (names &rest body)
  "Run BODY with live buffers NAMES and a fresh observation table."
  (declare (indent 1))
  `(let ((decknix-attention--seen (make-hash-table :test 'eq :weakness 'key))
         (bufs (mapcar #'get-buffer-create ,names)))
     (unwind-protect (progn ,@body)
       (mapc (lambda (b) (when (buffer-live-p b) (kill-buffer b))) bufs))))

(ert-deftest decknix-attention--the-three-states-and-no-others ()
  (dolist (s '("netfail" "waiting" "asking"))
    (should (decknix-attention-state-p s)))
  (dolist (s '("working" "ready" "finished" "closing" nil))
    (should-not (decknix-attention-state-p s))))

(ert-deftest decknix-attention--netfail-then-waiting-then-asking ()
  (let ((order (decknix-attention-order
                '(("a" nil nil "asking") ("w" nil nil "waiting")
                  ("r" nil nil "ready") ("n" nil nil "netfail")))))
    (should (equal '("n" "w" "a") (mapcar #'car order)))))

(ert-deftest decknix-attention--within-a-state-the-longest-wait-comes-first ()
  (let* ((since '(("old" . 100.0) ("new" . 200.0)))
         (order (decknix-attention-order
                 '(("new" nil nil "asking") ("old" nil nil "asking"))
                 (lambda (s) (cdr (assoc (car s) since))))))
    (should (equal '("old" "new") (mapcar #'car order)))))

(ert-deftest decknix-attention--next-walks-the-queue-and-wraps ()
  (should (equal 'b (decknix-attention-next '(a b c) 'a)))
  (should (equal 'a (decknix-attention-next '(a b c) 'c)))
  (should (equal 'a (decknix-attention-next '(a b c) 'elsewhere)))
  (should-not (decknix-attention-next nil 'a)))

(ert-deftest decknix-attention--observe-reports-the-edge-once ()
  (decknix-attention-test--with-buffers '("dk-att-a")
    (let ((b (get-buffer "dk-att-a")))
      (should-not (decknix-attention-observe b "working" 1.0))
      (should (decknix-attention-observe b "asking" 2.0))
      (should-not (decknix-attention-observe b "asking" 3.0))
      ;; A different attention state is a new call on you.
      (should (decknix-attention-observe b "waiting" 4.0)))))

(ert-deftest decknix-attention--since-survives-repeated-observation ()
  "Oldest waiting means longest in the state, not last observed."
  (decknix-attention-test--with-buffers '("dk-att-a")
    (let ((b (get-buffer "dk-att-a")))
      (decknix-attention-observe b "asking" 10.0)
      (decknix-attention-observe b "asking" 50.0)
      (should (= 10.0 (decknix-attention-since b))))))

(ert-deftest decknix-attention--count-reads-only-the-table ()
  (decknix-attention-test--with-buffers '("a" "b" "c" "d")
    (decknix-attention-observe (get-buffer "a") "asking")
    (decknix-attention-observe (get-buffer "b") "netfail")
    (decknix-attention-observe (get-buffer "c") "working")
    (decknix-attention-observe (get-buffer "d") "ready")
    (should (equal '(2 . 3) (decknix-attention-count)))
    (kill-buffer "a")
    (should (equal '(1 . 2) (decknix-attention-count)))))

(ert-deftest decknix-attention--buffers-follow-the-snapshot ()
  (decknix-attention-test--with-buffers '("*Claude: x*" "*Claude: y*")
    (cl-letf (((symbol-function 'decknix--hub-review-session-snapshot)
               (lambda () '(("*Claude: x*" nil nil "asking")
                            ("*Claude: y*" nil nil "waiting")
                            ("*Claude: gone*" nil nil "netfail")))))
      (should (equal (list (get-buffer "*Claude: y*") (get-buffer "*Claude: x*"))
                     (decknix-attention-buffers))))))

(ert-deftest decknix-attention--jump-selects-the-tab-holding-the-session ()
  "A session in its own tab is visited there, not pulled into this one."
  (let ((tab-bar-show nil))
    (tab-bar-mode 1)
    (unwind-protect
        (decknix-attention-test--with-buffers '("*Claude: tabbed*" "dk-other")
          (let ((target (get-buffer "*Claude: tabbed*")))
            (delete-other-windows)
            (switch-to-buffer target)
            (tab-bar-new-tab)
            (switch-to-buffer "dk-other")
            (should (= 2 (1+ (tab-bar--current-tab-index))))
            (cl-letf (((symbol-function 'decknix--hub-review-session-snapshot)
                       (lambda () '(("*Claude: tabbed*" nil nil "asking")))))
              (decknix-attention-jump))
            (should (= 1 (1+ (tab-bar--current-tab-index))))
            (should (eq target (window-buffer (selected-window))))
            ;; Not duplicated into the other tab's window either.
            (tab-bar-select-tab 2)
            (should (eq (get-buffer "dk-other") (window-buffer (selected-window))))))
      (while (> (length (tab-bar-tabs)) 1) (tab-bar-close-tab))
      (tab-bar-mode -1))))

(ert-deftest decknix-attention--jump-with-nothing-waiting-says-so ()
  (decknix-attention-test--with-buffers '()
    (cl-letf (((symbol-function 'decknix--hub-review-session-snapshot)
               (lambda () '(("x" nil nil "ready")))))
      (should (equal "No session needs you" (decknix-attention-jump))))))

(ert-deftest decknix-attention--age-label-is-compact ()
  (should (equal "now" (decknix-attention-age-label 100.0 130.0)))
  (should (equal "12m" (decknix-attention-age-label 0.0 720.0)))
  (should (equal "3h" (decknix-attention-age-label 0.0 10800.0)))
  (should (equal "2d" (decknix-attention-age-label 0.0 172800.0)))
  (should (equal "" (decknix-attention-age-label nil))))

(provide 'decknix-attention-test)
;;; decknix-attention-test.el ends here
