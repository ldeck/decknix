;;; decknix-agent-conv-recency-test.el --- Tests for conv-recency persistence -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-conv-recency "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the per-conversation
;; lastAccessed stamp pair.  The two accessors round-trip through
;; the same `~/.config/decknix/agent-sessions.json' that backs
;; tags / linked PRs / per-session model overrides / workspace
;; persistence, so the tests stub `decknix--agent-tags-read' /
;; `-write' / `-conversations' against an in-memory hash so they
;; can run hermetically in batch Emacs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-conv-recency)

;; -- Test fixtures -----------------------------------------------

(defvar decknix-test-conv-recency--store nil
  "In-memory stand-in for the agent-sessions.json store.")

(defun decknix-test-conv-recency--fresh-store ()
  "Build an empty store hash matching the on-disk shape."
  (let ((root (make-hash-table :test 'equal))
        (convs (make-hash-table :test 'equal)))
    (puthash "conversations" convs root)
    root))

(defmacro decknix-test-conv-recency-with-store (&rest body)
  "Run BODY with an isolated in-memory store stubbing tags accessors."
  (declare (indent 0))
  `(let ((decknix-test-conv-recency--store
          (decknix-test-conv-recency--fresh-store)))
     (cl-letf (((symbol-function 'decknix--agent-tags-read)
                (lambda () decknix-test-conv-recency--store))
               ((symbol-function 'decknix--agent-tags-write)
                (lambda (store)
                  (setq decknix-test-conv-recency--store store)))
               ((symbol-function 'decknix--agent-tags-conversations)
                (lambda (store) (gethash "conversations" store))))
       ,@body)))

(defun decknix-test-conv-recency--seed (conv-key &rest plist)
  "Insert an entry for CONV-KEY built from PLIST (k1 v1 k2 v2 ...)."
  (let ((entry (make-hash-table :test 'equal)))
    (cl-loop for (k v) on plist by #'cddr do
             (puthash k v entry))
    (puthash conv-key entry
             (decknix--agent-tags-conversations
              (decknix--agent-tags-read)))))

;; -- Reader (-last-accessed) -------------------------------------

(ert-deftest decknix-agent-conv-recency--read-nil-conv-returns-nil ()
  "Reader returns nil when CONV-KEY is nil."
  (decknix-test-conv-recency-with-store
    (should (null (decknix--agent-conv-last-accessed nil)))))

(ert-deftest decknix-agent-conv-recency--read-missing-conv-returns-nil ()
  "Reader returns nil when CONV-KEY has no entry."
  (decknix-test-conv-recency-with-store
    (should (null (decknix--agent-conv-last-accessed "missing")))))

(ert-deftest decknix-agent-conv-recency--read-entry-without-field-returns-nil ()
  "Reader returns nil when entry exists but has no `lastAccessed' field."
  (decknix-test-conv-recency-with-store
    (decknix-test-conv-recency--seed "ck" "tags" '("foo"))
    (should (null (decknix--agent-conv-last-accessed "ck")))))

(ert-deftest decknix-agent-conv-recency--read-returns-stored-stamp ()
  "Reader returns the stored timestamp string."
  (decknix-test-conv-recency-with-store
    (decknix-test-conv-recency--seed "ck"
                                     "lastAccessed"
                                     "2025-01-02T03:04:05.000Z")
    (should (equal "2025-01-02T03:04:05.000Z"
                   (decknix--agent-conv-last-accessed "ck")))))

;; -- Writer (-touch) ---------------------------------------------

(ert-deftest decknix-agent-conv-recency--touch-nil-conv-noop ()
  "Touch is a no-op when CONV-KEY is nil."
  (decknix-test-conv-recency-with-store
    (decknix--agent-conv-touch nil)
    (should (zerop (hash-table-count
                    (decknix--agent-tags-conversations
                     (decknix--agent-tags-read)))))))

(ert-deftest decknix-agent-conv-recency--touch-missing-conv-noop ()
  "Touch is a no-op when CONV-KEY has no entry (no auto-create)."
  (decknix-test-conv-recency-with-store
    (decknix--agent-conv-touch "missing")
    (should (zerop (hash-table-count
                    (decknix--agent-tags-conversations
                     (decknix--agent-tags-read)))))))

(ert-deftest decknix-agent-conv-recency--touch-stamps-existing-entry ()
  "Touch puts an ISO timestamp string on an existing entry."
  (decknix-test-conv-recency-with-store
    (decknix-test-conv-recency--seed "ck" "tags" '("foo"))
    (decknix--agent-conv-touch "ck")
    (let ((stamp (decknix--agent-conv-last-accessed "ck")))
      (should (stringp stamp))
      ;; Roughly: 2025-01-02T03:04:05.000Z (ISO-with-millis-Z).
      (should (string-match-p
               "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\.000Z\\'"
               stamp)))))

(ert-deftest decknix-agent-conv-recency--touch-preserves-existing-fields ()
  "Touch preserves tags / sessions / model / workspace alongside the stamp."
  (decknix-test-conv-recency-with-store
    (decknix-test-conv-recency--seed "ck"
                                     "tags" '("review")
                                     "sessions" '("s1")
                                     "model" "claude"
                                     "workspace" "/p")
    (decknix--agent-conv-touch "ck")
    (let* ((convs (decknix--agent-tags-conversations
                   (decknix--agent-tags-read)))
           (entry (gethash "ck" convs)))
      (should (equal '("review") (gethash "tags" entry)))
      (should (equal '("s1") (gethash "sessions" entry)))
      (should (equal "claude" (gethash "model" entry)))
      (should (equal "/p" (gethash "workspace" entry)))
      (should (stringp (gethash "lastAccessed" entry))))))

(ert-deftest decknix-agent-conv-recency--touch-overwrites-prior-stamp ()
  "Touch overwrites a prior `lastAccessed' value."
  (decknix-test-conv-recency-with-store
    (decknix-test-conv-recency--seed "ck"
                                     "lastAccessed"
                                     "2024-01-01T00:00:00.000Z")
    (decknix--agent-conv-touch "ck")
    (should-not (equal "2024-01-01T00:00:00.000Z"
                       (decknix--agent-conv-last-accessed "ck")))))

(provide 'decknix-agent-conv-recency-test)
;;; decknix-agent-conv-recency-test.el ends here
