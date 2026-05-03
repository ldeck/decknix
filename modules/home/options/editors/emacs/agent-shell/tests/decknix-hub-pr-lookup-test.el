;;; decknix-hub-pr-lookup-test.el --- Tests for hub-pr lookup -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-pr-lookup "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning current behaviour of `decknix--hub-pr-status-from-hub'
;; — the data accessor that walks the heredoc-resident `decknix--hub-wip'
;; and `decknix--hub-reviews' globals to return a normalised PR status
;; alist.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-test-helpers)
(require 'decknix-hub-pr-lookup)

;; -- Fixtures ------------------------------------------------------

(defun decknix-test--wip-with (repo &rest prs)
  "Build a `decknix--hub-wip' alist with one repo group containing PRS."
  `((repos . (((repo . ,repo) (prs . ,prs))))))

(defun decknix-test--reviews-with (&rest items)
  "Build a `decknix--hub-reviews' alist with ITEMS list."
  `((items . ,items)))

;; -- nil / non-PR url ----------------------------------------------

(ert-deftest decknix-hub-pr-lookup--nil-url ()
  (let ((decknix--hub-wip nil) (decknix--hub-reviews nil))
    (should (null (decknix--hub-pr-status-from-hub nil)))))

(ert-deftest decknix-hub-pr-lookup--non-pr-url ()
  (let ((decknix--hub-wip nil) (decknix--hub-reviews nil))
    (should (null (decknix--hub-pr-status-from-hub
                   "https://github.com/owner/repo")))))

(ert-deftest decknix-hub-pr-lookup--both-empty ()
  "Valid URL but both globals nil -> nil."
  (let ((decknix--hub-wip nil) (decknix--hub-reviews nil))
    (should (null (decknix--hub-pr-status-from-hub
                   "https://github.com/o/r/pull/1")))))

;; -- WIP path ------------------------------------------------------

(ert-deftest decknix-hub-pr-lookup--wip-basic ()
  "Match in WIP returns alist with kind=wip and key fields."
  (let ((decknix--hub-wip
         (decknix-test--wip-with "o/r"
                                 (decknix-test-make-pr :number 1 :title "T")))
        (decknix--hub-reviews nil))
    (let ((result (decknix--hub-pr-status-from-hub
                   "https://github.com/o/r/pull/1")))
      (should result)
      (should (eq (alist-get 'kind result) 'wip))
      (should (equal (alist-get 'title result) "T")))))

(ert-deftest decknix-hub-pr-lookup--wip-state-uppercased ()
  "Lowercase state in JSON is uppercased in the result."
  (let ((decknix--hub-wip
         (decknix-test--wip-with "o/r"
                                 (decknix-test-make-pr :number 1 :state "open")))
        (decknix--hub-reviews nil))
    (let ((result (decknix--hub-pr-status-from-hub
                   "https://github.com/o/r/pull/1")))
      (should (equal (alist-get 'state result) "OPEN")))))

(ert-deftest decknix-hub-pr-lookup--wip-state-default ()
  "Missing state defaults to OPEN (via `(or X \"OPEN\")' branch)."
  (let* ((pr (decknix-test-make-pr :number 1))
         ;; Strip the state field entirely.
         (pr-no-state (assq-delete-all 'state pr))
         (decknix--hub-wip (decknix-test--wip-with "o/r" pr-no-state))
         (decknix--hub-reviews nil))
    (let ((result (decknix--hub-pr-status-from-hub
                   "https://github.com/o/r/pull/1")))
      (should (equal (alist-get 'state result) "OPEN")))))

(ert-deftest decknix-hub-pr-lookup--wip-draft-strict-eq-t ()
  "Draft is strict eq-t: t -> t, nil -> nil, \"true\" string -> nil."
  (let ((decknix--hub-wip
         (decknix-test--wip-with "o/r"
                                 (decknix-test-make-pr :number 1 :draft t)
                                 (decknix-test-make-pr :number 2 :draft "true")))
        (decknix--hub-reviews nil))
    (should (eq (alist-get 'draft (decknix--hub-pr-status-from-hub
                                   "https://github.com/o/r/pull/1"))
                t))
    (should (null (alist-get 'draft (decknix--hub-pr-status-from-hub
                                     "https://github.com/o/r/pull/2"))))))

(ert-deftest decknix-hub-pr-lookup--wip-other-repo-skipped ()
  "PR in a different repo group is not matched."
  (let ((decknix--hub-wip
         (decknix-test--wip-with "other/repo"
                                 (decknix-test-make-pr :number 1)))
        (decknix--hub-reviews nil))
    (should (null (decknix--hub-pr-status-from-hub
                   "https://github.com/o/r/pull/1")))))

(ert-deftest decknix-hub-pr-lookup--wip-other-number-skipped ()
  "Different PR number in same repo is skipped."
  (let ((decknix--hub-wip
         (decknix-test--wip-with "o/r"
                                 (decknix-test-make-pr :number 99)))
        (decknix--hub-reviews nil))
    (should (null (decknix--hub-pr-status-from-hub
                   "https://github.com/o/r/pull/1")))))

(ert-deftest decknix-hub-pr-lookup--wip-multiple-prs-finds-right ()
  "Multiple PRs in repo: only matching number returned."
  (let ((decknix--hub-wip
         (decknix-test--wip-with "o/r"
                                 (decknix-test-make-pr :number 1 :title "first")
                                 (decknix-test-make-pr :number 2 :title "second")))
        (decknix--hub-reviews nil))
    (should (equal (alist-get 'title
                              (decknix--hub-pr-status-from-hub
                               "https://github.com/o/r/pull/2"))
                   "second"))))

(ert-deftest decknix-hub-pr-lookup--wip-carries-ci-fields ()
  "Inner ci.status and ci.checks are flattened to top-level keys."
  (let* ((pr `((number . 1) (title . "T") (state . "open")
               (ci . ((status . "fail") (checks . (((name . "build")
                                                    (conclusion . "failure"))))))))
         (decknix--hub-wip (decknix-test--wip-with "o/r" pr))
         (decknix--hub-reviews nil)
         (result (decknix--hub-pr-status-from-hub
                  "https://github.com/o/r/pull/1")))
    (should (equal (alist-get 'ci-status result) "fail"))
    (should (= (length (alist-get 'checks result)) 1))))

;; -- Review path ---------------------------------------------------

(ert-deftest decknix-hub-pr-lookup--review-basic ()
  "Match in reviews returns alist with kind=review and state OPEN."
  (let* ((item `((repo . "o/r") (number . 1) (title . "Rev")
                 (created . "2026-01-01T00:00:00Z")
                 (my_review . "COMMENTED")
                 (ci . ((status . "pass")))))
         (decknix--hub-wip nil)
         (decknix--hub-reviews (decknix-test--reviews-with item))
         (result (decknix--hub-pr-status-from-hub
                  "https://github.com/o/r/pull/1")))
    (should result)
    (should (eq (alist-get 'kind result) 'review))
    (should (equal (alist-get 'state result) "OPEN"))
    (should (equal (alist-get 'my_review result) "COMMENTED"))))

(ert-deftest decknix-hub-pr-lookup--review-other-skipped ()
  (let* ((item `((repo . "other/repo") (number . 1)))
         (decknix--hub-wip nil)
         (decknix--hub-reviews (decknix-test--reviews-with item)))
    (should (null (decknix--hub-pr-status-from-hub
                   "https://github.com/o/r/pull/1")))))

;; -- Precedence: WIP wins over Reviews -----------------------------

(ert-deftest decknix-hub-pr-lookup--wip-precedence ()
  "When the same PR appears in both files, WIP is returned (catch order)."
  (let* ((wip-pr (decknix-test-make-pr :number 1 :title "wip"))
         (rev-item `((repo . "o/r") (number . 1) (title . "review")
                     (my_review . "APPROVED")))
         (decknix--hub-wip (decknix-test--wip-with "o/r" wip-pr))
         (decknix--hub-reviews (decknix-test--reviews-with rev-item))
         (result (decknix--hub-pr-status-from-hub
                  "https://github.com/o/r/pull/1")))
    (should (eq (alist-get 'kind result) 'wip))
    (should (equal (alist-get 'title result) "wip"))))

(provide 'decknix-hub-pr-lookup-test)
;;; decknix-hub-pr-lookup-test.el ends here
