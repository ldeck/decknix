;;; decknix-agent-session-workspace-test.el --- Tests for per-conversation workspace store -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-session-workspace "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the per-conversation workspace
;; persistence layer.  The three accessors round-trip through the
;; same `~/.config/decknix/agent-sessions.json' that backs tags /
;; linked PRs / per-session model overrides, so the tests stub
;; `decknix--agent-tags-read' and `-write' against an in-memory
;; hash so they can run hermetically in batch Emacs.  The
;; session-id-based saver also stubs
;; `decknix--agent-conversation-key-for-session' so the resolve
;; step is decoupled from the session-cache layer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-session-workspace)

;; -- Test fixtures -----------------------------------------------

(defvar decknix-test-session-workspace--store nil
  "In-memory stand-in for the agent-sessions.json store.")

(defvar decknix-test-session-workspace--session-to-conv nil
  "Alist mapping session-id -> conv-key for the resolver stub.")

(defun decknix-test-session-workspace--fresh-store ()
  "Build an empty store hash matching the on-disk shape."
  (let ((root (make-hash-table :test 'equal))
        (convs (make-hash-table :test 'equal)))
    (puthash "conversations" convs root)
    root))

(defmacro decknix-test-session-workspace-with-store (&rest body)
  "Run BODY with an isolated in-memory store stubbing tags + resolver."
  (declare (indent 0))
  `(let ((decknix-test-session-workspace--store
          (decknix-test-session-workspace--fresh-store))
         (decknix-test-session-workspace--session-to-conv nil))
     (cl-letf (((symbol-function 'decknix--agent-tags-read)
                (lambda () decknix-test-session-workspace--store))
               ((symbol-function 'decknix--agent-tags-write)
                (lambda (store)
                  (setq decknix-test-session-workspace--store store)))
               ((symbol-function 'decknix--agent-tags-conversations)
                (lambda (store) (gethash "conversations" store)))
               ((symbol-function 'decknix--agent-conversation-key-for-session)
                (lambda (sid)
                  (cdr (assoc sid decknix-test-session-workspace--session-to-conv)))))
       ,@body)))

;; -- Read accessor -----------------------------------------------

(ert-deftest decknix-agent-session-workspace--read-missing-conv-returns-nil ()
  "Reader returns nil when CONV-KEY has no entry."
  (decknix-test-session-workspace-with-store
    (should (null (decknix--agent-workspace-for-conv-key "missing")))))

(ert-deftest decknix-agent-session-workspace--read-entry-without-workspace-returns-nil ()
  "Reader returns nil when entry exists but has no `workspace' field."
  (decknix-test-session-workspace-with-store
    (let ((entry (make-hash-table :test 'equal)))
      (puthash "tags" '("foo") entry)
      (puthash "ck" entry
               (decknix--agent-tags-conversations
                (decknix--agent-tags-read))))
    (should (null (decknix--agent-workspace-for-conv-key "ck")))))

(ert-deftest decknix-agent-session-workspace--read-returns-stored-workspace ()
  "Reader returns the stored workspace path."
  (decknix-test-session-workspace-with-store
    (let ((entry (make-hash-table :test 'equal)))
      (puthash "workspace" "/home/u/proj" entry)
      (puthash "ck" entry
               (decknix--agent-tags-conversations
                (decknix--agent-tags-read))))
    (should (equal "/home/u/proj"
                   (decknix--agent-workspace-for-conv-key "ck")))))

;; -- save-workspace-for-conv-key ---------------------------------

(ert-deftest decknix-agent-session-workspace--save-by-ck-nil-conv-noop ()
  "Direct saver is a no-op when CONV-KEY is nil."
  (decknix-test-session-workspace-with-store
    (decknix--agent-session-save-workspace-for-conv-key nil "/p")
    (should (zerop (hash-table-count
                    (decknix--agent-tags-conversations
                     (decknix--agent-tags-read)))))))

(ert-deftest decknix-agent-session-workspace--save-by-ck-nil-workspace-noop ()
  "Direct saver is a no-op when WORKSPACE is nil."
  (decknix-test-session-workspace-with-store
    (decknix--agent-session-save-workspace-for-conv-key "ck" nil)
    (should (zerop (hash-table-count
                    (decknix--agent-tags-conversations
                     (decknix--agent-tags-read)))))))

(ert-deftest decknix-agent-session-workspace--save-by-ck-creates-entry ()
  "Direct saver creates a fresh entry with empty tags + sessions."
  (decknix-test-session-workspace-with-store
    (decknix--agent-session-save-workspace-for-conv-key "ck" "/p")
    (let* ((convs (decknix--agent-tags-conversations
                   (decknix--agent-tags-read)))
           (entry (gethash "ck" convs)))
      (should (hash-table-p entry))
      (should (equal "/p" (gethash "workspace" entry)))
      (should (null (gethash "tags" entry)))
      (should (null (gethash "sessions" entry))))))

(ert-deftest decknix-agent-session-workspace--save-by-ck-preserves-existing ()
  "Direct saver preserves existing tags / sessions / model."
  (decknix-test-session-workspace-with-store
    (let ((entry (make-hash-table :test 'equal)))
      (puthash "tags" '("review") entry)
      (puthash "sessions" '("s1") entry)
      (puthash "model" "claude" entry)
      (puthash "ck" entry
               (decknix--agent-tags-conversations
                (decknix--agent-tags-read))))
    (decknix--agent-session-save-workspace-for-conv-key "ck" "/p")
    (let* ((convs (decknix--agent-tags-conversations
                   (decknix--agent-tags-read)))
           (entry (gethash "ck" convs)))
      (should (equal '("review") (gethash "tags" entry)))
      (should (equal '("s1") (gethash "sessions" entry)))
      (should (equal "claude" (gethash "model" entry)))
      (should (equal "/p" (gethash "workspace" entry))))))

(ert-deftest decknix-agent-session-workspace--save-by-ck-round-trip ()
  "Direct save then read returns the stored workspace."
  (decknix-test-session-workspace-with-store
    (decknix--agent-session-save-workspace-for-conv-key "ck" "/x")
    (should (equal "/x" (decknix--agent-workspace-for-conv-key "ck")))))

;; -- save-workspace (session-id resolved) ------------------------

(ert-deftest decknix-agent-session-workspace--save-by-sid-nil-noop ()
  "Session-id saver is a no-op when either arg is nil."
  (decknix-test-session-workspace-with-store
    (decknix--agent-session-save-workspace nil "/p")
    (decknix--agent-session-save-workspace "sid" nil)
    (should (zerop (hash-table-count
                    (decknix--agent-tags-conversations
                     (decknix--agent-tags-read)))))))

(ert-deftest decknix-agent-session-workspace--save-by-sid-unresolved-noop ()
  "Session-id saver is a no-op when resolver returns nil."
  (decknix-test-session-workspace-with-store
    (decknix--agent-session-save-workspace "unknown-sid" "/p")
    (should (zerop (hash-table-count
                    (decknix--agent-tags-conversations
                     (decknix--agent-tags-read)))))))

(ert-deftest decknix-agent-session-workspace--save-by-sid-round-trip ()
  "Session-id saver resolves and persists."
  (decknix-test-session-workspace-with-store
    (push '("sid-1" . "ck-1") decknix-test-session-workspace--session-to-conv)
    (decknix--agent-session-save-workspace "sid-1" "/p1")
    (should (equal "/p1" (decknix--agent-workspace-for-conv-key "ck-1")))))

(provide 'decknix-agent-session-workspace-test)
;;; decknix-agent-session-workspace-test.el ends here
