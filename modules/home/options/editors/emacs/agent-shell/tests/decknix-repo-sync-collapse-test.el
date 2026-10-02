;;; decknix-repo-sync-collapse-test.el --- Folding failed rows -*- lexical-binding: t -*-

;;; Commentary:
;;
;; A sweep that cannot reach the network fails every repo at once --
;; measured 11 identical "sync failed" rows -- which crowds out the kinds
;; that name a specific, fixable problem.  What is pinned here is that only
;; `failed' folds: a stale lock, a dirty tree and a diverged branch each
;; have their own remedy, so folding them would hide the actionable rows
;; behind a number.

;;; Code:

(require 'ert)
(require 'decknix-repo-sync)
(require 'decknix-repo-sync-actions)

(defun decknix-rsc-test--p (kind name) (list :kind kind :name name))

(ert-deftest decknix-rsc--folds-failed-past-the-threshold ()
  (let* ((ps (list (decknix-rsc-test--p 'failed "a")
                   (decknix-rsc-test--p 'failed "b")
                   (decknix-rsc-test--p 'failed "c")
                   (decknix-rsc-test--p 'failed "d")))
         (split (decknix--repo-sync-collapse ps 3 nil)))
    (should-not (car split))
    (should (= 4 (length (cdr split))))))

(ert-deftest decknix-rsc--leaves-a-few-failures-alone ()
  "Below the threshold the rows are worth reading individually, and a
summary of one is not a summary."
  (let* ((ps (list (decknix-rsc-test--p 'failed "a")
                   (decknix-rsc-test--p 'failed "b")))
         (split (decknix--repo-sync-collapse ps 3 nil)))
    (should (= 2 (length (car split))))
    (should-not (cdr split))))

(ert-deftest decknix-rsc--never-folds-an-actionable-kind ()
  "Each of these names a distinct remedy; collapsing them would bury it."
  (let* ((ps (list (decknix-rsc-test--p 'lock "a")
                   (decknix-rsc-test--p 'dirty "b")
                   (decknix-rsc-test--p 'diverged "c")
                   (decknix-rsc-test--p 'lock "d")
                   (decknix-rsc-test--p 'dirty "e")))
         (split (decknix--repo-sync-collapse ps 1 nil)))
    (should (= 5 (length (car split))))
    (should-not (cdr split))))

(ert-deftest decknix-rsc--keeps-actionable-rows-when-failures-fold ()
  "The whole point: the lock row must survive the fold that hides the
failures, since it is the one with a remedy."
  (let* ((ps (list (decknix-rsc-test--p 'lock "keepme")
                   (decknix-rsc-test--p 'failed "a")
                   (decknix-rsc-test--p 'failed "b")
                   (decknix-rsc-test--p 'failed "c")
                   (decknix-rsc-test--p 'failed "d")))
         (split (decknix--repo-sync-collapse ps 2 nil)))
    (should (equal '("keepme") (mapcar (lambda (p) (plist-get p :name))
                                       (car split))))
    (should (= 4 (length (cdr split))))))

(ert-deftest decknix-rsc--expanded-shows-everything ()
  (let* ((ps (list (decknix-rsc-test--p 'failed "a")
                   (decknix-rsc-test--p 'failed "b")
                   (decknix-rsc-test--p 'failed "c")
                   (decknix-rsc-test--p 'failed "d")))
         (split (decknix--repo-sync-collapse ps 2 t)))
    (should (= 4 (length (car split))))
    (should-not (cdr split))))

(ert-deftest decknix-rsc--label-states-the-count ()
  (should (string-match-p "11" (decknix--repo-sync-collapsed-label
                                (make-list 11 '(:kind failed))))))


;; --- reset targets ----------------------------------------------------

(ert-deftest decknix-rsc--local-is-the-default-reset-target ()
  "The launchd sweep keeps local in step with origin, so resetting to the
LOCAL branch discards only uncommitted work and leaves a checkout pinned
to a particular revision still pinned.  Resetting to origin would discard
those commits -- a larger loss, so never the default."
  (should (equal "main" (decknix-repo-sync-reset-ref 'local "main"))))

(ert-deftest decknix-rsc--origin-target-is-the-remote-ref ()
  (should (equal "origin/main" (decknix-repo-sync-reset-ref 'origin "main"))))

(ert-deftest decknix-rsc--an-unknown-target-does-not-become-origin ()
  "Falling back to the remote ref would discard local commits for a typo."
  (should (equal "main" (decknix-repo-sync-reset-ref 'nonsense "main"))))

(ert-deftest decknix-rsc--targets-differ-so-the-choice-is-meaningful ()
  (should-not (equal (decknix-repo-sync-reset-ref 'local "develop")
                     (decknix-repo-sync-reset-ref 'origin "develop"))))

(provide 'decknix-repo-sync-collapse-test)
;;; decknix-repo-sync-collapse-test.el ends here
