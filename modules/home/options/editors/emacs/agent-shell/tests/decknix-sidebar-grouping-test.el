;;; decknix-sidebar-grouping-test.el --- Tests for sidebar grouping -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification tests for the pure grouping layer behind the Live and
;; Previous sub-headers.  Rendering is exercised live; only the decision
;; layer is unit-tested here per AGENTS.md Rule 2.

;;; Code:

(require 'ert)
(require 'decknix-sidebar-grouping)

;; --- the cycle -------------------------------------------------------

(ert-deftest decknix-group-cycle--visits-every-mode-and-returns ()
  "off -> workspace -> repo -> off."
  (should (eq 'workspace (decknix-sidebar-group-next 'off)))
  (should (eq 'repo (decknix-sidebar-group-next 'workspace)))
  (should (eq 'off (decknix-sidebar-group-next 'repo))))

(ert-deftest decknix-group-cycle--unknown-mode-recovers ()
  "A stale persisted value must not wedge the sidebar."
  (should (eq 'off (decknix-sidebar-group-next 'tags)))
  (should (eq 'off (decknix-sidebar-group-next nil))))

(ert-deftest decknix-group-cycle--labels-are-stable ()
  "The footer/transient reads these; `off' is the catch-all."
  (should (equal "workspace" (decknix-sidebar-group-mode-label 'workspace)))
  (should (equal "repo" (decknix-sidebar-group-mode-label 'repo)))
  (should (equal "off" (decknix-sidebar-group-mode-label 'off)))
  (should (equal "off" (decknix-sidebar-group-mode-label 'nonsense))))

;; --- key derivation --------------------------------------------------

(ert-deftest decknix-group-workspace--is-the-basename ()
  "Headed like WIP: a bare name, not a path."
  (should (equal "nurturecloud"
                 (decknix-sidebar-group-workspace-label "/Users/x/Code/nurturecloud/"))))

(ert-deftest decknix-group-workspace--trailing-slash-does-not-split-a-group ()
  "\"/a/b\" and \"/a/b/\" are one workspace, not two."
  (should (equal (decknix-sidebar-group-workspace-label "/a/b")
                 (decknix-sidebar-group-workspace-label "/a/b/"))))

(ert-deftest decknix-group-workspace--nil-for-no-path ()
  (should-not (decknix-sidebar-group-workspace-label nil))
  (should-not (decknix-sidebar-group-workspace-label "")))

(ert-deftest decknix-group-repo--parses-the-pr-key ()
  (should (equal "rea-integration"
                 (decknix-sidebar-group-repo-label '("rea-integration#65"))))
  (should (equal "nct-intelligence-beholder"
                 (decknix-sidebar-group-repo-label '("nct-intelligence-beholder#1419")))))

(ert-deftest decknix-group-repo--takes-the-first-of-several ()
  "A multi-PR review is one row; filing it under every repo double-counts."
  (should (equal "upside"
                 (decknix-sidebar-group-repo-label '("upside#1" "upside#2")))))

(ert-deftest decknix-group-repo--nil-when-there-is-no-pr ()
  "Non-review sessions have no repo and must not get a guessed one."
  (should-not (decknix-sidebar-group-repo-label nil))
  (should-not (decknix-sidebar-group-repo-label '()))
  (should-not (decknix-sidebar-group-repo-label '("no-hash-here"))))

;; --- grouping --------------------------------------------------------

(ert-deftest decknix-group-items--sorts-headings-alphabetically ()
  "Headings must not move when an unrelated session starts."
  (let ((groups (decknix-sidebar-group-items
                 '("zeta" "alpha" "mid")
                 #'identity)))
    (should (equal '("alpha" "mid" "zeta") (mapcar #'car groups)))))

(ert-deftest decknix-group-items--keeps-item-order-within-a-group ()
  "Whatever ordering the caller applied (recency, status) survives."
  (let ((groups (decknix-sidebar-group-items
                 '((a . 1) (a . 2) (a . 3))
                 (lambda (it) (symbol-name (car it))))))
    (should (equal '((a . 1) (a . 2) (a . 3)) (cdr (assoc "a" groups))))))

(ert-deftest decknix-group-items--unscoped-goes-last ()
  "A session with no repo is a real category, listed after the named ones."
  (let* ((groups (decknix-sidebar-group-items
                  '("upside#1" "no-pr" "zzz#2")
                  (lambda (it) (decknix-sidebar-group-repo-label (list it)))))
         (labels (mapcar #'car groups)))
    (should (equal '("upside" "zzz" "unscoped") labels))
    (should (equal '("no-pr") (cdr (assoc "unscoped" groups))))))

(ert-deftest decknix-group-items--no-unscoped-heading-when-all-are-keyed ()
  "The heading appears only when it has rows; an empty one is noise."
  (let ((groups (decknix-sidebar-group-items '("a#1" "b#2")
                                             (lambda (it)
                                               (decknix-sidebar-group-repo-label
                                                (list it))))))
    (should-not (assoc "unscoped" groups))))

(ert-deftest decknix-group-items--empty-input-is-nil ()
  "Callers fall back to a flat render without a special case."
  (should-not (decknix-sidebar-group-items nil #'identity)))

(ert-deftest decknix-group-items--every-item-survives-grouping ()
  "The guard that matters: grouping is a re-ordering, never a filter.
A dropped row would make the section quietly under-report what is
running, which is worse than not grouping at all."
  (let* ((items '("a#1" "b#2" "plain" "a#3" nil))
         (groups (decknix-sidebar-group-items
                  items (lambda (it) (decknix-sidebar-group-repo-label (list it)))))
         (flattened (apply #'append (mapcar #'cdr groups))))
    (should (= (length items) (length flattened)))
    (dolist (it items)
      (should (member it flattened)))))

(provide 'decknix-sidebar-grouping-test)
;;; decknix-sidebar-grouping-test.el ends here
