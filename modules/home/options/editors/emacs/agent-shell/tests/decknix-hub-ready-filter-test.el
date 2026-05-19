;;; decknix-hub-ready-filter-test.el --- Tests for hub ready-for-review predicate -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-ready-filter "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix--hub-request-ready-p'
;; extracted from `decknix-agent-shell-workspace' (workspace-bulk).
;; Pins the four-clause contract: CI status in {pass,soft_fail},
;; not CONFLICTING, not draft, not already reviewed by me.  The CI
;; classification is mocked through `cl-letf' so the predicate's
;; behaviour can be exercised without standing up real CI fixtures
;; (those live in `decknix-hub-ci-test').

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-hub-ready-filter)

;; Forward-declare `decknix--hub-reviews' WITH an initialiser so the
;; reader/entries tests can `let'-bind it dynamically.  Per
;; AGENTS.md (Emacs / Tests §2): a bare `(defvar X)' is only a
;; compiler hint; the let binds lexically and the byte-compiled
;; module sees the global as void.  An initialiser registers the
;; symbol as `special-variable-p' so the let binding is dynamic and
;; the module's `varref' resolves to it.
(defvar decknix--hub-reviews nil)
;; Forward-declare with nil so the reviewed-visible predicate
;; (called from the filter chain in decknix--hub-review-ready-requests)
;; sees a bound, special variable.  nil = filter off, show everything,
;; which matches the "all stubs return t" test philosophy.
(defvar decknix--hub-requests-hide-reviewed nil)

(defmacro decknix-hub-ready-filter-test--with-ci (status &rest body)
  "Evaluate BODY with `decknix--hub-ci-classify' stubbed to return STATUS.
The stub ignores its argument so callers can pass any ITEM shape."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'decknix--hub-ci-classify)
              (lambda (_ci) ,status)))
     ,@body))

;; -- ready: positive cases ----------------------------------------

(ert-deftest decknix-hub-ready-filter/ready-when-pass-and-clean ()
  "CI pass + not conflicting + not draft + no my-review => ready."
  (decknix-hub-ready-filter-test--with-ci "pass"
    (should (decknix--hub-request-ready-p
             '((ci . anything)
               (mergeable . "MERGEABLE")
               (draft . :json-false)
               (my_review . nil))))))

(ert-deftest decknix-hub-ready-filter/ready-when-soft-fail ()
  "soft_fail (lint-only) still counts as ready."
  (decknix-hub-ready-filter-test--with-ci "soft_fail"
    (should (decknix--hub-request-ready-p
             '((ci . anything)
               (mergeable . "MERGEABLE")
               (draft . :json-false)
               (my_review . nil))))))

(ert-deftest decknix-hub-ready-filter/ready-tolerates-missing-fields ()
  "Absent mergeable / draft / my_review fields default to ready."
  (decknix-hub-ready-filter-test--with-ci "pass"
    (should (decknix--hub-request-ready-p '((ci . anything))))))

(ert-deftest decknix-hub-ready-filter/ready-allows-commented-review ()
  "A prior COMMENTED review (not approve/reject) does not block ready."
  (decknix-hub-ready-filter-test--with-ci "pass"
    (should (decknix--hub-request-ready-p
             '((ci . anything)
               (my_review . "COMMENTED"))))))

;; -- not ready: each clause individually --------------------------

(ert-deftest decknix-hub-ready-filter/not-ready-when-ci-fails ()
  "Hard fail blocks ready."
  (decknix-hub-ready-filter-test--with-ci "fail"
    (should-not (decknix--hub-request-ready-p
                 '((ci . anything)
                   (mergeable . "MERGEABLE"))))))

(ert-deftest decknix-hub-ready-filter/not-ready-when-ci-running ()
  "Pending CI blocks ready."
  (decknix-hub-ready-filter-test--with-ci "running"
    (should-not (decknix--hub-request-ready-p
                 '((ci . anything))))))

(ert-deftest decknix-hub-ready-filter/not-ready-when-ci-unknown ()
  "Unknown CI blocks ready (we don't approve unseen pipelines)."
  (decknix-hub-ready-filter-test--with-ci "unknown"
    (should-not (decknix--hub-request-ready-p
                 '((ci . anything))))))

(ert-deftest decknix-hub-ready-filter/not-ready-when-conflicting ()
  "CONFLICTING mergeable blocks ready even on green CI."
  (decknix-hub-ready-filter-test--with-ci "pass"
    (should-not (decknix--hub-request-ready-p
                 '((ci . anything)
                   (mergeable . "CONFLICTING"))))))

(ert-deftest decknix-hub-ready-filter/not-ready-when-draft ()
  "draft = t blocks ready; only `eq t' counts (alists carry t literal)."
  (decknix-hub-ready-filter-test--with-ci "pass"
    (should-not (decknix--hub-request-ready-p
                 '((ci . anything)
                   (draft . t))))))

(ert-deftest decknix-hub-ready-filter/not-ready-when-already-approved ()
  "An APPROVED review of mine drops the item from ready."
  (decknix-hub-ready-filter-test--with-ci "pass"
    (should-not (decknix--hub-request-ready-p
                 '((ci . anything)
                   (my_review . "APPROVED"))))))

(ert-deftest decknix-hub-ready-filter/not-ready-when-changes-requested ()
  "A CHANGES_REQUESTED review of mine drops the item from ready."
  (decknix-hub-ready-filter-test--with-ci "pass"
    (should-not (decknix--hub-request-ready-p
                 '((ci . anything)
                   (my_review . "CHANGES_REQUESTED"))))))

;; -- ready-requests reader ----------------------------------------
;;
;; The reader composes eight predicates over `decknix--hub-reviews'.
;; Tests stub all seven visibility predicates plus `ci-classify' so the
;; reader's filter composition is the only thing under test (the
;; predicates themselves are characterised in their own packages).

(defmacro decknix-hub-ready-filter-test--with-stubs (&rest body)
  "Evaluate BODY with all visibility predicates stubbed to t.
Also stubs `decknix--hub-ci-classify' to return \"pass\" so the
ready predicate's CI clause passes by default.  Individual tests
override specific stubs to flip their predicate to nil."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'decknix--hub-item-visible-p)
              (lambda (_repo) t))
             ((symbol-function 'decknix--hub-age-visible-p)
              (lambda (_iso) t))
             ((symbol-function 'decknix--hub-ci-visible-p)
              (lambda (_item) t))
             ((symbol-function 'decknix--hub-bot-visible-p)
              (lambda (_item) t))
             ((symbol-function 'decknix--hub-requests-attention-visible-p)
              (lambda (_item) t))
             ((symbol-function 'decknix--hub-requests-reviewed-visible-p)
              (lambda (_item) t))
             ((symbol-function 'decknix--hub-ci-classify)
              (lambda (_ci) "pass")))
     ,@body))

(ert-deftest decknix-hub-ready-filter/reader-empty-when-no-data ()
  "Nil `decknix--hub-reviews' yields an empty list (no crash)."
  (let ((decknix--hub-reviews nil))
    (decknix-hub-ready-filter-test--with-stubs
      (should (null (decknix--hub-review-ready-requests))))))

(ert-deftest decknix-hub-ready-filter/reader-empty-when-no-items ()
  "Data with no `items' alist key yields an empty list."
  (let ((decknix--hub-reviews '((generated_at . "2026-05-07"))))
    (decknix-hub-ready-filter-test--with-stubs
      (should (null (decknix--hub-review-ready-requests))))))

(ert-deftest decknix-hub-ready-filter/reader-passes-all-when-stubs-t ()
  "With all predicates t, every item passes through."
  (let ((decknix--hub-reviews
         '((items . (((ci . anything) (mergeable . "MERGEABLE"))
                     ((ci . anything) (mergeable . "MERGEABLE"))
                     ((ci . anything) (mergeable . "MERGEABLE")))))))
    (decknix-hub-ready-filter-test--with-stubs
      (should (= 3 (length (decknix--hub-review-ready-requests)))))))

(ert-deftest decknix-hub-ready-filter/reader-drops-failing-org ()
  "Org filter (item-visible-p) rejects the matching repo."
  (let ((decknix--hub-reviews
         '((items . (((repo . "ok/repo") (ci . anything))
                     ((repo . "bad/repo") (ci . anything)))))))
    (decknix-hub-ready-filter-test--with-stubs
      (cl-letf (((symbol-function 'decknix--hub-item-visible-p)
                 (lambda (repo) (not (equal repo "bad/repo")))))
        (let ((out (decknix--hub-review-ready-requests)))
          (should (= 1 (length out)))
          (should (equal "ok/repo" (alist-get 'repo (car out)))))))))

(ert-deftest decknix-hub-ready-filter/reader-drops-failing-ready-p ()
  "An item that fails the ready predicate (e.g. CONFLICTING) is dropped."
  (let ((decknix--hub-reviews
         '((items . (((number . 1) (ci . anything) (mergeable . "MERGEABLE"))
                     ((number . 2) (ci . anything) (mergeable . "CONFLICTING")))))))
    (decknix-hub-ready-filter-test--with-stubs
      (let ((out (decknix--hub-review-ready-requests)))
        (should (= 1 (length out)))
        (should (= 1 (alist-get 'number (car out))))))))

;; -- entries builder ----------------------------------------------
;;
;; The builder composes the reader with the sort routine and a few
;; icon helpers.  Tests stub the icons / tint to inert returns so the
;; structural contract (count, ordering, mention-only filter, cons
;; cell shape) is the only thing under test.

(defmacro decknix-hub-ready-filter-test--with-entry-stubs (&rest body)
  "Stub icon / tint helpers and the sort routine for entry tests.
`decknix--hub-sort-requests' returns ITEMS unchanged so the test can
assert input order is preserved.  Composes with
`decknix-hub-ready-filter-test--with-stubs' for the reader stubs."
  (declare (indent 0))
  `(decknix-hub-ready-filter-test--with-stubs
     (cl-letf (((symbol-function 'decknix--hub-sort-requests)
                (lambda (items) items))
               ((symbol-function 'decknix--hub-format-age)
                (lambda (_iso) "1h"))
               ((symbol-function 'decknix--hub-ci-icon)
                (lambda (_ci &optional _m) "✓"))
               ((symbol-function 'decknix--hub-review-icon)
                (lambda (_item) ""))
               ((symbol-function 'decknix--hub-request-has-live-session-p)
                (lambda (_item) nil))
               ((symbol-function 'decknix--hub-request-tint-active)
                (lambda (str _item) str)))
       ,@body)))

(ert-deftest decknix-hub-ready-filter/entries-empty-when-no-data ()
  "No reviews => no entries."
  (let ((decknix--hub-reviews nil))
    (decknix-hub-ready-filter-test--with-entry-stubs
      (should (null (decknix--hub-review-entries))))))

(ert-deftest decknix-hub-ready-filter/entries-cons-shape ()
  "Each entry is a (LABEL . ITEM) cons cell with a non-empty string label."
  (let ((decknix--hub-reviews
         '((items . (((repo . "owner/repo")
                      (number . 42)
                      (title . "Hello")
                      (ci . anything)
                      (mergeable . "MERGEABLE")))))))
    (decknix-hub-ready-filter-test--with-entry-stubs
      (let* ((out (decknix--hub-review-entries))
             (entry (car out)))
        (should (= 1 (length out)))
        (should (consp entry))
        (should (stringp (car entry)))
        (should (> (length (car entry)) 0))
        (should (= 42 (alist-get 'number (cdr entry))))))))

(ert-deftest decknix-hub-ready-filter/entries-mention-only-filters-in ()
  "MENTION-ONLY non-nil keeps only items with `mentioned' = t."
  (let ((decknix--hub-reviews
         '((items . (((number . 1) (ci . anything) (mergeable . "MERGEABLE")
                      (mentioned . t))
                     ((number . 2) (ci . anything) (mergeable . "MERGEABLE")
                      (mentioned . :json-false))
                     ((number . 3) (ci . anything) (mergeable . "MERGEABLE")
                      (mentioned . t)))))))
    (decknix-hub-ready-filter-test--with-entry-stubs
      (let* ((all (decknix--hub-review-entries))
             (only (decknix--hub-review-entries t))
             (only-numbers (mapcar (lambda (e) (alist-get 'number (cdr e)))
                                   only)))
        (should (= 3 (length all)))
        (should (= 2 (length only)))
        (should (equal '(1 3) only-numbers))))))

(ert-deftest decknix-hub-ready-filter/entries-preserves-sort-order ()
  "Entries are returned in the order `decknix--hub-sort-requests' produces.
The stub keeps input order, so output order matches input order."
  (let ((decknix--hub-reviews
         '((items . (((number . 10) (ci . anything) (mergeable . "MERGEABLE"))
                     ((number . 20) (ci . anything) (mergeable . "MERGEABLE"))
                     ((number . 30) (ci . anything) (mergeable . "MERGEABLE")))))))
    (decknix-hub-ready-filter-test--with-entry-stubs
      (let* ((out (decknix--hub-review-entries))
             (numbers (mapcar (lambda (e) (alist-get 'number (cdr e))) out)))
        (should (equal '(10 20 30) numbers))))))

(provide 'decknix-hub-ready-filter-test)
;;; decknix-hub-ready-filter-test.el ends here
