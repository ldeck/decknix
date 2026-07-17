;;; decknix-capture-test.el --- Tests for quick-capture -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification tests for the pure helpers of `decknix-capture' -- type
;; -> label mapping, hub repo extraction, and the CLI argument builders.
;; The interactive prompts + async process orchestration are exercised
;; live; only the pure command construction is unit-tested here.

;;; Code:

(require 'ert)
(require 'decknix-capture)

;; -- type -> label ---------------------------------------------------

(ert-deftest decknix-capture--type-label ()
  (should (equal (decknix--capture-type-label "feature") "enhancement"))
  (should (equal (decknix--capture-type-label "bug") "bug"))
  (should (equal (decknix--capture-type-label "investigation") "investigation"))
  (should (null (decknix--capture-type-label "nope"))))

;; -- hub repo extraction ---------------------------------------------

(ert-deftest decknix-capture--repos-from-hub-merges-and-sorts ()
  "Repos from reviews + WIP are merged, de-duplicated, and sorted."
  (let ((reviews '((items . (((repo . "o/b")) ((repo . "o/a")) ((repo . "o/b"))))))
        (wip '((repos . (((repo . "o/c")) ((repo . "o/a")))))))
    (should (equal (decknix--capture-repos-from-hub reviews wip)
                   '("o/a" "o/b" "o/c")))))

(ert-deftest decknix-capture--repos-from-hub-tolerates-empty ()
  "Nil / empty / non-alist inputs yield an empty list, never an error."
  (should (equal (decknix--capture-repos-from-hub nil nil) '()))
  (should (equal (decknix--capture-repos-from-hub '((items . ())) '((repos . ())))
                 '())))

;; -- gh issue args ---------------------------------------------------

(ert-deftest decknix-capture--gh-issue-args-with-label ()
  (should (equal (decknix--capture-gh-issue-args "o/r" "Title" "Body" "bug")
                 '("issue" "create" "-R" "o/r" "-t" "Title" "-b" "Body" "-l" "bug"))))

(ert-deftest decknix-capture--gh-issue-args-no-label-no-body ()
  "Empty/nil label is omitted; nil body becomes an empty string."
  (should (equal (decknix--capture-gh-issue-args "o/r" "Title" nil "")
                 '("issue" "create" "-R" "o/r" "-t" "Title" "-b" ""))))

;; -- gh comment args -------------------------------------------------

(ert-deftest decknix-capture--gh-comment-args ()
  (should (equal (decknix--capture-gh-comment-args "o/r" 42 "hi")
                 '("issue" "comment" "42" "-R" "o/r" "-b" "hi"))))

;; -- task args -------------------------------------------------------

(ert-deftest decknix-capture--task-args-full ()
  (should (equal (decknix--capture-task-args "Do it" "conn" '("perf" "roster"))
                 '("add" "Do it" "project:conn" "+perf" "+roster"))))

(ert-deftest decknix-capture--task-args-minimal ()
  "Blank project and empty tags are dropped."
  (should (equal (decknix--capture-task-args "Do it" "" '(""))
                 '("add" "Do it"))))

(provide 'decknix-capture-test)
;;; decknix-capture-test.el ends here
