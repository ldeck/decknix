;;; decknix-hub-pr-lookup-test.el --- Tests for hub-pr lookup -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-pr-lookup "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning current behaviour of:
;;
;;   `decknix--hub-pr-status-from-hub' — walks `decknix--hub-wip' and
;;     `decknix--hub-reviews' to return a normalised PR status alist.
;;   `decknix--hub-pr-cache-get' — TTL-gated read of the offline PR
;;     cache (`decknix--hub-pr-cache'); appends `(stale . t)' on miss.

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

;; -- cache-get fixtures --------------------------------------------

(defun decknix-test--cache-with (url ts status)
  "Build a `decknix--hub-pr-cache' hash table with one entry."
  (let ((h (make-hash-table :test 'equal)))
    (puthash url (cons ts status) h)
    h))

;; -- cache-get: empty / missing ------------------------------------

(ert-deftest decknix-hub-pr-cache-get--empty-cache ()
  "Empty cache returns nil for any URL."
  (let ((decknix--hub-pr-cache (make-hash-table :test 'equal))
        (decknix--hub-pr-cache-ttl 180))
    (should (null (decknix--hub-pr-cache-get
                   "https://github.com/o/r/pull/1")))))

(ert-deftest decknix-hub-pr-cache-get--miss-other-url ()
  "Cache hit on different URL doesn't satisfy the lookup."
  (let* ((other "https://github.com/o/r/pull/2")
         (decknix--hub-pr-cache
          (decknix-test--cache-with other (float-time) '((state . "OPEN"))))
         (decknix--hub-pr-cache-ttl 180))
    (should (null (decknix--hub-pr-cache-get
                   "https://github.com/o/r/pull/1")))))

;; -- cache-get: fresh hit ------------------------------------------

(ert-deftest decknix-hub-pr-cache-get--fresh-hit ()
  "Entry younger than TTL returns the status alist verbatim."
  (let* ((url "https://github.com/o/r/pull/1")
         (status '((state . "OPEN") (title . "fresh")))
         (decknix--hub-pr-cache
          (decknix-test--cache-with url (float-time) status))
         (decknix--hub-pr-cache-ttl 180)
         (result (decknix--hub-pr-cache-get url)))
    (should (equal result status))
    (should (null (alist-get 'stale result)))))

;; -- cache-get: stale hit ------------------------------------------

(ert-deftest decknix-hub-pr-cache-get--stale-hit ()
  "Entry older than TTL returns status with `(stale . t)' appended."
  (let* ((url "https://github.com/o/r/pull/1")
         (status '((state . "OPEN") (title . "old")))
         (decknix--hub-pr-cache
          (decknix-test--cache-with url
                                    (- (float-time) 600)  ; 10 min ago
                                    status))
         (decknix--hub-pr-cache-ttl 180)
         (result (decknix--hub-pr-cache-get url)))
    ;; Original entries preserved.
    (should (equal (alist-get 'state result) "OPEN"))
    (should (equal (alist-get 'title result) "old"))
    ;; Stale marker present and eq-t.
    (should (eq (alist-get 'stale result) t))))

(ert-deftest decknix-hub-pr-cache-get--boundary-just-fresh ()
  "Entry exactly at TTL boundary minus epsilon counts as fresh."
  (let* ((url "https://github.com/o/r/pull/1")
         (status '((state . "OPEN")))
         ;; 1 second younger than TTL.
         (decknix--hub-pr-cache
          (decknix-test--cache-with url (- (float-time) 179) status))
         (decknix--hub-pr-cache-ttl 180)
         (result (decknix--hub-pr-cache-get url)))
    (should (equal result status))
    (should (null (alist-get 'stale result)))))

(ert-deftest decknix-hub-pr-cache-get--boundary-just-stale ()
  "Entry just past TTL counts as stale."
  (let* ((url "https://github.com/o/r/pull/1")
         (status '((state . "OPEN")))
         ;; 1 second past TTL.
         (decknix--hub-pr-cache
          (decknix-test--cache-with url (- (float-time) 181) status))
         (decknix--hub-pr-cache-ttl 180)
         (result (decknix--hub-pr-cache-get url)))
    (should (eq (alist-get 'stale result) t))))

(ert-deftest decknix-hub-pr-cache-get--stale-preserves-existing-keys ()
  "Stale marker doesn't shadow keys already present in the status alist."
  (let* ((url "https://github.com/o/r/pull/1")
         (status '((state . "OPEN") (ci-status . "SUCCESS") (draft . t)))
         (decknix--hub-pr-cache
          (decknix-test--cache-with url (- (float-time) 1000) status))
         (decknix--hub-pr-cache-ttl 180)
         (result (decknix--hub-pr-cache-get url)))
    (should (equal (alist-get 'state result) "OPEN"))
    (should (equal (alist-get 'ci-status result) "SUCCESS"))
    (should (eq (alist-get 'draft result) t))
    (should (eq (alist-get 'stale result) t))))

(provide 'decknix-hub-pr-lookup-test)
;;; decknix-hub-pr-lookup-test.el ends here
