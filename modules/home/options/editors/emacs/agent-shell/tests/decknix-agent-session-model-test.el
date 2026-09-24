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

;; -- bulk re-pinning ------------------------------------------------
;;
;; A saved model is re-applied on every resume for as long as the session
;; advertises it, so a conversation started on an older model stays there
;; for life.  Moving a backlog forward meant resuming each one and
;; pressing `C-c C-v': 183 of 573 conversations were pinned to
;; `claude-opus-4-8' when this landed.

(defun decknix-model-test--convs (&rest pairs)
  "Build a conversations table from PAIRS of (CONV-KEY . MODEL)."
  (let ((convs (make-hash-table :test 'equal)))
    (dolist (pair pairs)
      (let ((entry (make-hash-table :test 'equal)))
        (puthash "tags" nil entry)
        (puthash "sessions" nil entry)
        (when (cdr pair) (puthash "model" (cdr pair) entry))
        (puthash (car pair) entry convs)))
    convs))

(ert-deftest decknix-model-migrate--selects-only-the-from-model ()
  "Exactly the conversations pinned to FROM are planned."
  (let ((convs (decknix-model-test--convs
                '("a" . "claude-opus-4-8")
                '("b" . "claude-sonnet-5")
                '("c" . "claude-opus-4-8"))))
    (should (equal '("a" "c")
                   (decknix--agent-model-migration-plan
                    convs "claude-opus-4-8" "claude-opus-5-5")))))

(ert-deftest decknix-model-migrate--leaves-unpinned-conversations-alone ()
  "An unpinned conversation already follows the provider default.

Re-pinning it would REMOVE that freedom -- it would stop moving with the
default it is currently tracking -- so absence of a pin is never treated
as a pin to migrate.  349 of 573 conversations were in this state."
  (let ((convs (decknix-model-test--convs
                '("a" . nil)
                '("b" . "claude-opus-4-8"))))
    (should (equal '("b")
                   (decknix--agent-model-migration-plan
                    convs "claude-opus-4-8" "claude-opus-5-5")))))

(ert-deftest decknix-model-migrate--plan-is-sorted ()
  "A dry run and the write that follows must agree on order."
  (let ((convs (decknix-model-test--convs
                '("zz" . "m") '("aa" . "m") '("mm" . "m"))))
    (should (equal '("aa" "mm" "zz")
                   (decknix--agent-model-migration-plan convs "m" "n")))))

(ert-deftest decknix-model-migrate--degenerate-input-plans-nothing ()
  "A no-op request must not rewrite the store.
FROM equal to TO is the dangerous one: it would rewrite every matching
entry to the value it already holds, rotating the single backup slot and
discarding the pre-change state for no gain."
  (let ((convs (decknix-model-test--convs '("a" . "m"))))
    (should-not (decknix--agent-model-migration-plan convs "m" "m"))
    (should-not (decknix--agent-model-migration-plan convs "" "n"))
    (should-not (decknix--agent-model-migration-plan convs "m" ""))
    (should-not (decknix--agent-model-migration-plan convs nil "n"))
    (should-not (decknix--agent-model-migration-plan convs "m" nil))
    (should-not (decknix--agent-model-migration-plan nil "m" "n"))))

(ert-deftest decknix-model-migrate--no-match-plans-nothing ()
  "A model absent from the store yields an empty plan, not an error."
  (let ((convs (decknix-model-test--convs '("a" . "other"))))
    (should-not (decknix--agent-model-migration-plan
                 convs "claude-opus-4-8" "claude-opus-5-5"))))

(ert-deftest decknix-models-in-store--counts-and-ranks ()
  "Candidates come from the store, most-used first."
  (let ((convs (decknix-model-test--convs
                '("a" . "opus") '("b" . "sonnet") '("c" . "opus")
                '("d" . nil) '("e" . "opus"))))
    (should (equal '(("opus" . 3) ("sonnet" . 1))
                   (decknix--agent-models-in-store convs)))))

(ert-deftest decknix-models-in-store--ignores-blank-and-missing ()
  "An empty-string pin is not a model."
  (let ((convs (decknix-model-test--convs '("a" . "") '("b" . nil))))
    (should-not (decknix--agent-models-in-store convs))
    (should-not (decknix--agent-models-in-store nil))))


(provide 'decknix-agent-session-model-test)
;;; decknix-agent-session-model-test.el ends here
