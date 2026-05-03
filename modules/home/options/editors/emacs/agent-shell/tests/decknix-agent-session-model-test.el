;;; decknix-agent-session-model-test.el --- Tests for per-conversation model store -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-session-model "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the per-conversation auggie
;; model override store.  The two accessors round-trip through
;; the same `~/.config/decknix/agent-sessions.json' that backs
;; tags / linked PRs / saved workspaces, so the tests stub
;; `decknix--agent-tags-read' and `-write' against an in-memory
;; hash so they can run hermetically in batch Emacs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-session-model)

;; -- Test fixtures -----------------------------------------------

(defvar decknix-test-session-model--store nil
  "In-memory stand-in for the agent-sessions.json store.")

(defun decknix-test-session-model--fresh-store ()
  "Build an empty store hash matching the on-disk shape."
  (let ((root (make-hash-table :test 'equal))
        (convs (make-hash-table :test 'equal)))
    (puthash "conversations" convs root)
    root))

(defmacro decknix-test-session-model-with-store (&rest body)
  "Run BODY with an isolated in-memory store stubbing tags read/write."
  (declare (indent 0))
  `(let ((decknix-test-session-model--store
          (decknix-test-session-model--fresh-store)))
     (cl-letf (((symbol-function 'decknix--agent-tags-read)
                (lambda () decknix-test-session-model--store))
               ((symbol-function 'decknix--agent-tags-write)
                (lambda (store)
                  (setq decknix-test-session-model--store store)))
               ((symbol-function 'decknix--agent-tags-conversations)
                (lambda (store) (gethash "conversations" store))))
       ,@body)))

;; -- Read accessor -----------------------------------------------

(ert-deftest decknix-agent-session-model--read-nil-conv-key ()
  "Reader returns nil when CONV-KEY is nil."
  (decknix-test-session-model-with-store
    (should (null (decknix--agent-session-model-for-conv-key nil)))))

(ert-deftest decknix-agent-session-model--read-missing-conv-returns-nil ()
  "Reader returns nil when CONV-KEY has no entry in the store."
  (decknix-test-session-model-with-store
    (should (null (decknix--agent-session-model-for-conv-key "missing")))))

(ert-deftest decknix-agent-session-model--read-entry-without-model-returns-nil ()
  "Reader returns nil when the entry exists but has no `model' field."
  (decknix-test-session-model-with-store
    (let ((entry (make-hash-table :test 'equal)))
      (puthash "tags" '("foo") entry)
      (puthash "ck" entry
               (decknix--agent-tags-conversations
                (decknix--agent-tags-read))))
    (should (null (decknix--agent-session-model-for-conv-key "ck")))))

(ert-deftest decknix-agent-session-model--read-returns-stored-model ()
  "Reader returns the stored model-id."
  (decknix-test-session-model-with-store
    (let ((entry (make-hash-table :test 'equal)))
      (puthash "model" "claude-sonnet-4.5" entry)
      (puthash "ck" entry
               (decknix--agent-tags-conversations
                (decknix--agent-tags-read))))
    (should (equal "claude-sonnet-4.5"
                   (decknix--agent-session-model-for-conv-key "ck")))))

;; -- Save accessor -----------------------------------------------

(ert-deftest decknix-agent-session-model--save-nil-conv-key-noop ()
  "Saver is a no-op when CONV-KEY is nil."
  (decknix-test-session-model-with-store
    (decknix--agent-session-save-model-for-conv-key nil "claude")
    (should (zerop (hash-table-count
                    (decknix--agent-tags-conversations
                     (decknix--agent-tags-read)))))))

(ert-deftest decknix-agent-session-model--save-nil-model-noop ()
  "Saver is a no-op when MODEL-ID is nil."
  (decknix-test-session-model-with-store
    (decknix--agent-session-save-model-for-conv-key "ck" nil)
    (should (zerop (hash-table-count
                    (decknix--agent-tags-conversations
                     (decknix--agent-tags-read)))))))

(ert-deftest decknix-agent-session-model--save-creates-new-entry ()
  "Saver creates a fresh entry with empty tags + sessions when none exists."
  (decknix-test-session-model-with-store
    (decknix--agent-session-save-model-for-conv-key "ck" "claude")
    (let* ((convs (decknix--agent-tags-conversations
                   (decknix--agent-tags-read)))
           (entry (gethash "ck" convs)))
      (should (hash-table-p entry))
      (should (equal "claude" (gethash "model" entry)))
      ;; Default scaffolding for unrelated fields.
      (should (null (gethash "tags" entry)))
      (should (null (gethash "sessions" entry))))))

(ert-deftest decknix-agent-session-model--save-preserves-existing-entry ()
  "Saver preserves existing tags / sessions when updating model."
  (decknix-test-session-model-with-store
    (let ((entry (make-hash-table :test 'equal)))
      (puthash "tags" '("review") entry)
      (puthash "sessions" '("s1" "s2") entry)
      (puthash "ck" entry
               (decknix--agent-tags-conversations
                (decknix--agent-tags-read))))
    (decknix--agent-session-save-model-for-conv-key "ck" "gpt-5")
    (let* ((convs (decknix--agent-tags-conversations
                   (decknix--agent-tags-read)))
           (entry (gethash "ck" convs)))
      (should (equal '("review") (gethash "tags" entry)))
      (should (equal '("s1" "s2") (gethash "sessions" entry)))
      (should (equal "gpt-5" (gethash "model" entry))))))

(ert-deftest decknix-agent-session-model--save-overwrites-existing-model ()
  "Saver overwrites a prior model-id."
  (decknix-test-session-model-with-store
    (decknix--agent-session-save-model-for-conv-key "ck" "old")
    (decknix--agent-session-save-model-for-conv-key "ck" "new")
    (should (equal "new"
                   (decknix--agent-session-model-for-conv-key "ck")))))

(ert-deftest decknix-agent-session-model--round-trip ()
  "Save then read returns the stored model-id."
  (decknix-test-session-model-with-store
    (decknix--agent-session-save-model-for-conv-key "ck" "claude-3.7")
    (should (equal "claude-3.7"
                   (decknix--agent-session-model-for-conv-key "ck")))))

(provide 'decknix-agent-session-model-test)
;;; decknix-agent-session-model-test.el ends here
