;;; decknix-agent-tags-store-test.el --- Tests for tag store persistence -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-tags-store "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the tag store storage layer
;; extracted from the main heredoc.  Covers the cache-state defaults,
;; round-tripping a store through write+read, the lazy `conversations'
;; accessor, the fast-path TTL gate that skips the mtime check, and the
;; canonical conv-key re-keying migration.
;;
;; Stubs `decknix--agent-session-list-if-warm' and
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
(unless (fboundp 'decknix--agent-session-list-if-warm)
  (defun decknix--agent-session-list-if-warm () nil))
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
  "Reading with no file present returns a store with root keys + caches it."
  (decknix-agent-tags-store-test--with-isolated-store
    (let ((store (decknix--agent-tags-read)))
      (should (hash-table-p store))
      ;; Root keys are seeded automatically.
      (should (hash-table-p (gethash "conversations" store)))
      (should (hash-table-p (gethash "bookmarks" store)))
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


;; -- canonical conv-key migration ---------------------------------
;;
;; Pre-canonical writes hashed the unbounded comint input rather than
;; the jq-truncated firstUserMessage prefix.  Long-message entries
;; landed under a key the read side could never resolve.  The
;; migration walks v2 conversations, re-derives the canonical key
;; from each entry's first session, and moves orphans (merging into
;; any pre-existing canonical entry).

(defmacro decknix-agent-tags-store-test--with-canonical-stubs
    (sessions key-fn &rest body)
  "Run BODY with session-list / conversation-key stubbed.
SESSIONS is the list returned by both session-list stubs; KEY-FN is the
function that maps a firstUserMessage string to a conv-key for the
conversation-key stub.  Stubs both `decknix--agent-session-list' and
`decknix--agent-session-list-if-warm' to return SESSIONS."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'decknix--agent-session-list)
              (lambda () ,sessions))
             ((symbol-function 'decknix--agent-session-list-if-warm)
              (lambda () ,sessions))
             ((symbol-function 'decknix--agent-conversation-key)
              ,key-fn))
     ,@body))

(defun decknix-agent-tags-store-test--seed-store (entries)
  "Write a v2 STORE built from ENTRIES into the shadowed tag file.
ENTRIES is an alist of (KEY . PLIST) where PLIST may contain
`:tags', `:sessions', `:workspace'."
  (let ((store (make-hash-table :test 'equal))
        (convs (make-hash-table :test 'equal)))
    (dolist (cell entries)
      (let ((key (car cell))
            (plist (cdr cell))
            (entry (make-hash-table :test 'equal)))
        (when-let ((tags (plist-get plist :tags)))
          (puthash "tags" tags entry))
        (when-let ((sids (plist-get plist :sessions)))
          (puthash "sessions" sids entry))
        (when-let ((ws (plist-get plist :workspace)))
          (puthash "workspace" ws entry))
        (puthash key entry convs)))
    (puthash "conversations" convs store)
    (decknix--agent-tags-write store)
    (setq decknix--agent-tags-cache nil
          decknix--agent-tags-cache-mtime nil
          decknix--agent-tags-cache-checked-at 0.0)))

(ert-deftest decknix-agent-tags-store--canonical-rekey-simple-move ()
  "Orphan entry is moved to its canonical conv-key when the slot is free."
  (decknix-agent-tags-store-test--with-isolated-store
    (decknix-agent-tags-store-test--seed-store
     '(("orphan-key" :tags ("review" "urgent")
                     :sessions ("sid-A")
                     :workspace "/tmp/ws")))
    (decknix-agent-tags-store-test--with-canonical-stubs
        '(((sessionId . "sid-A") (firstUserMessage . "first msg")))
        (lambda (msg)
          (and (equal msg "first msg") "canonical-key"))
      (let* ((store (decknix--agent-tags-read))
             (convs (decknix--agent-tags-conversations store)))
        (should-not (gethash "orphan-key" convs))
        (let ((entry (gethash "canonical-key" convs)))
          (should (hash-table-p entry))
          (should (equal '("review" "urgent") (gethash "tags" entry)))
          (should (equal "/tmp/ws" (gethash "workspace" entry)))
          (should (member "sid-A" (gethash "sessions" entry))))
        (should (= decknix--agent-tags-canonical-key-version
                   (gethash "_canonicalKeyVersion" store)))))))

(ert-deftest decknix-agent-tags-store--canonical-rekey-merges-into-target ()
  "Orphan tags / sessions / workspace fold into a pre-existing canonical entry."
  (decknix-agent-tags-store-test--with-isolated-store
    (decknix-agent-tags-store-test--seed-store
     '(("orphan-key"     :tags ("legacy") :sessions ("sid-old")
                         :workspace "/tmp/old-ws")
       ("canonical-key"  :tags ("kept")   :sessions ("sid-new"))))
    (decknix-agent-tags-store-test--with-canonical-stubs
        '(((sessionId . "sid-old") (firstUserMessage . "old msg"))
          ((sessionId . "sid-new") (firstUserMessage . "new msg")))
        (lambda (msg)
          (cond ((equal msg "old msg") "canonical-key")
                ((equal msg "new msg") "canonical-key")
                (t nil)))
      (let* ((store (decknix--agent-tags-read))
             (convs (decknix--agent-tags-conversations store))
             (target (gethash "canonical-key" convs)))
        (should-not (gethash "orphan-key" convs))
        (should (hash-table-p target))
        (should (equal (sort (copy-sequence (gethash "tags" target))
                             #'string<)
                       '("kept" "legacy")))
        (should (member "sid-old" (gethash "sessions" target)))
        (should (member "sid-new" (gethash "sessions" target)))
        ;; Workspace from the orphan promoted because the target slot
        ;; lacked one.
        (should (equal "/tmp/old-ws" (gethash "workspace" target)))))))

(ert-deftest decknix-agent-tags-store--canonical-rekey-skips-matching ()
  "Entries whose key already matches the canonical hash are untouched."
  (decknix-agent-tags-store-test--with-isolated-store
    (decknix-agent-tags-store-test--seed-store
     '(("good-key" :tags ("ok") :sessions ("sid-A"))))
    (decknix-agent-tags-store-test--with-canonical-stubs
        '(((sessionId . "sid-A") (firstUserMessage . "msg-A")))
        (lambda (msg) (and (equal msg "msg-A") "good-key"))
      (let* ((store (decknix--agent-tags-read))
             (convs (decknix--agent-tags-conversations store))
             (entry (gethash "good-key" convs)))
        (should (hash-table-p entry))
        (should (equal '("ok") (gethash "tags" entry)))))))

(ert-deftest decknix-agent-tags-store--canonical-rekey-no-sessions-defers ()
  "Without a populated session list the migration is a no-op (no flag stamped)."
  (decknix-agent-tags-store-test--with-isolated-store
    (decknix-agent-tags-store-test--seed-store
     '(("orphan-key" :tags ("t") :sessions ("sid-A"))))
    (decknix-agent-tags-store-test--with-canonical-stubs
        nil
        (lambda (_msg) "canonical-key")
      (let* ((store (decknix--agent-tags-read))
             (convs (decknix--agent-tags-conversations store)))
        ;; Entry stays under the old key -- nothing to resolve against.
        (should (hash-table-p (gethash "orphan-key" convs)))
        ;; And the version flag is NOT stamped, so a later read with
        ;; sessions populated will still attempt the migration.
        (should-not (gethash "_canonicalKeyVersion" store))))))

(ert-deftest decknix-agent-tags-store--canonical-rekey-idempotent ()
  "Once stamped, the migration short-circuits on subsequent reads."
  (decknix-agent-tags-store-test--with-isolated-store
    (decknix-agent-tags-store-test--seed-store
     '(("canonical-key" :tags ("t") :sessions ("sid-A"))))
    ;; First pass: stamps the version flag.
    (decknix-agent-tags-store-test--with-canonical-stubs
        '(((sessionId . "sid-A") (firstUserMessage . "msg-A")))
        (lambda (msg) (and (equal msg "msg-A") "canonical-key"))
      (decknix--agent-tags-read))
    ;; Bust the cache so the second read takes the disk path again.
    (setq decknix--agent-tags-cache nil
          decknix--agent-tags-cache-mtime nil
          decknix--agent-tags-cache-checked-at 0.0)
    ;; Second pass: even with a stub that would re-key everything, the
    ;; flag should short-circuit the migration entirely.
    (let ((calls 0))
      (decknix-agent-tags-store-test--with-canonical-stubs
          '(((sessionId . "sid-A") (firstUserMessage . "msg-A")))
          (lambda (msg)
            (setq calls (1+ calls))
            (and (equal msg "msg-A") "canonical-key"))
        (decknix--agent-tags-read)
        ;; Zero invocations of the conv-key fn means the migration walk
        ;; was skipped on the second read.
        (should (= 0 calls))))))


;; -- Hardening: Atomic writes, Backups, Corruption guards -----------

(ert-deftest decknix-agent-tags-store--write-is-atomic-and-backups ()
  "Write uses a temp file, renames it, and creates a .bak file."
  (decknix-agent-tags-store-test--with-isolated-store
    (let ((store (make-hash-table :test 'equal))
          (file decknix--agent-tags-file)
          (bak-file (concat decknix--agent-tags-file ".bak")))
      (puthash "conversations" (make-hash-table :test 'equal) store)
      (puthash "c1" "data" (gethash "conversations" store))

      ;; Initial write
      (decknix--agent-tags-write store)
      (should (file-exists-p file))
      ;; No .bak on the very first write because there was no previous file
      (should-not (file-exists-p bak-file))

      ;; Second write
      (puthash "c2" "more data" (gethash "conversations" store))
      (decknix--agent-tags-write store)
      (should (file-exists-p file))
      (should (file-exists-p bak-file))

      ;; Verify .bak contains the PREVIOUS state (only c1)
      (let* ((json-object-type 'hash-table)
             (json-key-type 'string)
             (parsed (json-read-file bak-file))
             (convs (gethash "conversations" parsed)))
        (should (gethash "c1" convs))
        (should-not (gethash "c2" convs))))))

(ert-deftest decknix-agent-tags-store--write-refuses-empty-clobber ()
  "Refuse to overwrite a non-empty disk file with an empty memory store."
  (decknix-agent-tags-store-test--with-isolated-store
    (let ((store (make-hash-table :test 'equal))
          (file decknix--agent-tags-file))
      (puthash "conversations" (make-hash-table :test 'equal) store)
      (puthash "c1" "data" (gethash "conversations" store))

      ;; 1. Seed the file with data (one conversation ~45 bytes with pretty-print)
      (decknix--agent-tags-write store)
      (should (> (file-attribute-size (file-attributes file)) 30))

      ;; 2. Try to write an EMPTY store
      (let ((empty-store (make-hash-table :test 'equal)))
        (puthash "conversations" (make-hash-table :test 'equal) empty-store)
        (should-error (decknix--agent-tags-write empty-store)
                      :type 'error)
        ;; Verify the file on disk is still the old one (not wiped)
        (let* ((json-object-type 'hash-table)
               (parsed (json-read-file file)))
          (should (gethash "c1" (gethash "conversations" parsed))))))))

(ert-deftest decknix-agent-tags-store--read-handles-corruption-and-restores ()
  "On JSON corruption, move bad file aside and restore from .bak."
  (decknix-agent-tags-store-test--with-isolated-store
    (let ((file decknix--agent-tags-file)
          (bak-file (concat decknix--agent-tags-file ".bak"))
          (store (make-hash-table :test 'equal)))
      ;; 1. Setup a valid backup
      (puthash "conversations" (make-hash-table :test 'equal) store)
      (puthash "c1" "good data" (gethash "conversations" store))
      (decknix--agent-tags-write store)
      ;; Second write to ensure .bak exists
      (decknix--agent-tags-write store)
      (should (file-exists-p bak-file))

      ;; 2. Corrupt the main file
      (with-temp-file file
        (insert "{ invalid json ... "))

      ;; 3. Invalidate cache and read
      (setq decknix--agent-tags-cache nil
            decknix--agent-tags-cache-mtime nil
            decknix--agent-tags-cache-checked-at 0.0)

      (let ((read-store (decknix--agent-tags-read)))
        ;; Should have restored from backup
        (should (gethash "c1" (gethash "conversations" read-store)))
        ;; Should have moved corrupted file to .corrupt-<ts>
        (should (directory-files (file-name-directory file) nil "\\.corrupt-"))))))

(provide 'decknix-agent-tags-store-test)
;;; decknix-agent-tags-store-test.el ends here
