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

(provide 'decknix-hub-ready-filter-test)
;;; decknix-hub-ready-filter-test.el ends here
