;;; decknix-agent-tags-read-test.el --- Tests for tags read accessors -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-tags-read "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the two tags read accessors.
;; The tests stub `decknix--agent-tags-read' /
;; `-tags-conversations' against an in-memory hash; the
;; session-id variant additionally stubs
;; `decknix--agent-conversation-key-for-session' so the resolve
;; step is decoupled from the session-cache layer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-tags-read)

;; -- Test fixtures -----------------------------------------------

(defvar decknix-test-tags-read--store nil
  "In-memory stand-in for the agent-sessions.json store.")

(defvar decknix-test-tags-read--session-to-conv nil
  "Alist mapping session-id -> conv-key for the resolver stub.")

(defun decknix-test-tags-read--fresh-store ()
  "Build an empty store hash matching the on-disk shape."
  (let ((root (make-hash-table :test 'equal))
        (convs (make-hash-table :test 'equal)))
    (puthash "conversations" convs root)
    root))

(defmacro decknix-test-tags-read-with-store (&rest body)
  "Run BODY with an isolated in-memory store stubbing accessors + resolver."
  (declare (indent 0))
  `(let ((decknix-test-tags-read--store
          (decknix-test-tags-read--fresh-store))
         (decknix-test-tags-read--session-to-conv nil))
     (cl-letf (((symbol-function 'decknix--agent-tags-read)
                (lambda () decknix-test-tags-read--store))
               ((symbol-function 'decknix--agent-tags-conversations)
                (lambda (store) (gethash "conversations" store)))
               ((symbol-function 'decknix--agent-conversation-key-for-session)
                (lambda (sid &optional _no-block)
                  (cdr (assoc sid decknix-test-tags-read--session-to-conv)))))
       ,@body)))

(defun decknix-test-tags-read--seed (conv-key &rest plist)
  "Insert an entry for CONV-KEY built from PLIST (k1 v1 k2 v2 ...)."
  (let ((entry (make-hash-table :test 'equal)))
    (cl-loop for (k v) on plist by #'cddr do
             (puthash k v entry))
    (puthash conv-key entry
             (decknix--agent-tags-conversations
              (decknix--agent-tags-read)))))

;; -- tags-for-conv-key (direct) ----------------------------------

(ert-deftest decknix-agent-tags-read--ck-missing-returns-nil ()
  "Direct reader returns nil when CONV-KEY has no entry."
  (decknix-test-tags-read-with-store
    (should (null (decknix--agent-tags-for-conv-key "missing")))))

(ert-deftest decknix-agent-tags-read--ck-entry-without-tags-returns-nil ()
  "Direct reader returns nil when entry exists but has no `tags' field."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "ck" "workspace" "/p")
    (should (null (decknix--agent-tags-for-conv-key "ck")))))

(ert-deftest decknix-agent-tags-read--ck-non-hash-entry-returns-nil ()
  "Direct reader returns nil when the entry is not a hash-table.
Defensive guard for legacy / corrupt entries."
  (decknix-test-tags-read-with-store
    (puthash "ck" '(:not-a-hash)
             (decknix--agent-tags-conversations
              (decknix--agent-tags-read)))
    (should (null (decknix--agent-tags-for-conv-key "ck")))))

(ert-deftest decknix-agent-tags-read--ck-returns-stored-tags ()
  "Direct reader returns the stored tags list verbatim."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "ck" "tags" '("review" "backend"))
    (should (equal '("review" "backend")
                   (decknix--agent-tags-for-conv-key "ck")))))

;; -- tags-for-session (resolved) ---------------------------------

(ert-deftest decknix-agent-tags-read--sid-unresolved-returns-nil ()
  "Session reader returns nil when resolver returns nil."
  (decknix-test-tags-read-with-store
    (should (null (decknix--agent-tags-for-session "unknown-sid")))))

(ert-deftest decknix-agent-tags-read--sid-resolved-no-entry-returns-nil ()
  "Session reader returns nil when conv-key resolves but no entry exists."
  (decknix-test-tags-read-with-store
    (push '("sid-1" . "ck-1") decknix-test-tags-read--session-to-conv)
    (should (null (decknix--agent-tags-for-session "sid-1")))))

(ert-deftest decknix-agent-tags-read--sid-resolved-no-tags-returns-nil ()
  "Session reader returns nil when entry exists but has no `tags' field."
  (decknix-test-tags-read-with-store
    (push '("sid-1" . "ck-1") decknix-test-tags-read--session-to-conv)
    (decknix-test-tags-read--seed "ck-1" "workspace" "/p")
    (should (null (decknix--agent-tags-for-session "sid-1")))))

(ert-deftest decknix-agent-tags-read--sid-returns-stored-tags ()
  "Session reader returns tags via resolver -> entry lookup."
  (decknix-test-tags-read-with-store
    (push '("sid-1" . "ck-1") decknix-test-tags-read--session-to-conv)
    (decknix-test-tags-read--seed "ck-1" "tags" '("frontend"))
    (should (equal '("frontend")
                   (decknix--agent-tags-for-session "sid-1")))))

;; -- tags-all (aggregation) --------------------------------------

(ert-deftest decknix-agent-tags-read--all-empty-store ()
  "Aggregate returns nil when no conversations exist."
  (decknix-test-tags-read-with-store
    (should (null (decknix--agent-tags-all)))))

(ert-deftest decknix-agent-tags-read--all-no-tags ()
  "Aggregate returns nil when conversations exist but none carry tags."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "ck-1" "workspace" "/p")
    (decknix-test-tags-read--seed "ck-2" "workspace" "/q")
    (should (null (decknix--agent-tags-all)))))

(ert-deftest decknix-agent-tags-read--all-deduplicates ()
  "Aggregate dedupes tags shared across conversations."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "ck-1" "tags" '("review" "backend"))
    (decknix-test-tags-read--seed "ck-2" "tags" '("backend" "infra"))
    (should (equal '("backend" "infra" "review")
                   (decknix--agent-tags-all)))))

(ert-deftest decknix-agent-tags-read--all-sorts-string-lt ()
  "Aggregate returns tags sorted by `string<'."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "ck-1" "tags" '("zeta" "alpha" "mu"))
    (should (equal '("alpha" "mu" "zeta")
                   (decknix--agent-tags-all)))))

(ert-deftest decknix-agent-tags-read--all-skips-non-hash-entries ()
  "Aggregate is defensive against legacy / corrupt non-hash entries."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "ck-1" "tags" '("real"))
    (puthash "ck-2" '(:not-a-hash)
             (decknix--agent-tags-conversations
              (decknix--agent-tags-read)))
    (should (equal '("real") (decknix--agent-tags-all)))))

(provide 'decknix-agent-tags-read-test)
;;; decknix-agent-tags-read-test.el ends here
