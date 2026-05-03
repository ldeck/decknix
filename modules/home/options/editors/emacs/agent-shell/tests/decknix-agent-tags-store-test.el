;;; decknix-agent-tags-store-test.el --- Tests for tag store persistence -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-tags-store "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the tag store storage layer
;; extracted from the main heredoc.  Covers the cache-state defaults,
;; round-tripping a v2 store through write+read, the lazy
;; `conversations' accessor, the fast-path TTL gate that skips the
;; mtime + migration walk, and the v1 -> v2 auto-migration.
;;
;; Stubs `decknix--agent-session-list' and
;; `decknix--agent-conversation-key' (both forward-declared by the
;; module) so the migration walk has predictable input without
;; needing an `~/.augment/sessions/' tree.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)

;; Stub the heredoc-resident callbacks invoked by the migration walk
;; in `decknix--agent-tags-read'.  Tests rebind them where a specific
;; return value is needed.
(unless (fboundp 'decknix--agent-session-list)
  (defun decknix--agent-session-list () nil))
(unless (fboundp 'decknix--agent-conversation-key)
  (defun decknix--agent-conversation-key (_first-message) nil))

(require 'decknix-agent-tags-store)

(defmacro decknix-agent-tags-store-test--with-isolated-store (&rest body)
  "Evaluate BODY with the tag file + cache state shadowed.
Per-test mktemp dir so the user's
~/.config/decknix/agent-sessions.json is never touched.  All four
cache state vars are reset so a previous test's hash never bleeds
into the current one."
  (declare (indent 0))
  `(let* ((tmp-dir (file-name-as-directory
                    (make-temp-file "agent-tags-store-" t)))
          (decknix--agent-tags-file
           (expand-file-name "agent-sessions.json" tmp-dir))
          (decknix--agent-tags-cache nil)
          (decknix--agent-tags-cache-mtime nil)
          (decknix--agent-tags-cache-checked-at 0.0))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p tmp-dir)
         (delete-directory tmp-dir t)))))

;; -- defaults ------------------------------------------------------

(ert-deftest decknix-agent-tags-store--defaults ()
  "File path + TTL constant match the documented contract."
  (should (string-match-p "/decknix/agent-sessions\\.json\\'"
                          decknix--agent-tags-file))
  (should (= decknix--agent-tags-cache-ttl 1.0)))

;; -- write creates parent dir + writes JSON ------------------------

(ert-deftest decknix-agent-tags-store--write-creates-parent-dir ()
  "Write creates the tag-file's parent directory if it doesn't exist."
  (decknix-agent-tags-store-test--with-isolated-store
    (let ((decknix--agent-tags-file
           (expand-file-name "deep/nested/agent-sessions.json"
                             (file-name-directory
                              decknix--agent-tags-file))))
      (should-not (file-directory-p (file-name-directory
                                     decknix--agent-tags-file)))
      (decknix--agent-tags-write (make-hash-table :test 'equal))
      (should (file-directory-p (file-name-directory
                                 decknix--agent-tags-file)))
      (should (file-exists-p decknix--agent-tags-file)))))

(ert-deftest decknix-agent-tags-store--write-emits-json ()
  "Write encodes the store as JSON parseable by `json-read-file'."
  (decknix-agent-tags-store-test--with-isolated-store
    (let ((store (make-hash-table :test 'equal)))
      (puthash "bookmarks" (make-hash-table :test 'equal) store)
      (decknix--agent-tags-write store)
      (let* ((json-object-type 'hash-table)
             (json-key-type 'string)
             (parsed (json-read-file decknix--agent-tags-file)))
        (should (hash-table-p parsed))
        (should (hash-table-p (gethash "bookmarks" parsed)))))))

;; -- conversations accessor ---------------------------------------

(ert-deftest decknix-agent-tags-store--conversations-lazy-seed ()
  "`conversations' accessor seeds an empty hash on a fresh store."
  (let ((store (make-hash-table :test 'equal)))
    (let ((convs (decknix--agent-tags-conversations store)))
      (should (hash-table-p convs))
      ;; Subsequent calls return the same hash so callers can mutate
      ;; it in place.
      (should (eq convs
                  (decknix--agent-tags-conversations store))))))

(ert-deftest decknix-agent-tags-store--conversations-existing ()
  "`conversations' accessor returns the existing hash unchanged."
  (let* ((store (make-hash-table :test 'equal))
         (convs (make-hash-table :test 'equal)))
    (puthash "abc" "marker" convs)
    (puthash "conversations" convs store)
    (let ((got (decknix--agent-tags-conversations store)))
      (should (eq got convs))
      (should (equal "marker" (gethash "abc" got))))))

;; -- read fast path ------------------------------------------------

(ert-deftest decknix-agent-tags-store--read-ttl-fast-path ()
  "Within the TTL window, `read' returns the cached hash directly."
  (decknix-agent-tags-store-test--with-isolated-store
    (let ((sentinel (make-hash-table :test 'equal)))
      (puthash "marker" t sentinel)
      (setq decknix--agent-tags-cache sentinel
            decknix--agent-tags-cache-checked-at (float-time))
      ;; Even with the file missing, the TTL fast path must short-
      ;; circuit and return the cached hash.
      (should-not (file-exists-p decknix--agent-tags-file))
      (should (eq sentinel (decknix--agent-tags-read))))))

;; -- read missing file -> empty hash + cached ---------------------

(ert-deftest decknix-agent-tags-store--read-missing-file ()
  "Reading with no file present returns an empty hash + caches it."
  (decknix-agent-tags-store-test--with-isolated-store
    (let ((store (decknix--agent-tags-read)))
      (should (hash-table-p store))
      (should (= (hash-table-count store) 0))
      ;; A second call returns the same cached hash without falling
      ;; back to the disk path again.
      (should (eq store (decknix--agent-tags-read))))))

;; -- write + read round-trip --------------------------------------

(ert-deftest decknix-agent-tags-store--write-then-read-roundtrip ()
  "A v2 store survives write + read with cache invalidated mid-flight."
  (decknix-agent-tags-store-test--with-isolated-store
    (let ((store (make-hash-table :test 'equal))
          (convs (make-hash-table :test 'equal))
          (entry (make-hash-table :test 'equal)))
      (puthash "tags" '("review" "urgent") entry)
      (puthash "workspace" "/tmp/ws" entry)
      (puthash "conv-1" entry convs)
      (puthash "conversations" convs store)
      (decknix--agent-tags-write store)
      ;; Force a real disk read by invalidating both the cache and
      ;; the TTL gate (the write updated the cache + mtime in place).
      (setq decknix--agent-tags-cache nil
            decknix--agent-tags-cache-mtime nil
            decknix--agent-tags-cache-checked-at 0.0)
      (let* ((read-store (decknix--agent-tags-read))
             (read-convs (decknix--agent-tags-conversations read-store))
             (read-entry (gethash "conv-1" read-convs)))
        (should (hash-table-p read-entry))
        (should (equal '("review" "urgent")
                       (gethash "tags" read-entry)))
        (should (equal "/tmp/ws"
                       (gethash "workspace" read-entry)))))))

;; -- v1 -> v2 auto-migration --------------------------------------

(ert-deftest decknix-agent-tags-store--read-migrates-v1-entries ()
  "Orphan v1 (session-keyed) entries are folded into a v2 conversation."
  (decknix-agent-tags-store-test--with-isolated-store
    (let* ((store (make-hash-table :test 'equal))
           (v1-entry (make-hash-table :test 'equal)))
      (puthash "tags" '("legacy") v1-entry)
      (puthash "session-id-A" v1-entry store)
      (decknix--agent-tags-write store)
      ;; Force a real read.
      (setq decknix--agent-tags-cache nil
            decknix--agent-tags-cache-mtime nil
            decknix--agent-tags-cache-checked-at 0.0)
      ;; Stub the heredoc callbacks so the migration walk can resolve
      ;; the orphan session-id to a conversation key.
      (cl-letf (((symbol-function 'decknix--agent-session-list)
                 (lambda ()
                   '(((sessionId . "session-id-A")
                      (firstUserMessage . "hi from A")))))
                ((symbol-function 'decknix--agent-conversation-key)
                 (lambda (msg)
                   (and (equal msg "hi from A") "conv-A"))))
        (let* ((read-store (decknix--agent-tags-read))
               (read-convs (decknix--agent-tags-conversations read-store))
               (entry (gethash "conv-A" read-convs)))
          ;; v1 orphan removed
          (should-not (gethash "session-id-A" read-store))
          ;; v2 entry created with the legacy tag
          (should (hash-table-p entry))
          (should (equal '("legacy") (gethash "tags" entry)))
          (should (member "session-id-A"
                          (gethash "sessions" entry))))))))

(provide 'decknix-agent-tags-store-test)
;;; decknix-agent-tags-store-test.el ends here
