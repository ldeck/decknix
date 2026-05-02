;;; decknix-hub-org-filter-test.el --- Tests for hub org-filter helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-org-filter "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning the current behaviour of the hub org-filter
;; helpers extracted from the agent-shell heredoc.  Covers the
;; visible-p predicate (default-show-all + per-org gate), the
;; discover-orgs scan over `decknix--hub-reviews' and `decknix--hub-wip',
;; and the summary string the toggles transient renders.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-test-helpers)
(require 'decknix-hub-org-filter)

;; -- Inline fixtures ----------------------------------------------

(defun decknix-test--make-hub-reviews (repos)
  "Build a `decknix--hub-reviews'-shaped alist from REPOS (list of strings)."
  `((items . ,(mapcar (lambda (r) `((repo . ,r))) repos))))

;; -- decknix--hub-org-visible-p -----------------------------------

(ert-deftest decknix-hub-org-filter/visible-p-nil-table-shows-all ()
  (let ((decknix--hub-org-visibility nil))
    (should (decknix--hub-org-visible-p "anyone"))
    (should (decknix--hub-org-visible-p ""))
    (should (decknix--hub-org-visible-p "Some/Other"))))

(ert-deftest decknix-hub-org-filter/visible-p-honours-table-entries ()
  (let ((decknix--hub-org-visibility (make-hash-table :test 'equal)))
    (puthash "shown-org" t decknix--hub-org-visibility)
    (puthash "hidden-org" nil decknix--hub-org-visibility)
    (should (decknix--hub-org-visible-p "shown-org"))
    (should-not (decknix--hub-org-visible-p "hidden-org"))))

(ert-deftest decknix-hub-org-filter/visible-p-missing-key-is-hidden ()
  ;; Once a filter table exists, any org NOT in the table is hidden
  ;; — gethash returns nil for missing keys.
  (let ((decknix--hub-org-visibility (make-hash-table :test 'equal)))
    (puthash "alpha" t decknix--hub-org-visibility)
    (should-not (decknix--hub-org-visible-p "beta"))))

;; -- decknix--hub-discover-orgs -----------------------------------

(ert-deftest decknix-hub-org-filter/discover-orgs-empty-when-no-data ()
  (let ((decknix--hub-reviews nil)
        (decknix--hub-wip nil))
    (should (equal '() (decknix--hub-discover-orgs)))))

(ert-deftest decknix-hub-org-filter/discover-orgs-reads-from-reviews ()
  (let ((decknix--hub-reviews
         (decknix-test--make-hub-reviews
          '("octocat/spoon" "octocat/fork")))
        (decknix--hub-wip nil))
    (should (equal '("octocat") (decknix--hub-discover-orgs)))))

(ert-deftest decknix-hub-org-filter/discover-orgs-reads-from-wip ()
  (let ((decknix--hub-reviews nil)
        (decknix--hub-wip
         (decknix-test-make-hub-wip
          (list (cons "raywhite/decknix"
                      (list (decknix-test-make-pr :number 1)))))))
    (should (equal '("raywhite") (decknix--hub-discover-orgs)))))

(ert-deftest decknix-hub-org-filter/discover-orgs-merges-and-sorts ()
  ;; Owners discovered from both sources are deduped and sorted
  ;; case-sensitively via `string<'.
  (let ((decknix--hub-reviews
         (decknix-test--make-hub-reviews
          '("zeta/r1" "alpha/r2" "alpha/r3")))
        (decknix--hub-wip
         (decknix-test-make-hub-wip
          (list (cons "mu/r4"
                      (list (decknix-test-make-pr :number 1)))
                (cons "alpha/r5"
                      (list (decknix-test-make-pr :number 2)))))))
    (should (equal '("alpha" "mu" "zeta") (decknix--hub-discover-orgs)))))

(ert-deftest decknix-hub-org-filter/discover-orgs-skips-empty-owners ()
  ;; Repo strings without a slash split into ("foo") so owner=foo;
  ;; an empty repo string yields owner="" which is rejected.
  (let ((decknix--hub-reviews
         (decknix-test--make-hub-reviews '("" "lone")))
        (decknix--hub-wip nil))
    (should (equal '("lone") (decknix--hub-discover-orgs)))))

;; -- decknix--hub-org-filter-summary ------------------------------

(ert-deftest decknix-hub-org-filter/summary-nil-table-is-all ()
  (let ((decknix--hub-org-visibility nil))
    (should (equal "all" (decknix--hub-org-filter-summary)))))

(ert-deftest decknix-hub-org-filter/summary-all-visible-is-all ()
  (let ((decknix--hub-reviews
         (decknix-test--make-hub-reviews '("alpha/r" "beta/r")))
        (decknix--hub-wip nil)
        (decknix--hub-org-visibility (make-hash-table :test 'equal)))
    (puthash "alpha" t decknix--hub-org-visibility)
    (puthash "beta" t decknix--hub-org-visibility)
    (should (equal "all" (decknix--hub-org-filter-summary)))))

(ert-deftest decknix-hub-org-filter/summary-zero-visible-is-none ()
  (let ((decknix--hub-reviews
         (decknix-test--make-hub-reviews '("alpha/r" "beta/r")))
        (decknix--hub-wip nil)
        (decknix--hub-org-visibility (make-hash-table :test 'equal)))
    (puthash "alpha" nil decknix--hub-org-visibility)
    (puthash "beta" nil decknix--hub-org-visibility)
    (should (equal "none" (decknix--hub-org-filter-summary)))))

(ert-deftest decknix-hub-org-filter/summary-partial-visible-is-fraction ()
  (let ((decknix--hub-reviews
         (decknix-test--make-hub-reviews '("alpha/r" "beta/r" "gamma/r")))
        (decknix--hub-wip nil)
        (decknix--hub-org-visibility (make-hash-table :test 'equal)))
    (puthash "alpha" t decknix--hub-org-visibility)
    (puthash "beta" nil decknix--hub-org-visibility)
    (puthash "gamma" t decknix--hub-org-visibility)
    (should (equal "2/3" (decknix--hub-org-filter-summary)))))

(provide 'decknix-hub-org-filter-test)
;;; decknix-hub-org-filter-test.el ends here
