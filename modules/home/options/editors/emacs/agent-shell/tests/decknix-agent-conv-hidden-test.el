;;; decknix-agent-conv-hidden-test.el --- Tests for hidden-conv flag -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-conv-hidden "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; Characterisation tests for the `hidden' flag predicate + setter
;; carved from main-bulk in PR B.67.  All tag-store calls are
;; stubbed via `cl-letf' so the suite is hermetic -- no
;; ~/.config/decknix files are read or written.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-conv-hidden)

(defun decknix-conv-hidden-test--make-store (&optional convs)
  "Return a synthetic store hash with optional pre-populated CONVS."
  (let ((store (make-hash-table :test 'equal)))
    (puthash "conversations"
             (or convs (make-hash-table :test 'equal))
             store)
    store))

;; -- predicate ---------------------------------------------------

(ert-deftest decknix-conv-hidden-p--true-when-flag-is-t ()
  "Returns non-nil for a conv-key whose `hidden' is `t'."
  (let* ((convs (make-hash-table :test 'equal))
         (entry (make-hash-table :test 'equal)))
    (puthash "hidden" t entry)
    (puthash "ck" entry convs)
    (cl-letf (((symbol-function 'decknix--agent-tags-read)
               (lambda () 'fake-store))
              ((symbol-function 'decknix--agent-tags-conversations)
               (lambda (_) convs)))
      (should (decknix--agent-conversation-hidden-p "ck")))))

(ert-deftest decknix-conv-hidden-p--nil-when-flag-is-json-false ()
  "Returns nil when the flag exists but is `:json-false' (not `t')."
  (let* ((convs (make-hash-table :test 'equal))
         (entry (make-hash-table :test 'equal)))
    (puthash "hidden" :json-false entry)
    (puthash "ck" entry convs)
    (cl-letf (((symbol-function 'decknix--agent-tags-read)
               (lambda () 'fake-store))
              ((symbol-function 'decknix--agent-tags-conversations)
               (lambda (_) convs)))
      (should (null (decknix--agent-conversation-hidden-p "ck"))))))

(ert-deftest decknix-conv-hidden-p--nil-when-conv-missing ()
  "Returns nil when the conversation key is not in the store."
  (cl-letf (((symbol-function 'decknix--agent-tags-read)
             (lambda () 'fake-store))
            ((symbol-function 'decknix--agent-tags-conversations)
             (lambda (_) (make-hash-table :test 'equal))))
    (should (null (decknix--agent-conversation-hidden-p "missing")))))

(ert-deftest decknix-conv-hidden-p--swallows-errors ()
  "Returns nil when the tag-store accessor raises -- never propagates."
  (cl-letf (((symbol-function 'decknix--agent-tags-read)
             (lambda () (error "Disk read failed"))))
    (should (null (decknix--agent-conversation-hidden-p "any")))))

;; -- setter ------------------------------------------------------

(ert-deftest decknix-conv-hidden-set--writes-t-and-persists ()
  "Setting HIDDEN=t puts `t' on the entry's `hidden' slot and writes."
  (let* ((convs (make-hash-table :test 'equal))
         (store 'fake-store)
         (write-called nil))
    (cl-letf (((symbol-function 'decknix--agent-tags-read)
               (lambda () store))
              ((symbol-function 'decknix--agent-tags-conversations)
               (lambda (_) convs))
              ((symbol-function 'decknix--agent-tags-write)
               (lambda (s)
                 (should (eq s store))
                 (setq write-called t))))
      (decknix--agent-conversation-set-hidden "ck-new" t)
      (should write-called)
      (let ((entry (gethash "ck-new" convs)))
        (should (hash-table-p entry))
        (should (eq (gethash "hidden" entry) t))))))

(ert-deftest decknix-conv-hidden-set--writes-json-false-for-nil ()
  "Setting HIDDEN=nil stores `:json-false' (not nil) so JSON encodes it."
  (let* ((convs (make-hash-table :test 'equal))
         (entry (make-hash-table :test 'equal)))
    (puthash "hidden" t entry)
    (puthash "ck" entry convs)
    (cl-letf (((symbol-function 'decknix--agent-tags-read)
               (lambda () 'fake))
              ((symbol-function 'decknix--agent-tags-conversations)
               (lambda (_) convs))
              ((symbol-function 'decknix--agent-tags-write)
               (lambda (_) nil)))
      (decknix--agent-conversation-set-hidden "ck" nil)
      (should (eq (gethash "hidden" (gethash "ck" convs)) :json-false)))))

(ert-deftest decknix-conv-hidden-set--reuses-existing-entry ()
  "Setting on an existing conv-key preserves sibling slots."
  (let* ((convs (make-hash-table :test 'equal))
         (entry (make-hash-table :test 'equal)))
    (puthash "tags" '("foo" "bar") entry)
    (puthash "ck" entry convs)
    (cl-letf (((symbol-function 'decknix--agent-tags-read)
               (lambda () 'fake))
              ((symbol-function 'decknix--agent-tags-conversations)
               (lambda (_) convs))
              ((symbol-function 'decknix--agent-tags-write)
               (lambda (_) nil)))
      (decknix--agent-conversation-set-hidden "ck" t)
      (let ((updated (gethash "ck" convs)))
        ;; New flag landed.
        (should (eq (gethash "hidden" updated) t))
        ;; Existing slot survived the mutation.
        (should (equal (gethash "tags" updated) '("foo" "bar")))))))

(provide 'decknix-agent-conv-hidden-test)
;;; decknix-agent-conv-hidden-test.el ends here
