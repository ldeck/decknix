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
  "Two entries with the same conv-key collapse to the NEWEST (last)."
  (let* ((e1 (decknix-sidebar-previous-test--entry "s1" "ck-a" "first"))
         (e2 (decknix-sidebar-previous-test--entry "s2" "ck-a" "second"))
         (result (decknix--sidebar-previous-dedupe (list e1 e2))))
    (should (= (length result) 1))
    ;; Newest occurrence wins (live file is appended oldest-first).
    (should (equal (alist-get 'session-id (car result)) "s2"))
    (should (equal (alist-get 'name (car result)) "second"))))

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
  "Three entries sharing a conv-key collapse to one (the NEWEST/last)."
  (let* ((e1 (decknix-sidebar-previous-test--entry "s1" "ck-a" "alpha"))
         (e2 (decknix-sidebar-previous-test--entry "s2" "ck-a" "beta"))
         (e3 (decknix-sidebar-previous-test--entry "s3" "ck-a" "gamma"))
         (result (decknix--sidebar-previous-dedupe (list e1 e2 e3))))
    (should (= (length result) 1))
    (should (equal (alist-get 'session-id (car result)) "s3"))
    (should (equal (alist-get 'name (car result)) "gamma"))))

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

;; -- display-name: re-derive from the live tag store -----------------
;;
;; The Previous-Sessions snapshot bakes a `name' field at record time.
;; When a conversation is (re-)tagged after the snapshot, the baked
;; name goes stale.  `decknix--sidebar-previous-display-name' re-derives
;; the row label from the *current* tag store (keyed by conv-key) so the
;; sidebar matches the Saved-Sessions section.  Both impure collaborators
;; (`decknix--agent-tags-for-conv-key' tag-store read,
;; `decknix--agent-session-derive-name' name builder) are stubbed via
;; `cl-letf'; the derive-name stub mirrors the real contract (tags joined
;; by "/").

(defmacro decknix-sidebar-previous-test--with-store (alist &rest body)
  "Run BODY with the tag store stubbed from ALIST (conv-key -> tags).
Also stubs `decknix--agent-session-derive-name' to join tags by \"/\"."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'decknix--agent-tags-for-conv-key)
              (lambda (ck) (cdr (assoc ck ,alist))))
             ((symbol-function 'decknix--agent-session-derive-name)
              (lambda (tags &rest _) (string-join tags "/"))))
     ,@body))

(ert-deftest decknix-sidebar-previous-display-name--store-overrides-baked ()
  "Current store tags win over the entry's baked `name'."
  (decknix-sidebar-previous-test--with-store
      '(("ck-a" . ("nurturecloud" "ARC" "retro")))
    (let ((entry (decknix-sidebar-previous-test--entry
                  "s1" "ck-a" "*Auggie: Auggie Agent @ nurturecloud*")))
      (should (equal (decknix--sidebar-previous-display-name entry)
                     "nurturecloud/ARC/retro")))))

(ert-deftest decknix-sidebar-previous-display-name--falls-back-to-entry-tags ()
  "When the store has no tags, the entry's baked `tags' are used."
  (decknix-sidebar-previous-test--with-store '()
    (let ((entry (list (cons 'session-id "s1")
                       (cons 'name "*Auggie: stale*")
                       (cons 'conv-key "ck-a")
                       (cons 'tags '("decknix" "ai")))))
      (should (equal (decknix--sidebar-previous-display-name entry)
                     "decknix/ai")))))

(ert-deftest decknix-sidebar-previous-display-name--strips-auggie-wrapper ()
  "With no tags anywhere, the baked `name' is returned sans wrapper."
  (decknix-sidebar-previous-test--with-store '()
    (let ((entry (decknix-sidebar-previous-test--entry
                  "s1" "ck-a" "*Auggie: feature/foo*")))
      (should (equal (decknix--sidebar-previous-display-name entry)
                     "feature/foo")))))

(ert-deftest decknix-sidebar-previous-display-name--plain-name-passthrough ()
  "A `name' without the wrapper passes through unchanged."
  (decknix-sidebar-previous-test--with-store '()
    (let ((entry (decknix-sidebar-previous-test--entry "s1" "ck-a" "plain")))
      (should (equal (decknix--sidebar-previous-display-name entry)
                     "plain")))))

(ert-deftest decknix-sidebar-previous-display-name--unknown-when-empty ()
  "No conv-key, tags, or name yields \"unknown\"."
  (decknix-sidebar-previous-test--with-store '()
    (let ((entry (list (cons 'session-id "s1")
                       (cons 'name nil)
                       (cons 'conv-key nil)
                       (cons 'tags nil))))
      (should (equal (decknix--sidebar-previous-display-name entry)
                     "unknown")))))

(ert-deftest decknix-sidebar-previous-display-name--nil-conv-key-skips-store ()
  "A nil conv-key never hits the store; entry tags drive the name."
  (decknix-sidebar-previous-test--with-store
      '((nil . ("should" "not" "be" "used")))
    (let ((entry (list (cons 'session-id "s1")
                       (cons 'name "*Auggie: x*")
                       (cons 'conv-key nil)
                       (cons 'tags '("only" "these")))))
      (should (equal (decknix--sidebar-previous-display-name entry)
                     "only/these")))))

(provide 'decknix-sidebar-previous-test)
;;; decknix-sidebar-previous-test.el ends here
