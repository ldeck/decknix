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
;; This module owns the storage layer:
;;
;;   `decknix--agent-tags-read'           — cached read with v1 -> v2
;;                                            auto-migration
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
      ;; Collect orphaned session-keyed entries (UUID keys with tags)
      (maphash (lambda (key val)
                 (when (and (hash-table-p val)
                            (gethash "tags" val)
                            (not (member key '("conversations" "bookmarks"))))
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
      store)))

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
