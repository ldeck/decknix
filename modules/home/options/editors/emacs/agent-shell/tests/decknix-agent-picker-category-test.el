;;; decknix-agent-picker-category-test.el --- Tests for picker category/attention -*- lexical-binding: t -*-

;; Author: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-picker-category "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests for the pure classifier + attention rank + stable sort behind
;; the C-c b picker category/attention features.

;;; Code:

(require 'ert)
(require 'decknix-agent-picker-category)

;; -- category classification ---------------------------------------

(ert-deftest decknix-picker-cat/requests-when-review ()
  (should (eq 'requests
              (decknix--agent-picker-category-of '("review" "svc" "#12"))))
  ;; review wins even with a PR number present
  (should (eq 'requests
              (decknix--agent-picker-category-of '("#12" "review")))))

(ert-deftest decknix-picker-cat/wip-when-pr-number-no-review ()
  (should (eq 'wip (decknix--agent-picker-category-of '("svc" "#636"))))
  (should (eq 'wip (decknix--agent-picker-category-of '("#1")))))

(ert-deftest decknix-picker-cat/other-otherwise ()
  (should (eq 'other (decknix--agent-picker-category-of '("helix" "nix"))))
  (should (eq 'other (decknix--agent-picker-category-of nil)))
  ;; a tag that merely starts with # but isn't #<digits> is not a PR tag
  (should (eq 'other (decknix--agent-picker-category-of '("#topic")))))

(ert-deftest decknix-picker-cat/labels ()
  (should (equal (decknix--agent-picker-category-label 'requests) "Req"))
  (should (equal (decknix--agent-picker-category-label 'wip) "WIP"))
  (should (equal (decknix--agent-picker-category-label 'other) "Oth")))

;; -- attention rank ------------------------------------------------

(ert-deftest decknix-picker-cat/attention-rank-order ()
  (should (< (decknix--agent-picker-attention-rank "waiting")
             (decknix--agent-picker-attention-rank "ready")))
  (should (< (decknix--agent-picker-attention-rank "ready")
             (decknix--agent-picker-attention-rank "closing")))
  (should (< (decknix--agent-picker-attention-rank "closing")
             (decknix--agent-picker-attention-rank "working")))
  (should (< (decknix--agent-picker-attention-rank "working")
             (decknix--agent-picker-attention-rank "finished-idle-unknown")))
  ;; finished ranks with ready (both are "awaiting me")
  (should (= (decknix--agent-picker-attention-rank "finished")
             (decknix--agent-picker-attention-rank "ready"))))

(ert-deftest decknix-picker-cat/every-needs-you-state-shares-the-top-band ()
  "Which of them comes first is `decknix-attention's call, not this rank's."
  (dolist (st decknix-attention-states)
    (should (= 0 (decknix--agent-picker-attention-rank st)))
    (should (< (decknix--agent-picker-attention-rank st)
               (decknix--agent-picker-attention-rank "ready")))))

;; -- stable attention + MRU sort -----------------------------------

(ert-deftest decknix-picker-cat/sort-attention-then-mru ()
  ;; items: (name rank mru).  Expect ordering by rank, MRU tiebreak.
  (let ((in '(("a" 3 0)   ; working, most recent
              ("b" 0 1)   ; waiting
              ("c" 1 2)   ; ready
              ("d" 3 3)   ; working, older
              ("e" 0 4)))) ; waiting, older
    (should (equal (decknix--agent-picker-order-index in)
                   '("b" "e" "c" "a" "d")))))

(ert-deftest decknix-picker-cat/sort-does-not-mutate-input ()
  (let* ((in '(("x" 1 0) ("y" 0 1)))
         (copy (copy-tree in)))
    (decknix--agent-picker-order-index in)
    (should (equal in copy))))

;; -- needs-you first, in the sidebar's order ----------------------

(ert-deftest decknix-picker-cat/needs-you-first-in-attention-order ()
  "netfail, waiting, asking, then the rest as before: ready, working by MRU."
  (let ((rows '((w1 "w1" "working" 0)
                (as "as" "asking" 1)
                (r1 "r1" "ready" 2)
                (wt "wt" "waiting" 3)
                (nf "nf" "netfail" 4)
                (w2 "w2" "working" 5))))
    (should (equal (decknix--agent-picker-order rows)
                   '(nf wt as r1 w1 w2)))))

(ert-deftest decknix-picker-cat/longest-wait-first-within-a-state ()
  "Ties within a state go to whoever has waited longest, not to MRU."
  (let* ((since '(("new" . 200.0) ("old" . 100.0)))
         (order-fn (lambda (tuples)
                     (decknix-attention-order
                      tuples (lambda (tu) (cdr (assoc (car tu) since)))))))
    (should (equal (decknix--agent-picker-order
                    '((new "new" "asking" 0) (old "old" "asking" 1))
                    order-fn)
                   '(old new)))))

(ert-deftest decknix-picker-cat/order-fn-sees-the-attention-rows-only ()
  (let (seen)
    (decknix--agent-picker-order
     '((a "a" "ready" 0) (b "b" "waiting" 1))
     (lambda (tuples) (setq seen (mapcar #'car tuples)) tuples))
    (should (equal seen '("b")))))

;; -- the sidebar's look --------------------------------------------

(ert-deftest decknix-picker-cat/prefix-is-the-sidebar-glyph-and-face ()
  (dolist (st '("netfail" "waiting" "asking" "working" "ready"
                "finished" "closing" "killed" nil))
    (let ((p (decknix--agent-picker-state-prefix st)))
      (should (equal (substring-no-properties p)
                     (concat (decknix--layout-state-glyph st) " ")))
      (should (equal (get-text-property 0 'face p)
                     (decknix--layout-state-face st))))))

(ert-deftest decknix-picker-cat/needs-you-shows-the-flag-in-the-attention-face ()
  (let ((p (decknix--agent-picker-state-prefix "asking")))
    (should (string-prefix-p decknix-attention-glyph p))
    (should (eq (get-text-property 0 'face p) 'decknix-attention-face))))

(provide 'decknix-agent-picker-category-test)
;;; decknix-agent-picker-category-test.el ends here
