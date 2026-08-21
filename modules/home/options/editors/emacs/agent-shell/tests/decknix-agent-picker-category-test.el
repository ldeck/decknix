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

(ert-deftest decknix-picker-cat/asking-ranks-with-waiting ()
  "A session that ended on a question is blocked on you, like a permission
prompt -- so it sorts into the same top band, above a turn that merely
finished and wants reading."
  (should (= (decknix--agent-picker-attention-rank "asking")
             (decknix--agent-picker-attention-rank "waiting")))
  (should (< (decknix--agent-picker-attention-rank "asking")
             (decknix--agent-picker-attention-rank "ready"))))

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

(provide 'decknix-agent-picker-category-test)
;;; decknix-agent-picker-category-test.el ends here
