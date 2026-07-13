;;; decknix-agent-session-cache.el --- Session list cache + jq fetch -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-parse "0.1"))
;; Keywords: agent, agent-shell, decknix, session, cache

;;; Commentary:
;;
;; In-process cache for the auggie session list, backed by a persistent
;; mtime-keyed metadata store.  Session JSON files are parsed by jq exactly
;; once per file lifetime; subsequent reads come from an in-memory hash
;; table that is saved to disk and reloaded on daemon restart.
;;
;; Design:
;;
;;   1. File listing  — `decknix--session-list-files' uses `ls -t | head'
;;      to get the N newest session paths in ~1 ms (no JSON reads).
;;
;;   2. Mtime cache   — `decknix--session-meta' checks whether a file's
;;      mtime matches the cached entry.  Finished sessions never change,
;;      so after the first parse the cost is a hash lookup.
;;
;;   3. Persistence   — `decknix--session-meta-cache-load/save' round-trips
;;      the hash table through `decknix--session-meta-cache-file' so the
;;      cache survives daemon restarts without re-parsing anything.
;;
;;   4. Bulk fallback — `decknix--agent-session-jq-cmd' (kept for backward
;;      compatibility with the grep thorough path) runs parallel jq over all
;;      files when a cold cache needs a full initial fill.
;;
;; Public surface used elsewhere:
;;
;;   `decknix--agent-session-list'             — read the (cached) list
;;   `decknix--agent-session-refresh-sync'     — mtime-keyed sync refresh
;;   `decknix--agent-session-refresh-async'    — mtime-keyed async refresh
;;   `decknix--agent-session-jq-cmd'           — bulk jq command builder
;;   `decknix--agent-session-ensure-jq-filter' — write jq script once
;;   `decknix--session-meta-cache-load'        — load persistent cache
;;   `decknix--session-meta-cache-save'        — flush cache to disk
;;   `decknix--session-meta'                   — per-file mtime lookup
;;   `decknix--session-parse-file'             — single-file jq parse
;;   `decknix--session-list-files'             — cheap file listing
;;
;; State vars (`-cache', `-cache-time', `-cache-ttl', `-refresh-proc',
;; `-jq-filter-file', `-sessions-dir') are intentionally exposed so the
;; sidebar / picker / batch flows can read or invalidate them directly.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'decknix-agent-provider)

;; Forward declaration: parser lives in sibling `decknix-agent-parse',
;; loaded by the heredoc immediately before this module.
(declare-function decknix--agent-session-parse "decknix-agent-parse" (raw))
(declare-function decknix--agent-session-parse-object "decknix-agent-parse" (raw))

;; Forward declaration: the path builder lives in sibling
;; `decknix-agent-session-history' (which itself requires this module
;; for `decknix--session-meta', so we must not `require' it back --
;; both are loaded at daemon start).  Used by the cheap disk-probe
;; branch of `decknix--agent-provider-for-session-id'.
(declare-function decknix--agent-session-file
                  "decknix-agent-session-history" (session-id &optional provider-id))

;; ---------------------------------------------------------------------------
;; Public state — read/invalidated by sidebar, picker, batch flows
;; ---------------------------------------------------------------------------

(defvar decknix--agent-session-cache-map (make-hash-table :test 'eq)
  "Map of provider-id (symbol) -> cached list of sessions (alists).")

(defvar decknix--agent-session-cache-time-map (make-hash-table :test 'eq)
  "Map of provider-id (symbol) -> float-time when last updated.")

(defvar decknix--agent-session-refresh-proc-map (make-hash-table :test 'eq)
  "Map of provider-id (symbol) -> process handle for async refresh.")

(defvar decknix--agent-session-cache nil
  "Legacy shim for `auggie' session cache.")

(defvar decknix--agent-session-cache-time 0
  "Legacy shim for `auggie' session cache time.")

(defvar decknix--agent-session-refresh-proc nil
  "Legacy shim for `auggie' session refresh process.")


(defvar decknix--agent-session-cache-ttl 120
  "Seconds before the session cache is considered stale.")

(defvar decknix--agent-session-cache-max-files 200
  "Maximum number of session JSON files to consider per refresh (newest first).
With 1000+ session files this limits the mtime-diff scan to the most
recently active sessions.  Nil scans all files.")

(defvar decknix--agent-sessions-dir
  (expand-file-name "~/.augment/sessions")
  "Directory containing auggie session JSON files.")

(defvar decknix--agent-session-jq-filter-map (make-hash-table :test 'eq)
  "Map of provider-id (symbol) -> temp file path for jq filter.")

(defvar decknix--agent-session-jq-filter-file nil
  "Legacy shim for `auggie' jq filter file.")

;; ---------------------------------------------------------------------------
;; Mtime-keyed metadata cache
;; ---------------------------------------------------------------------------

(defvar decknix--session-meta-cache
  (make-hash-table :test 'equal :size 1024)
  "In-memory mtime-keyed metadata cache.
Key   = absolute file path (string).
Value = plist (:mtime FLOAT :data ALIST) where ALIST is the same
        format returned by `decknix--agent-session-parse'.")

(defvar decknix--session-meta-cache-file
  (expand-file-name "~/.config/decknix/hub/session-meta.eld")
  "Persistent on-disk backing store for `decknix--session-meta-cache'.
Written as a printed Elisp alist; loaded at daemon startup via
`decknix--session-meta-cache-load'.")

;; ---------------------------------------------------------------------------
;; Low-level helpers
;; ---------------------------------------------------------------------------

(defun decknix--session-file-mtime (path)
  "Return the modification time of PATH as a float-time, or nil if missing."
  (let ((attrs (file-attributes path)))
    (when attrs
      (float-time (file-attribute-modification-time attrs)))))

(defvar decknix--session-meta-reparse-throttle 4.0
  "Seconds to serve slightly-stale cached metadata for a *changed* session file.
An actively-streaming agent rewrites its session JSONL on every token, so
its mtime bumps continuously and the mtime cache never hits.  Re-slurping
the whole (often large) file through `jq' on every sidebar refresh is the
dominant main-thread stall (CPU profiling caught 672 synchronous `jq'
parses / 225s in a few minutes).  Within this window a changed file
reuses its last parsed metadata instead of re-parsing, bounding re-parses
to once per window per file no matter how fast the file churns.  Set to 0
to always re-parse changed files (previous behaviour).")

(defun decknix--session-cache-hit (entry mtime)
  "Return usable cached :data from ENTRY for MTIME, or nil.
Usable when the file is unchanged since the cached parse, OR it changed
but was parsed within `decknix--session-meta-reparse-throttle' seconds
\(see that variable).  MTIME is the file's current float-time mtime."
  (when (and entry mtime)
    (let ((cached-mtime (plist-get entry :mtime))
          (parsed-at (plist-get entry :parsed-at))
          (data (plist-get entry :data)))
      (when (and data
                 (or (and cached-mtime (= mtime cached-mtime))
                     (and (> decknix--session-meta-reparse-throttle 0)
                          parsed-at
                          (< (- (float-time) parsed-at)
                             decknix--session-meta-reparse-throttle))))
        data))))

(defvar decknix--session-list-files-cache (make-hash-table :test 'eq)
  "Provider-id (symbol) -> plist (:key (COUNT . MAX-MTIME) :paths PATHS).
Fingerprint cache that lets `decknix--session-list-files' skip the
sort pass when the sessions dir is unchanged between calls.  Any file
added, removed, or touched bumps COUNT or MAX-MTIME, so no observable
staleness slips past.  Not persisted; cheap to rebuild.")

(defun decknix--session-collect-files-and-mtimes-depth (dir ext maxdepth)
  "Return alist ((MTIME . PATH) ...) for regular files under DIR ending in EXT.
Walks up to MAXDEPTH levels (1 = files directly in DIR, auggie shape;
2 = one subdir deep, claude `<sessions-dir>/<project>/`).  Uses
`directory-files-and-attributes' so the readdir + stat happens in one
batched pass per directory instead of a follow-up `file-attributes' call
per entry.  Returns nil when DIR does not exist.  Symlinks are not
followed.  Hidden entries (leading dot) are skipped to match the shell
glob semantics of the previous `ls -t1 %s/*%s' path."
  (when (file-directory-p dir)
    (let ((results nil)
          (pattern (concat (regexp-quote ext) "\\'")))
      (cl-labels
          ((walk (d depth)
             (when (>= depth 1)
               (dolist (entry (directory-files-and-attributes
                               d t "\\`[^.]" t))
                 (let* ((path (car entry))
                        (attrs (cdr entry))
                        (type (file-attribute-type attrs)))
                   (cond
                    ;; symlink: TYPE is the target string -- skip.
                    ((stringp type) nil)
                    ;; directory: TYPE is t -- recurse.
                    ((eq type t) (walk path (1- depth)))
                    ;; regular file matching extension.
                    ((and (null type) (string-match-p pattern path))
                     (push (cons (float-time
                                  (file-attribute-modification-time attrs))
                                 path)
                           results))))))))
        (walk dir maxdepth))
      results)))

(defun decknix--session-list-files (provider-id &optional max)
  "Return absolute session JSON paths for PROVIDER-ID sorted newest-first.
When MAX is non-nil, limit to at most MAX files.

Result is cached per PROVIDER-ID under a `(COUNT . MAX-MTIME)'
fingerprint of the scan; when the fingerprint is unchanged across
calls the cached list is returned as-is (same cons identity), skipping
the sort.  Adding, removing, or touching any file bumps the
fingerprint, so no observable staleness slips past.

Native replacement for the historical `ls -t1' / `find | xargs ls -t1'
shell pipeline: walks the provider's sessions dir with
`directory-files-and-attributes' (one readdir+stat batch per dir) via
`decknix--session-collect-files-and-mtimes-depth' and sorts in-process
by mtime.  Removes a shell fork from every sidebar refresh and fixes a
latent bug where a missing sessions dir under zsh returned a bogus
one-element list holding the shell's `no matches found' error text."
  (let ((entry (decknix--session-list-files--entry provider-id)))
    (when entry
      (let ((paths (plist-get entry :paths)))
        (if max (seq-take paths max) paths)))))

(defun decknix--session-list-files-with-mtimes (provider-id &optional max)
  "Return ((MTIME . PATH) ...) for PROVIDER-ID sorted newest-first.
When MAX is non-nil, limit to at most MAX pairs.

Pair-returning sibling of `decknix--session-list-files' backed by the
same fingerprint cache: unchanged fs state returns the exact same cons
cell across calls (skip-sort proof).  Lets
`decknix--agent-session-refresh-{sync,async}' consume mtime alongside
each path without a second per-file stat during the partition loop."
  (let ((entry (decknix--session-list-files--entry provider-id)))
    (when entry
      (let ((pairs (plist-get entry :pairs)))
        (if max (seq-take pairs max) pairs)))))

(defun decknix--session-list-files--entry (provider-id)
  "Return the cache entry for PROVIDER-ID: (:key KEY :paths PATHS :pairs PAIRS).
Rebuilds via `directory-files-and-attributes' walk when the fs
fingerprint (count . max-mtime) has changed; returns the cached entry
as-is otherwise.  Returns nil when the sessions dir is empty/missing.
Common back-end for `decknix--session-list-files' and
`decknix--session-list-files-with-mtimes' so both APIs stay `eq'-stable
and share the single sort pass."
  (let* ((dir (decknix-agent-provider-sessions-dir provider-id))
         (ext (decknix-agent-provider-session-file-extension provider-id))
         (hist (decknix-agent-provider-history-file provider-id))
         ;; Multi-project providers (claude, :history-file set) live at
         ;; `<sessions-dir>/<project-hash>/<sid>.jsonl' -- depth 2.
         ;; Single-dir providers (auggie) at `<sessions-dir>/<sid>.json' -- depth 1.
         (pairs (decknix--session-collect-files-and-mtimes-depth
                 dir ext (if hist 2 1))))
    (when pairs
      (let* ((count (length pairs))
             (max-mtime (apply #'max (mapcar #'car pairs)))
             (key (cons count max-mtime))
             (cached (gethash provider-id decknix--session-list-files-cache)))
        (if (and cached (equal (plist-get cached :key) key))
            cached
          (let* ((sorted (sort pairs (lambda (a b) (> (car a) (car b)))))
                 (only-paths (mapcar #'cdr sorted))
                 (fresh (list :key key :paths only-paths :pairs sorted)))
            (puthash provider-id fresh decknix--session-list-files-cache)
            fresh))))))

(defun decknix--session-parse-file (provider-id path)
  "Extract session metadata from PATH for PROVIDER-ID.
Returns a parsed alist via `decknix--agent-session-parse-object' (the
per-file jq path emits one bare `{...}' object, which the array parser
`decknix--agent-session-parse' rejects), stamped with (filePath . PATH)
so `decknix--session-store-parsed' can write the correct mtime-cache
entry for multi-project providers (e.g., claude-code) whose session
files live under a project-hash sub-directory and cannot be
reconstructed from sessionId + sessions-dir alone.
Returns nil on parse failure."
  (let* ((jqf (decknix--agent-session-ensure-jq-filter provider-id))
         (ext (decknix-agent-provider-session-file-extension provider-id))
         ;; Claude uses JSONL; JQ needs -s (slurp) to handle it if the filter
         ;; expects an array.  Auggie uses a single JSON object.
         (jq-args (if (string= ext ".jsonl") "-Mcs" "-Mc"))
         (raw (shell-command-to-string
               (concat "jq " jq-args " -f "
                       (shell-quote-argument jqf)
                       " " (shell-quote-argument path)
                       " 2>/dev/null")))
         (data (decknix--agent-session-parse-object raw)))
    (when data
      ;; Stamp filePath so decknix--session-store-parsed can key the mtime
      ;; cache on the real absolute path regardless of provider layout.
      ;; decknix--session-meta stamps providerId in the same pattern.
      (if (alist-get 'filePath data) data
        (cons (cons 'filePath path) data)))))

(defun decknix--session-meta (provider-id path)
  "Return session metadata alist for PATH using the mtime-keyed cache.
PROVIDER-ID is the agent backend.
Returns cached data when the file's mtime matches the stored entry;
otherwise calls `decknix--session-parse-file' and updates the cache.
Phase 1.3: stamps `providerId' on freshly parsed data so resume and
the session picker can identify the backend without rechecking paths.
Returns nil when PATH does not exist."
  (let* ((mtime (decknix--session-file-mtime path))
         (entry (gethash path decknix--session-meta-cache))
         (hit (decknix--session-cache-hit entry mtime)))
    (or hit
        (when mtime
          (let* ((raw  (decknix--session-parse-file provider-id path))
                 ;; Phase 1.3: stamp providerId so callers (resume,
                 ;; session picker) know which backend owns this session.
                 (data (when raw
                         (if (alist-get 'providerId raw) raw
                           (cons (cons 'providerId provider-id) raw)))))
            (when data
              (puthash path (list :mtime mtime :data data :parsed-at (float-time))
                       decknix--session-meta-cache)
              data))))))

;; ---------------------------------------------------------------------------
;; Sub-agent metadata fast path (#146)
;; ---------------------------------------------------------------------------
;;
;; The sidebar walks a session's `subagents/' dir on every paint and, for a
;; STREAMING sub-agent, the transcript's mtime bumps on every token so the
;; mtime cache never hits -- re-spawning `jq' per file per paint was the
;; dominant main-thread stall (see `decknix--session-meta-reparse-throttle').
;; But a sub-agent transcript's identity fields (sessionId / created /
;; firstUserMessage, from the immutable first line) never change, so we parse
;; them ONCE and cache permanently by path; only `modified' is refreshed, and
;; from the file mtime (a stat) rather than a re-parse.  No subprocess on the
;; hot path once a file has been seen.

(defvar decknix--agent-subagent-meta-cache
  (make-hash-table :test 'equal :size 256)
  "Permanent immutable-field cache for sub-agent metadata, keyed by path.
Value is the alist last returned by `decknix--session-meta' for that path.
Never invalidated by mtime -- the transcript's first line is immutable, so
a streaming sub-agent no longer re-parses on every sidebar paint.  Cleared
only on daemon reload.")

(defun decknix--agent-subagent-meta-with-mtime (base mtime)
  "Return BASE metadata with `modified' set from MTIME (a float-time).
The on-disk mtime is fresher than the last-parsed transcript timestamp and
free to read, and drives sub-agent liveness.  MTIME nil -> BASE unchanged.
Does not mutate BASE."
  (if (null mtime)
      base
    (cons (cons 'modified (format-time-string "%Y-%m-%dT%H:%M:%S%z"
                                              (seconds-to-time mtime)))
          (seq-remove (lambda (kv) (eq (car-safe kv) 'modified)) base))))

(defun decknix--agent-subagent-meta (provider-id path)
  "Return sub-agent metadata for PATH without re-parsing a streaming file.
Immutable fields are parsed once (via `decknix--session-meta', which may
already be a cache hit) and cached permanently by PATH; `modified' is
refreshed from the file mtime on every call.  Returns nil when PATH is
missing or unparseable."
  (when (and path (stringp path))
    (let ((base (or (gethash path decknix--agent-subagent-meta-cache)
                    (let ((parsed (decknix--session-meta provider-id path)))
                      (when parsed
                        (puthash path parsed decknix--agent-subagent-meta-cache))
                      parsed))))
      (when base
        (decknix--agent-subagent-meta-with-mtime
         base (decknix--session-file-mtime path))))))

;; ---------------------------------------------------------------------------
;; Persistence
;; ---------------------------------------------------------------------------

(defun decknix--session-meta-cache-load ()
  "Load the persistent metadata cache from disk into `decknix--session-meta-cache'.
Silently no-ops when the cache file does not yet exist (first ever run)."
  (when (file-exists-p decknix--session-meta-cache-file)
    (condition-case _
        (with-temp-buffer
          (insert-file-contents decknix--session-meta-cache-file)
          (let ((data (read (current-buffer))))
            (when (listp data)
              (clrhash decknix--session-meta-cache)
              (dolist (entry data)
                (when (and (consp entry) (stringp (car entry))
                           (listp (cdr entry)))
                  (puthash (car entry) (cdr entry)
                           decknix--session-meta-cache))))))
      (error nil))))

(defun decknix--session-meta-cache-save ()
  "Flush `decknix--session-meta-cache' to disk atomically."
  (condition-case err
      (let ((dir (file-name-directory decknix--session-meta-cache-file)))
        (unless (file-exists-p dir)
          (make-directory dir t))
        (with-temp-buffer
          (let ((entries nil)
                ;; `prin1' rather than `pp': this is a machine-read cache
                ;; (loaded via `read'), never edited by hand, and can hold
                ;; ~1024 entries.  `pp' is a known hot spot -- its
                ;; `pp--object'/`pp-fill' passes cost meaningful CPU on the
                ;; sidebar-refresh path -- while `prin1' round-trips
                ;; identically for `read' at a fraction of the cost.
                (print-length nil)
                (print-level nil))
            (maphash (lambda (k v) (push (cons k v) entries))
                     decknix--session-meta-cache)
            (prin1 entries (current-buffer)))
          (write-region (point-min) (point-max)
                        decknix--session-meta-cache-file nil 'quiet)))
    (error (message "decknix-session-meta: save failed: %s" err))))

;; ---------------------------------------------------------------------------
;; jq filter file (shared by per-file and bulk parse paths)
;; ---------------------------------------------------------------------------

(defun decknix--agent-session-ensure-jq-filter (provider-id)
  "Write the jq extraction filter for PROVIDER-ID to a temp file.
Returns the path.  Used by both single-file and bulk parse paths."
  (let ((path (gethash provider-id decknix--agent-session-jq-filter-map)))
    (unless (and path (file-exists-p path))
      (let ((filter (decknix-agent-provider-session-jq-filter provider-id)))
        (setq path (make-temp-file (format "agent-%s-session-" provider-id)
                                   nil ".jq"))
        (with-temp-file path
          (insert filter "\n"))
        (puthash provider-id path decknix--agent-session-jq-filter-map)))
    path))

;; ---------------------------------------------------------------------------
;; Bulk jq command (kept for grep thorough path backward compatibility)
;; ---------------------------------------------------------------------------

(defun decknix--agent-session-jq-cmd (provider-id)
  "Shell command to bulk-extract session metadata for PROVIDER-ID.
Used by the grep thorough path (C-u C-u C-c A g) and as the cold-cache
fallback when many files need parsing at once.
Scans at most `decknix--agent-session-cache-max-files' newest files."
  (let* ((jqf (decknix--agent-session-ensure-jq-filter provider-id))
         (dir (shell-quote-argument (decknix-agent-provider-sessions-dir provider-id)))
         (ext (decknix-agent-provider-session-file-extension provider-id))
         (max decknix--agent-session-cache-max-files)
         (jq-args (if (string= ext ".jsonl") "-Mcs" "-Mc"))
         (list-cmd (if (string= ext ".jsonl")
                       (if max
                           (format "find %s -maxdepth 2 -name '*%s' -print0 2>/dev/null | xargs -0 ls -t1 2>/dev/null | head -%d"
                                   dir ext max)
                         (format "find %s -maxdepth 2 -name '*%s' -print 2>/dev/null"
                                 dir ext))
                     (if max
                         (concat "ls -t1 " dir "/*" ext " 2>/dev/null"
                                 " | head -" (number-to-string max))
                       (concat "find " dir
                               " -maxdepth 1 -name '*" ext "' -print 2>/dev/null")))))
    (concat
     list-cmd
     " | tr '\\n' '\\0'"
     " | xargs -0 -P8 -I{} jq " jq-args " -f "
     (shell-quote-argument jqf)
     " {} 2>/dev/null"
     " | jq -Msc 'sort_by(.modified) | reverse'")))

;; ---------------------------------------------------------------------------
;; Internal: parse a set of files (small = sequential, large = parallel jq)
;; ---------------------------------------------------------------------------

(defun decknix--session-refresh-parse-files (provider-id files)
  "Parse FILES for PROVIDER-ID and return a list of session alists.
For small sets (< 20 files) parse sequentially; for larger sets use
parallel jq via a temp file list for speed (cold-cache initial fill)."
  (if (< (length files) 20)
      (delq nil (mapcar (lambda (f) (decknix--session-parse-file provider-id f)) files))
    ;; Large set: write paths to a temp file, fan out to parallel jq.
    ;; After parsing, stamp filePath on each result so decknix--session-store-parsed
    ;; can cache multi-project providers (claude-code) whose path cannot be
    ;; reconstructed from sessionId + dir alone.
    (let* ((jqf (decknix--agent-session-ensure-jq-filter provider-id))
           (ext (decknix-agent-provider-session-file-extension provider-id))
           (jq-args (if (string= ext ".jsonl") "-Mcs" "-Mc"))
           (list-file (make-temp-file (format "agent-%s-files-" provider-id))))
      (unwind-protect
          (progn
            (with-temp-file list-file
              (dolist (f files) (insert f "\n")))
            (let ((results
                   (decknix--agent-session-parse
                    (shell-command-to-string
                     (concat "cat " (shell-quote-argument list-file)
                             " | tr '\\n' '\\0'"
                             " | xargs -0 -P8 -I{} jq " jq-args " -f "
                             (shell-quote-argument jqf)
                             " {} 2>/dev/null"
                             " | jq -Msc 'sort_by(.modified) | reverse'")))))
              (decknix--session-stamp-file-paths results files)))
        (when (file-exists-p list-file)
          (delete-file list-file))))))

;; Internal helper: stamp (filePath . PATH) on bulk-parsed results that lack it.
;; Used after large-set parallel jq parses where per-file path info is not
;; embedded in the combined JSON output.  Builds a sessionId -> path map from
;; FILES (absolute paths whose basename == sessionId) and stamps filePath on
;; each alist in PARSED-LIST that is still missing it.
(defun decknix--session-stamp-file-paths (parsed-list files)
  "Return PARSED-LIST with (filePath . PATH) stamped using FILES.
PARSED-LIST is a list of session alists from a bulk jq parse.
FILES is the list of absolute file paths that were fed to that parse;
each basename (sans extension) is taken as the sessionId key."
  (let ((sid-map (make-hash-table :test 'equal :size (length files))))
    (dolist (f files)
      (puthash (file-name-base f) f sid-map))
    (mapcar (lambda (data)
              (if (or (not (listp data)) (alist-get 'filePath data))
                  data
                (let* ((sid  (alist-get 'sessionId data))
                       (path (and sid (gethash sid sid-map))))
                  (if path (cons (cons 'filePath path) data) data))))
            parsed-list)))

;; Internal helper: update mtime cache entries for a list of parsed alists.
(defun decknix--session-store-parsed (provider-id alist-list)
  "Store ALIST-LIST entries in `decknix--session-meta-cache' keyed by path+mtime.
PROVIDER-ID is the agent backend.
Each alist should carry a (filePath . PATH) entry — stamped by
`decknix--session-parse-file' for sequential parses, or by
`decknix--session-stamp-file-paths' after a bulk jq parse.
Without filePath, multi-project providers (claude-code, :history-file set)
are silently skipped; single-directory providers (auggie) fall back to
reconstructing path from sessionId + dir."
  (let ((dir (decknix-agent-provider-sessions-dir provider-id))
        (ext (decknix-agent-provider-session-file-extension provider-id))
        (hist (decknix-agent-provider-history-file provider-id)))
    (dolist (data alist-list)
      (let* ((sid  (alist-get 'sessionId data))
             ;; Prefer filePath stamped by decknix--session-parse-file or
             ;; decknix--session-stamp-file-paths.  Fall back to the
             ;; single-directory layout for providers without :history-file.
             (path (or (alist-get 'filePath data)
                       (unless hist
                         (expand-file-name (concat sid ext) dir))))
             (mtime (and path (decknix--session-file-mtime path))))
        (when (and path mtime)
          (puthash path (list :mtime mtime :data data :parsed-at (float-time))
                   decknix--session-meta-cache))))))

;; ---------------------------------------------------------------------------
;; Public refresh functions
;; ---------------------------------------------------------------------------

(defun decknix--agent-session-refresh-sync (&optional provider-id)
  "Synchronously refresh session cache for PROVIDER-ID.
Defaults to `decknix-agent-default-provider'.
Files already in the persistent cache cost only a hash lookup; only new
or modified files trigger a jq parse.  The result is sorted newest-first
and the persistent cache is saved if any new entries were written."
  (let* ((provider-id (or provider-id decknix-agent-default-provider))
         (pairs (decknix--session-list-files-with-mtimes
                 provider-id decknix--agent-session-cache-max-files))
         (cached-data nil)
         (new-files nil))
    ;; Partition: cached (mtime match or within re-parse throttle) vs new/changed.
    ;; Mtime comes from the list-files scan (single stat), not a per-file re-stat.
    (dolist (pair pairs)
      (let* ((mtime (car pair))
             (path (cdr pair))
             (entry (gethash path decknix--session-meta-cache))
             (hit (decknix--session-cache-hit entry mtime)))
        (if hit
            (push hit cached-data)
          (push path new-files))))
    (setq new-files (nreverse new-files))
    (let* ((before (hash-table-count decknix--session-meta-cache))
           (new-data (when new-files
                       (decknix--session-refresh-parse-files provider-id new-files))))
      ;; Update mtime cache for newly parsed files and persist.
      (when new-data
        (decknix--session-store-parsed provider-id new-data))
      (when (/= (hash-table-count decknix--session-meta-cache) before)
        (decknix--session-meta-cache-save))
      ;; Assemble result: cached (already sorted newest-first by ls -t)
      ;; followed by newly parsed.
      (let ((full-list (append (nreverse cached-data) (or new-data '()))))
        (puthash provider-id full-list decknix--agent-session-cache-map)
        (puthash provider-id (float-time) decknix--agent-session-cache-time-map)
        ;; Update legacy shims if provider is auggie
        (when (eq provider-id 'auggie)
          (setq decknix--agent-session-cache full-list
                decknix--agent-session-cache-time (float-time)))
        full-list))))

(defun decknix--agent-session-refresh-async (&optional provider-id)
  "Refresh session cache for PROVIDER-ID without blocking.
Defaults to `decknix-agent-default-provider'.
On a warm cache (common case) this completes synchronously in < 1 ms
since only file-attribute lookups are needed.  When new files exist,
small sets are parsed synchronously; large sets (cold cache) run jq
in a background subprocess."
  (let* ((provider-id (or provider-id decknix-agent-default-provider))
         (proc (gethash provider-id decknix--agent-session-refresh-proc-map)))
    (when (or (null proc) (not (process-live-p proc)))
      (let* ((pairs (decknix--session-list-files-with-mtimes
                     provider-id decknix--agent-session-cache-max-files))
             (cached-data nil)
             (new-files nil))
        ;; Partition files (cached / within re-parse throttle vs new/changed).
        ;; Mtime comes from the list-files scan (single stat), not a per-file re-stat.
        (dolist (pair pairs)
          (let* ((mtime (car pair))
                 (path (cdr pair))
                 (entry (gethash path decknix--session-meta-cache))
                 (hit (decknix--session-cache-hit entry mtime)))
            (if hit
                (push hit cached-data)
              (push path new-files))))
        (setq new-files (nreverse new-files))
        (if (null new-files)
            ;; Fully warm: assemble from memory, no subprocess.
            (let ((full-list (nreverse cached-data)))
              (puthash provider-id full-list decknix--agent-session-cache-map)
              (puthash provider-id (float-time) decknix--agent-session-cache-time-map)
              (when (eq provider-id 'auggie)
                (setq decknix--agent-session-cache full-list
                      decknix--agent-session-cache-time (float-time))))
          (if (< (length new-files) 20)
              ;; Small new set: parse synchronously (fast per-file jq).
              (let ((new-data (delq nil (mapcar (lambda (f) (decknix--session-parse-file provider-id f))
                                                new-files))))
                (decknix--session-store-parsed provider-id new-data)
                (when new-data (decknix--session-meta-cache-save))
                (let ((full-list (append (nreverse cached-data) new-data)))
                  (puthash provider-id full-list decknix--agent-session-cache-map)
                  (puthash provider-id (float-time) decknix--agent-session-cache-time-map)
                  (when (eq provider-id 'auggie)
                    (setq decknix--agent-session-cache full-list
                          decknix--agent-session-cache-time (float-time)))))
            ;; Large new set (cold cache): spawn a subprocess for parallel jq.
            (let* ((cmd (decknix--agent-session-jq-cmd provider-id))
                   (list-file (make-temp-file (format "agent-%s-files-" provider-id)))
                   (buf (generate-new-buffer (format " *agent-%s-session-list*" provider-id))))
              (with-temp-file list-file
                (dolist (f new-files) (insert f "\n")))
              ;; Re-build cmd with the list file if the jq-cmd doesn't already handle it?
              ;; Actually, jq-cmd uses `ls` or `find`.
              ;; Wait, `decknix--agent-session-jq-cmd` doesn't take a file list.
              ;; I should probably refactor jq-cmd or use the logic from sync.
              (let ((proc (start-process-shell-command (format "agent-%s-session-list" provider-id)
                                                       buf cmd)))
                (puthash provider-id proc decknix--agent-session-refresh-proc-map)
                (when (eq provider-id 'auggie)
                  (setq decknix--agent-session-refresh-proc proc))
                (set-process-sentinel
                 proc
                 ;; Lexical closure captures provider-id, c-data, n-files.
                 ;; n-files is the list of new-or-changed paths fed to the
                 ;; subprocess; it is used to stamp filePath on the parsed
                 ;; results so decknix--session-store-parsed can cache
                 ;; multi-project (claude-code) sessions correctly.
                 (let ((p-id provider-id)
                       (c-data (nreverse cached-data))
                       (n-files new-files))
                   (lambda (proc _event)
                     (when (eq (process-status proc) 'exit)
                       (let ((pbuf (process-buffer proc)))
                         (when (buffer-live-p pbuf)
                           (let ((new-parsed
                                  (decknix--session-stamp-file-paths
                                   (decknix--agent-session-parse
                                    (with-current-buffer pbuf (buffer-string)))
                                   n-files)))
                             (when new-parsed
                               (decknix--session-store-parsed p-id new-parsed)
                               (decknix--session-meta-cache-save)
                               (let ((full-list (append c-data new-parsed)))
                                 (puthash p-id full-list decknix--agent-session-cache-map)
                                 (puthash p-id (float-time) decknix--agent-session-cache-time-map)
                                 (when (eq p-id 'auggie)
                                   (setq decknix--agent-session-cache full-list
                                         decknix--agent-session-cache-time (float-time))))))
                           (kill-buffer pbuf)))))))))))))))

;; ---------------------------------------------------------------------------
;; Public cache read
;; ---------------------------------------------------------------------------

(defun decknix--session-stamp-provider-id (provider-id sessions)
  "Return SESSIONS with (providerId . PROVIDER-ID) ensured on each alist.
The list-refresh parse paths stamp `filePath' but not `providerId'
(only `decknix--session-meta', used by compose-history, does).  Stamping
here — where the provider is known — lets the picker, grep and sidebar
resolve a session's backend (glyph, provider filter) with no per-session
disk probe.  Entries already carrying `providerId' are returned as-is;
others get a fresh cons head, so callers must use the returned list."
  (mapcar (lambda (s)
            (if (or (not (listp s)) (alist-get 'providerId s))
                s
              (cons (cons 'providerId provider-id) s)))
          sessions))

(defun decknix--agent-session-list (&optional provider-id)
  "Return cached sessions.
If PROVIDER-ID is non-nil, return sessions for that provider.
If PROVIDER-ID is nil, return sessions for ALL registered providers,
merged and sorted newest-first.
On first call (empty cache) or after cache invalidation, blocks briefly
for a synchronous mtime-keyed refresh (fast on a warm cache).
Triggers an async mtime-keyed refresh when the cache is stale.

Every returned session carries `providerId' (stamped once via
`decknix--session-stamp-provider-id' and written back) so downstream
callers can render a provider glyph and filter by provider."
  (if provider-id
      (let ((cache (gethash provider-id decknix--agent-session-cache-map))
            (time (or (gethash provider-id decknix--agent-session-cache-time-map) 0)))
        (when (and (null cache) (= time 0))
          (setq cache (decknix--agent-session-refresh-sync provider-id)
                time (gethash provider-id decknix--agent-session-cache-time-map)))
        (when (> (- (float-time) time) decknix--agent-session-cache-ttl)
          (decknix--agent-session-refresh-async provider-id))
        (let ((result (or cache (gethash provider-id decknix--agent-session-cache-map))))
          ;; Ensure providerId is present.  Cheap O(1) check on the head
          ;; (entries are stamped as a batch); stamp + write back once so
          ;; subsequent reads (e.g. per-keystroke grep) are no-ops.
          (when (and result (not (alist-get 'providerId (car result))))
            (setq result (decknix--session-stamp-provider-id provider-id result))
            (puthash provider-id result decknix--agent-session-cache-map))
          result))
    (decknix--agent-session-list-all)))

(defun decknix--agent-session-list-all ()
  "Return combined sessions from all registered providers."
  (let ((all nil))
    (dolist (provider-entry decknix-agent-provider-registry)
      (let ((p-id (car provider-entry)))
        (setq all (append all (decknix--agent-session-list p-id)))))
    ;; Sort combined list newest-first by modified date (ISO-8601).
    (sort all (lambda (a b)
                (let ((ma (alist-get 'modified a))
                      (mb (alist-get 'modified b)))
                  (string> (or ma "") (or mb "")))))))

(defun decknix--agent-session-cache-warm-p (&optional provider-id)
  "Return non-nil if the session cache for PROVIDER-ID is populated.
When PROVIDER-ID is nil, checks if ANY registered provider has a warm cache.
This is a cheap O(1) check that does NOT trigger a synchronous refresh —
use it to guard code that should defer when the cache is cold (e.g.,
background migrations that can wait until the user opens the session picker)."
  (if provider-id
      (> (or (gethash provider-id decknix--agent-session-cache-time-map) 0) 0)
    (catch 'warm
      (dolist (entry decknix-agent-provider-registry)
        (when (> (or (gethash (car entry) decknix--agent-session-cache-time-map) 0) 0)
          (throw 'warm t)))
      nil)))

(defun decknix--agent-session-list-if-warm (&optional provider-id)
  "Return cached sessions if the cache is warm, otherwise nil.
Unlike `decknix--agent-session-list', this NEVER triggers a synchronous
refresh — it returns nil immediately when the cache is cold.  Use this
for background migrations that can defer until the cache warms up naturally."
  (when (decknix--agent-session-cache-warm-p provider-id)
    (if provider-id
        (gethash provider-id decknix--agent-session-cache-map)
      (let ((all nil))
        (dolist (entry decknix-agent-provider-registry)
          (let ((p-id (car entry)))
            (when (gethash p-id decknix--agent-session-cache-map)
              (setq all (append all (gethash p-id decknix--agent-session-cache-map))))))
        (sort all (lambda (a b)
                    (let ((ma (alist-get 'modified a))
                          (mb (alist-get 'modified b)))
                      (string> (or ma "") (or mb "")))))))))

;; ---------------------------------------------------------------------------
;; Provider-id lookup by session-id (Phase 1.3)
;; ---------------------------------------------------------------------------

(defun decknix--agent-provider-for-session-id (session-id)
  "Return the provider-id that owns SESSION-ID, or the default provider.

Resolution is intentionally cheap so the resume path stays fast:

  1. Scan the already-loaded in-memory session caches
     (`decknix--agent-session-cache-map').  Zero I/O; covers the
     warm/common case where the picker or a prior resume has already
     populated the cache for a provider.
  2. Probe each registered provider's on-disk session *file* by path
     existence only -- a `file-exists-p' for single-directory
     providers, a bounded `find ... -print -quit' (via
     `decknix--agent-session-file') for multi-project providers.  No
     transcript parsing happens here.  Providers are probed in
     registry order, so the default (auggie) -- registered first and
     by far the most common -- short-circuits before any expensive
     multi-project `find'.
  3. Fall back to `decknix-agent-default-provider'.

This deliberately does NOT call `decknix--agent-session-list', which
would trigger a synchronous metadata refresh (jq-parsing every
session transcript) for EVERY registered provider.  That all-provider
parse on a cold in-memory cache was the cause of the multi-second
stall observed when resuming sessions after a daemon reload (the
reload re-evaluates the cache defvars, emptying the maps)."
  (or
   ;; 1. In-memory cache scan -- zero I/O.
   (catch 'found
     (dolist (entry decknix-agent-provider-registry)
       (let ((p-id (car entry)))
         (dolist (s (gethash p-id decknix--agent-session-cache-map))
           (when (string= (alist-get 'sessionId s) session-id)
             (throw 'found p-id)))))
     nil)
   ;; 2. On-disk path probe -- no transcript parsing.
   (when (fboundp 'decknix--agent-session-file)
     (catch 'found
       (dolist (entry decknix-agent-provider-registry)
         (let* ((p-id (car entry))
                (file (decknix--agent-session-file session-id p-id)))
           (when (and (stringp file)
                      (not (string-empty-p file))
                      (file-exists-p file))
             (throw 'found p-id))))
       nil))
   ;; 3. Fallback.
   decknix-agent-default-provider))

(provide 'decknix-agent-session-cache)
;;; decknix-agent-session-cache.el ends here
