;;; decknix-sidebar-previous-test.el --- Tests for previous-sessions dedupe -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-sidebar-previous "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix--sidebar-previous-dedupe',
;; the pure list -> list dedupe used to collapse parallel
;; session-id snapshots of the same conversation down to one row in
;; the sidebar Previous Sessions section.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-sidebar-previous)

(defun decknix-sidebar-previous-test--entry (sid ck &optional name)
  "Build a Previous-Sessions alist with SID and CK."
  (list (cons 'session-id sid)
        (cons 'name (or name sid))
        (cons 'workspace "/tmp")
        (cons 'conv-key ck)
        (cons 'tags nil)))

;; -- empty / single ------------------------------------------------

(ert-deftest decknix-sidebar-previous-dedupe--empty ()
  "Empty input returns empty list."
  (should (null (decknix--sidebar-previous-dedupe nil)))
  (should (null (decknix--sidebar-previous-dedupe '()))))

(ert-deftest decknix-sidebar-previous-dedupe--single-entry-passthrough ()
  "A single entry survives untouched."
  (let* ((e (decknix-sidebar-previous-test--entry "s1" "ck-a"))
         (result (decknix--sidebar-previous-dedupe (list e))))
    (should (= (length result) 1))
    (should (equal (alist-get 'session-id (car result)) "s1"))
    (should (equal (alist-get 'conv-key (car result)) "ck-a"))))

;; -- conv-key collapsing ------------------------------------------

(ert-deftest decknix-sidebar-previous-dedupe--collapses-by-conv-key ()
  "Two entries with the same conv-key collapse to the first."
  (let* ((e1 (decknix-sidebar-previous-test--entry "s1" "ck-a" "first"))
         (e2 (decknix-sidebar-previous-test--entry "s2" "ck-a" "second"))
         (result (decknix--sidebar-previous-dedupe (list e1 e2))))
    (should (= (length result) 1))
    ;; First occurrence wins (input order).
    (should (equal (alist-get 'session-id (car result)) "s1"))
    (should (equal (alist-get 'name (car result)) "first"))))

(ert-deftest decknix-sidebar-previous-dedupe--preserves-order ()
  "Distinct conv-keys all kept, in original order."
  (let* ((e1 (decknix-sidebar-previous-test--entry "s1" "ck-a"))
         (e2 (decknix-sidebar-previous-test--entry "s2" "ck-b"))
         (e3 (decknix-sidebar-previous-test--entry "s3" "ck-c"))
         (result (decknix--sidebar-previous-dedupe (list e1 e2 e3))))
    (should (= (length result) 3))
    (should (equal (mapcar (lambda (e) (alist-get 'session-id e)) result)
                   '("s1" "s2" "s3")))))

(ert-deftest decknix-sidebar-previous-dedupe--three-share-one-key ()
  "Three entries sharing a conv-key collapse to one (the first)."
  (let* ((e1 (decknix-sidebar-previous-test--entry "s1" "ck-a" "alpha"))
         (e2 (decknix-sidebar-previous-test--entry "s2" "ck-a" "beta"))
         (e3 (decknix-sidebar-previous-test--entry "s3" "ck-a" "gamma"))
         (result (decknix--sidebar-previous-dedupe (list e1 e2 e3))))
    (should (= (length result) 1))
    (should (equal (alist-get 'name (car result)) "alpha"))))

;; -- nil conv-key fallback ---------------------------------------

(ert-deftest decknix-sidebar-previous-dedupe--nil-conv-key-uses-sid ()
  "Entries with no conv-key dedupe by session-id instead."
  (let* ((e1 (decknix-sidebar-previous-test--entry "s1" nil))
         (e2 (decknix-sidebar-previous-test--entry "s1" nil))
         (e3 (decknix-sidebar-previous-test--entry "s2" nil))
         (result (decknix--sidebar-previous-dedupe (list e1 e2 e3))))
    (should (= (length result) 2))
    (should (equal (mapcar (lambda (e) (alist-get 'session-id e)) result)
                   '("s1" "s2")))))

(ert-deftest decknix-sidebar-previous-dedupe--mixed-nil-and-conv-key ()
  "An entry with nil conv-key and an entry with the same sid but a
conv-key are treated as distinct keys (the conv-key entry uses ck,
the no-conv-key entry uses (sid . SID))."
  (let* ((e1 (decknix-sidebar-previous-test--entry "s1" "ck-a" "with-ck"))
         (e2 (decknix-sidebar-previous-test--entry "s1" nil "no-ck"))
         (result (decknix--sidebar-previous-dedupe (list e1 e2))))
    (should (= (length result) 2))
    (should (equal (alist-get 'name (nth 0 result)) "with-ck"))
    (should (equal (alist-get 'name (nth 1 result)) "no-ck"))))

(ert-deftest decknix-sidebar-previous-dedupe--input-not-mutated ()
  "Dedupe does not destructively modify the input list."
  (let* ((e1 (decknix-sidebar-previous-test--entry "s1" "ck-a"))
         (e2 (decknix-sidebar-previous-test--entry "s2" "ck-a"))
         (input (list e1 e2))
         (input-copy (copy-tree input)))
    (decknix--sidebar-previous-dedupe input)
    (should (equal input input-copy))))

(provide 'decknix-sidebar-previous-test)
;;; decknix-sidebar-previous-test.el ends here
