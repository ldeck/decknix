;;; decknix-agent-session-mode-test.el --- Tests for per-conversation mode store -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-session-mode "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the per-conversation session/permission
;; mode override store.  The two accessors round-trip through the same
;; `~/.config/decknix/agent-sessions.json' that backs tags / linked PRs /
;; saved workspaces / model overrides, so the tests stub
;; `decknix--agent-tags-read' and `-write' against an in-memory hash so
;; they can run hermetically in batch Emacs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-session-mode)

;; -- Test fixtures -----------------------------------------------

(defvar decknix-test-session-mode--store nil
  "In-memory stand-in for the agent-sessions.json store.")

(defun decknix-test-session-mode--fresh-store ()
  "Build an empty store hash matching the on-disk shape."
  (let ((root (make-hash-table :test 'equal))
        (convs (make-hash-table :test 'equal)))
    (puthash "conversations" convs root)
    root))

(defmacro decknix-test-session-mode-with-store (&rest body)
  "Run BODY with an isolated in-memory store stubbing tags read/write."
  (declare (indent 0))
  `(let ((decknix-test-session-mode--store
          (decknix-test-session-mode--fresh-store)))
     (cl-letf (((symbol-function 'decknix--agent-tags-read)
                (lambda () decknix-test-session-mode--store))
               ((symbol-function 'decknix--agent-tags-write)
                (lambda (store)
                  (setq decknix-test-session-mode--store store)))
               ((symbol-function 'decknix--agent-tags-conversations)
                (lambda (store) (gethash "conversations" store))))
       ,@body)))

;; -- Read accessor -----------------------------------------------

(ert-deftest decknix-agent-session-mode--read-nil-conv-key ()
  "Reader returns nil when CONV-KEY is nil."
  (decknix-test-session-mode-with-store
    (should (null (decknix--agent-session-mode-for-conv-key nil)))))

(ert-deftest decknix-agent-session-mode--read-missing-conv-returns-nil ()
  "Reader returns nil when CONV-KEY has no entry in the store."
  (decknix-test-session-mode-with-store
    (should (null (decknix--agent-session-mode-for-conv-key "missing")))))

(ert-deftest decknix-agent-session-mode--read-entry-without-mode-returns-nil ()
  "Reader returns nil when the entry exists but has no `mode' field."
  (decknix-test-session-mode-with-store
    (let ((entry (make-hash-table :test 'equal)))
      (puthash "tags" '("foo") entry)
      (puthash "ck" entry
               (decknix--agent-tags-conversations
                (decknix--agent-tags-read))))
    (should (null (decknix--agent-session-mode-for-conv-key "ck")))))

(ert-deftest decknix-agent-session-mode--read-returns-stored-mode ()
  "Reader returns the stored mode-id."
  (decknix-test-session-mode-with-store
    (let ((entry (make-hash-table :test 'equal)))
      (puthash "mode" "auto" entry)
      (puthash "ck" entry
               (decknix--agent-tags-conversations
                (decknix--agent-tags-read))))
    (should (equal "auto"
                   (decknix--agent-session-mode-for-conv-key "ck")))))

;; -- Save accessor -----------------------------------------------

(ert-deftest decknix-agent-session-mode--save-nil-conv-key-noop ()
  "Saver is a no-op when CONV-KEY is nil."
  (decknix-test-session-mode-with-store
    (decknix--agent-session-save-mode-for-conv-key nil "auto")
    (should (zerop (hash-table-count
                    (decknix--agent-tags-conversations
                     (decknix--agent-tags-read)))))))

(ert-deftest decknix-agent-session-mode--save-nil-mode-noop ()
  "Saver is a no-op when MODE-ID is nil."
  (decknix-test-session-mode-with-store
    (decknix--agent-session-save-mode-for-conv-key "ck" nil)
    (should (zerop (hash-table-count
                    (decknix--agent-tags-conversations
                     (decknix--agent-tags-read)))))))

(ert-deftest decknix-agent-session-mode--save-creates-new-entry ()
  "Saver creates a fresh entry with empty tags + sessions when none exists."
  (decknix-test-session-mode-with-store
    (decknix--agent-session-save-mode-for-conv-key "ck" "auto")
    (let* ((convs (decknix--agent-tags-conversations
                   (decknix--agent-tags-read)))
           (entry (gethash "ck" convs)))
      (should (hash-table-p entry))
      (should (equal "auto" (gethash "mode" entry)))
      ;; Default scaffolding for unrelated fields.
      (should (null (gethash "tags" entry)))
      (should (null (gethash "sessions" entry))))))

(ert-deftest decknix-agent-session-mode--save-preserves-existing-entry ()
  "Saver preserves existing tags / sessions when updating mode."
  (decknix-test-session-mode-with-store
    (let ((entry (make-hash-table :test 'equal)))
      (puthash "tags" '("review") entry)
      (puthash "sessions" '("s1" "s2") entry)
      (puthash "ck" entry
               (decknix--agent-tags-conversations
                (decknix--agent-tags-read))))
    (decknix--agent-session-save-mode-for-conv-key "ck" "plan")
    (let* ((convs (decknix--agent-tags-conversations
                   (decknix--agent-tags-read)))
           (entry (gethash "ck" convs)))
      (should (equal '("review") (gethash "tags" entry)))
      (should (equal '("s1" "s2") (gethash "sessions" entry)))
      (should (equal "plan" (gethash "mode" entry))))))

(ert-deftest decknix-agent-session-mode--save-overwrites-existing-mode ()
  "Saver overwrites a prior mode-id."
  (decknix-test-session-mode-with-store
    (decknix--agent-session-save-mode-for-conv-key "ck" "default")
    (decknix--agent-session-save-mode-for-conv-key "ck" "auto")
    (should (equal "auto"
                   (decknix--agent-session-mode-for-conv-key "ck")))))

(ert-deftest decknix-agent-session-mode--round-trip ()
  "Save then read returns the stored mode-id."
  (decknix-test-session-mode-with-store
    (decknix--agent-session-save-mode-for-conv-key "ck" "acceptEdits")
    (should (equal "acceptEdits"
                   (decknix--agent-session-mode-for-conv-key "ck")))))

(provide 'decknix-agent-session-mode-test)
;;; decknix-agent-session-mode-test.el ends here
