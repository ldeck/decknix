;;; decknix-agent-tags-store.el --- Tag-store JSON persistence + cache -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-parse "0.1") (decknix-agent-session-cache "0.1"))
;; Keywords: agent, agent-shell, decknix, tags, persistence

;;; Commentary:
;;
;; The tag store is a JSON file at
;; `~/.config/decknix/agent-sessions.json' keyed by conversation hash
;; (the v2 layout):
;;
;;   {"conversations": {"<conv-key>": {"tags": [...],
;;                                     "sessions": [...],
;;                                     "workspace": "...",
;;                                     "model": "...",
;;                                     "lastAccessed": "..."}}
;;    "bookmarks":     {"<session-id>": {"label": "...", "created": "..."}}}
;;
;; A bookkeeping `_canonicalKeyVersion' integer at the root tracks
;; the canonical conv-key migration (see
;; `decknix--agent-tags-canonical-key-version').
;;
;; This module owns the storage layer:
;;
;;   `decknix--agent-tags-read'           — cached read with v1 -> v2
;;                                            auto-migration plus a
;;                                            second-pass canonical
;;                                            conv-key re-keying for
;;                                            v2 entries written before
;;                                            the jq-truncated hash
;;                                            convention was honoured
;;   `decknix--agent-tags-write'          — write hash to disk +
;;                                            update cache
;;   `decknix--agent-tags-conversations'  — extract / lazily seed
;;                                            the conversations hash
;;
;; Higher-level accessors (per-conv tags, workspace, model, links)
;; stay in `decknix-agent-shell-main' for now — they are pure
;; compositions over this storage layer plus the conversation-key
;; resolver, and pulling them out as well would multiply the surface
;; area without gaining isolation.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)

;; -- Forward declarations ----------------------------------------
;; `decknix--agent-session-list' is defined in the sibling
;; `decknix-agent-session-cache' package; `decknix--agent-conversation-key'
;; lives in the heredoc (`decknix-agent-shell-main') because it threads
;; mergedInto-redirect resolution through this very store.  Both are
;; resolved at call time, not compile time, so a forward declaration
;; is sufficient here.
(declare-function decknix--agent-session-list
                  "decknix-agent-session-cache" ())
(declare-function decknix--agent-conversation-key
                  "ext:decknix-agent-shell-main" (first-message))

(defvar decknix--agent-tags-file
  (expand-file-name "~/.config/decknix/agent-sessions.json")
  "Path to the JSON file storing conversation tag metadata.")

;; In-memory cache for the tag store to avoid repeated json-read-file.
;; Each call to `decknix--agent-tags-read' was doing disk I/O (called
;; 29+ times from various functions).  Now we cache the parsed
;; hash-table and only re-read when the file's mtime changes.
(defvar decknix--agent-tags-cache nil
  "In-memory cache of the tag store hash-table.")
(defvar decknix--agent-tags-cache-mtime nil
  "File modification time when cache was last populated.")
(defvar decknix--agent-tags-cache-checked-at 0.0
  "`float-time' when we last validated the tag-store cache on disk.
Used to throttle `file-exists-p' / `file-attributes' syscalls and the
v1→v2 migration walk on hot paths (sidebar refresh, group-by-conv).")
(defconst decknix--agent-tags-cache-ttl 1.0
  "Seconds to trust `decknix--agent-tags-cache' without re-checking disk.
The sidebar refresh timer calls `decknix--agent-tags-read' O(N) times per
cycle via `decknix--agent-session-group-by-conversation'; statting the
tag file plus walking the store for v1 migrations N times per refresh
would saturate a core (see #hub-loop).  The mtime check still fires
after the TTL elapses, so external edits converge within one second.")

(defconst decknix--agent-tags-canonical-key-version 1
  "Schema version for the canonical conv-key migration.
Bump in lockstep with `decknix--agent-conv-key-canonical-length' or any
future change to the conv-key derivation that would invalidate previously
written entries.  When `decknix--agent-tags-read' sees a stored
`_canonicalKeyVersion' lower than this constant it runs
`decknix--agent-tags--canonicalize-keys' once and bumps the flag.")

(defun decknix--agent-tags-read ()
  "Read the tag store, returning an in-memory cached hash-table.
Re-reads from disk only if the file has been modified externally.
Auto-migrates v1 (session-keyed) format to v2 (conversation-keyed).

When called repeatedly inside `decknix--agent-tags-cache-ttl' seconds
the cached hash-table is returned directly without stat-ing the file
or walking the store for orphaned v1 entries."
  ;; Fast path: recent cache hit — skip stat + migration walk.
  (if (and decknix--agent-tags-cache
           (< (- (float-time) decknix--agent-tags-cache-checked-at)
              decknix--agent-tags-cache-ttl))
      decknix--agent-tags-cache
    (setq decknix--agent-tags-cache-checked-at (float-time))
    ;; Check if cache is valid (file hasn't changed)
    (let ((current-mtime (and (file-exists-p decknix--agent-tags-file)
                              (file-attribute-modification-time
                               (file-attributes decknix--agent-tags-file)))))
      (when (or (null decknix--agent-tags-cache)
                (not (equal current-mtime decknix--agent-tags-cache-mtime)))
        ;; Cache miss — read from disk
        (setq decknix--agent-tags-cache
              (if (file-exists-p decknix--agent-tags-file)
                  (condition-case err
                      (let* ((json-object-type 'hash-table)
                             (json-array-type 'list)
                             (json-key-type 'string))
                        (json-read-file decknix--agent-tags-file))
                    (error
                     (message "Warning: could not read tag store: %s"
                              (error-message-string err))
                     (make-hash-table :test 'equal)))
                (make-hash-table :test 'equal)))
        (setq decknix--agent-tags-cache-mtime current-mtime)))
    (let ((store decknix--agent-tags-cache))
      ;; Auto-migrate v1 format: session-keyed entries → conversation-keyed.
      ;; Handles both initial migration (no "conversations" key) and
      ;; incremental migration (orphaned v1 entries coexisting with v2).
      (let ((convs (or (gethash "conversations" store)
                       (make-hash-table :test 'equal)))
            (sessions (decknix--agent-session-list))
            (old-entries nil)
            (migrated 0))
      ;; Collect orphaned session-keyed entries (UUID keys with tags).
      ;; Skip the well-known root keys plus the `_canonicalKeyVersion'
      ;; bookkeeping flag added by the canonical conv-key migration.
      (maphash (lambda (key val)
                 (when (and (hash-table-p val)
                            (gethash "tags" val)
                            (not (member key '("conversations"
                                               "bookmarks"
                                               "_canonicalKeyVersion"))))
                   (push (cons key val) old-entries)))
               store)
      (when old-entries
        ;; Resolve each old session → conversation and merge tags
        (dolist (entry old-entries)
          (let* ((sid (car entry))
                 (data (cdr entry))
                 (match (seq-find
                         (eval `(lambda (s)
                                  (string= (alist-get 'sessionId s) ,sid))
                               t)
                         sessions))
                 (conv-key (when match
                             (decknix--agent-conversation-key
                              (alist-get 'firstUserMessage match ""))))
                 (tags (gethash "tags" data)))
            (when (and conv-key tags)
              (let ((conv-entry (or (gethash conv-key convs)
                                    (let ((h (make-hash-table :test 'equal)))
                                      (puthash "tags" nil h)
                                      (puthash "sessions" nil h)
                                      h))))
                ;; Merge tags
                (let ((existing (gethash "tags" conv-entry)))
                  (dolist (tag tags)
                    (cl-pushnew tag existing :test #'string=))
                  (puthash "tags" existing conv-entry))
                ;; Track session
                (let ((sids (gethash "sessions" conv-entry)))
                  (cl-pushnew sid sids :test #'string=)
                  (puthash "sessions" sids conv-entry))
                (puthash conv-key conv-entry convs))
              ;; Only remove the v1 entry once it has been
              ;; successfully merged into v2.  Leaving
              ;; unresolved v1 entries in place lets a later
              ;; pass complete the migration when session-list
              ;; / firstUserMessage data becomes available —
              ;; the previous unconditional `remhash' was the
              ;; source of tag loss on the guided-session
              ;; creation race.
              (remhash sid store)
              (setq migrated (1+ migrated)))))
        ;; Write back the cleaned store
        (puthash "conversations" convs store)
        (unless (gethash "bookmarks" store)
          (puthash "bookmarks" (make-hash-table :test 'equal) store))
        (decknix--agent-tags-write store)
        (when (> migrated 0)
          (message "Migrated %d v1 tag entries to conversation format"
                   migrated))))
      ;; Second-pass migration: re-key v2 entries that were written
      ;; under the pre-canonical hash (full comint input, not the
      ;; jq-truncated firstUserMessage prefix the read side uses).
      ;; Idempotent via `_canonicalKeyVersion'.  Requires a populated
      ;; session list to look up firstUserMessage values; runs as a
      ;; no-op when sessions are unavailable so the migration completes
      ;; on a later read once the cache warms up.
      (decknix--agent-tags--maybe-canonicalize-keys store)
      store)))

(defun decknix--agent-tags--maybe-canonicalize-keys (store)
  "Run the canonical conv-key migration on STORE if needed.
Gated by the `_canonicalKeyVersion' flag so the walk only happens
once per upgrade.  Skipped entirely when `decknix--agent-session-list'
is empty, so the migration defers gracefully until the session
cache populates."
  (let ((current (gethash "_canonicalKeyVersion" store)))
    (when (or (not (numberp current))
              (< current decknix--agent-tags-canonical-key-version))
      (let* ((sessions (decknix--agent-session-list))
             (rekeyed (and sessions
                           (decknix--agent-tags--canonicalize-keys
                            store sessions))))
        (when (and rekeyed (> rekeyed 0))
          (message "Re-keyed %d conversation entries to canonical hash"
                   rekeyed))
        ;; Only stamp the version flag once we had session data to
        ;; work with -- otherwise a cold-start read would mark the
        ;; migration done before any orphan could be resolved.
        (when sessions
          (puthash "_canonicalKeyVersion"
                   decknix--agent-tags-canonical-key-version
                   store)
          (decknix--agent-tags-write store))))))

(defun decknix--agent-tags--canonicalize-keys (store sessions)
  "Re-key conversation entries in STORE under the canonical hash.
SESSIONS is the cached session-list (alists with `sessionId' +
`firstUserMessage').  For each entry whose first session-id resolves
to a firstUserMessage that hashes to a different conv-key than the
entry is currently stored under, the entry is moved to the canonical
key.  Tags / sessions / workspace are merged into any pre-existing
canonical entry so no metadata is lost.

Mutates STORE in place; returns the number of entries re-keyed."
  (let* ((convs (gethash "conversations" store))
         (sid->fum (make-hash-table :test 'equal))
         (rekeyed 0)
         (to-move nil))
    (when (hash-table-p convs)
      ;; Build session-id -> firstUserMessage lookup once so the
      ;; per-entry resolve is O(1) instead of O(N) over the full
      ;; session list.
      (dolist (s sessions)
        (let ((sid (alist-get 'sessionId s))
              (fum (alist-get 'firstUserMessage s)))
          (when (and sid fum)
            (puthash sid fum sid->fum))))
      ;; First pass: collect entries whose key disagrees with the
      ;; canonical hash of their first session's firstUserMessage.
      ;; Defer the mutation so we don't disturb the maphash walk.
      (maphash
       (lambda (key entry)
         (when (hash-table-p entry)
           (let* ((sids (gethash "sessions" entry))
                  (sid (car sids))
                  (fum (and sid (gethash sid sid->fum)))
                  (canonical (and fum (decknix--agent-conversation-key fum))))
             (when (and canonical (not (string= canonical key)))
               (push (list key canonical entry) to-move)))))
       convs)
      ;; Second pass: apply moves, merging into any pre-existing
      ;; canonical-key entry instead of clobbering it.
      (dolist (mv to-move)
        (let* ((old-key (nth 0 mv))
               (new-key (nth 1 mv))
               (entry (nth 2 mv))
               (target (gethash new-key convs)))
          (cond
           ((null target)
            (puthash new-key entry convs)
            (remhash old-key convs))
           (t
            (let ((merged-tags (gethash "tags" target)))
              (dolist (tag (gethash "tags" entry))
                (cl-pushnew tag merged-tags :test #'string=))
              (puthash "tags" merged-tags target))
            (let ((merged-sids (gethash "sessions" target)))
              (dolist (sid (gethash "sessions" entry))
                (cl-pushnew sid merged-sids :test #'string=))
              (puthash "sessions" merged-sids target))
            (unless (gethash "workspace" target)
              (when-let ((ws (gethash "workspace" entry)))
                (puthash "workspace" ws target)))
            (remhash old-key convs)))
          (setq rekeyed (1+ rekeyed)))))
    rekeyed))

(defun decknix--agent-tags-write (store)
  "Write STORE (hash-table) to the tag file and update in-memory cache."
  (let ((dir (file-name-directory decknix--agent-tags-file)))
    (unless (file-directory-p dir)
      (make-directory dir t))
    (with-temp-file decknix--agent-tags-file
      (let ((json-encoding-pretty-print t))
        (insert (json-encode store))))
    ;; Update cache so subsequent reads don't hit disk
    (setq decknix--agent-tags-cache store
          decknix--agent-tags-cache-mtime
          (file-attribute-modification-time
           (file-attributes decknix--agent-tags-file)))))

(defun decknix--agent-tags-conversations (store)
  "Get the conversations hash-table from STORE."
  (or (gethash "conversations" store)
      (let ((convs (make-hash-table :test 'equal)))
        (puthash "conversations" convs store)
        convs)))

(provide 'decknix-agent-tags-store)
;;; decknix-agent-tags-store.el ends here
