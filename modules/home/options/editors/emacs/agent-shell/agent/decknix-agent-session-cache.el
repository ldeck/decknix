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

;; Forward declaration: parser lives in sibling `decknix-agent-parse',
;; loaded by the heredoc immediately before this module.
(declare-function decknix--agent-session-parse "decknix-agent-parse" (raw))

;; ---------------------------------------------------------------------------
;; Public state — read/invalidated by sidebar, picker, batch flows
;; ---------------------------------------------------------------------------

(defvar decknix--agent-session-cache nil
  "Cached list of auggie sessions (alists), newest first.")

(defvar decknix--agent-session-cache-time 0
  "Float-time when `decknix--agent-session-cache' was last updated.")

(defvar decknix--agent-session-cache-ttl 120
  "Seconds before the session cache is considered stale.")

(defvar decknix--agent-session-refresh-proc nil
  "Process handle for async session list refresh.")

(defvar decknix--agent-session-cache-max-files 200
  "Maximum number of session JSON files to consider per refresh (newest first).
With 1000+ session files this limits the mtime-diff scan to the most
recently active sessions.  Nil scans all files.")

(defvar decknix--agent-sessions-dir
  (expand-file-name "~/.augment/sessions")
  "Directory containing auggie session JSON files.")

(defvar decknix--agent-session-jq-filter-file nil
  "Path to the temp file containing the jq filter for session extraction.")

;; ---------------------------------------------------------------------------
;; Mtime-keyed metadata cache
;; ---------------------------------------------------------------------------

(defvar decknix--session-meta-cache
  (make-hash-table :test 'equal :size 256)
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

(defun decknix--session-list-files (&optional max)
  "Return absolute session JSON paths sorted newest-first.
When MAX is non-nil, limit to at most MAX files via `head'."
  (let* ((dir (shell-quote-argument decknix--agent-sessions-dir))
         (cmd (if max
                  (concat "ls -t1 " dir "/*.json 2>/dev/null"
                          " | head -" (number-to-string max))
                (concat "ls -t1 " dir "/*.json 2>/dev/null")))
         (out (shell-command-to-string cmd)))
    (split-string (string-trim out) "\n" t)))

(defun decknix--session-parse-file (path)
  "Extract session metadata from PATH with a single jq invocation.
Returns a parsed alist via `decknix--agent-session-parse', or nil."
  (let* ((jqf (decknix--agent-session-ensure-jq-filter))
         (raw (shell-command-to-string
               (concat "jq -Mc -f "
                       (shell-quote-argument jqf)
                       " " (shell-quote-argument path)
                       " 2>/dev/null"))))
    (decknix--agent-session-parse raw)))

(defun decknix--session-meta (path)
  "Return session metadata alist for PATH using the mtime-keyed cache.
Returns cached data when the file's mtime matches the stored entry;
otherwise calls `decknix--session-parse-file' and updates the cache.
Returns nil when PATH does not exist."
  (let* ((mtime (decknix--session-file-mtime path))
         (entry (gethash path decknix--session-meta-cache))
         (cached-mtime (and entry (plist-get entry :mtime))))
    (if (and mtime cached-mtime (= mtime cached-mtime))
        (plist-get entry :data)
      (when mtime
        (let ((data (decknix--session-parse-file path)))
          (when data
            (puthash path (list :mtime mtime :data data)
                     decknix--session-meta-cache)
            data))))))

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
          (let ((entries nil))
            (maphash (lambda (k v) (push (cons k v) entries))
                     decknix--session-meta-cache)
            (pp entries (current-buffer)))
          (write-region (point-min) (point-max)
                        decknix--session-meta-cache-file nil 'quiet)))
    (error (message "decknix-session-meta: save failed: %s" err))))

;; ---------------------------------------------------------------------------
;; jq filter file (shared by per-file and bulk parse paths)
;; ---------------------------------------------------------------------------

(defun decknix--agent-session-ensure-jq-filter ()
  "Write the jq extraction filter to a temp file if not already done.
Returns the path.  Used by both single-file and bulk parse paths."
  (unless (and decknix--agent-session-jq-filter-file
               (file-exists-p decknix--agent-session-jq-filter-file))
    (setq decknix--agent-session-jq-filter-file
          (make-temp-file "auggie-session-" nil ".jq"))
    (with-temp-file decknix--agent-session-jq-filter-file
      ;; Use try//default for chatHistory operations so that files being
      ;; actively written (mid-write parse errors) still produce partial
      ;; results instead of being silently dropped from the session list.
      ;; Skip MCP startup errors when extracting firstUserMessage —
      ;; find the first real user message instead.
      (insert "{sessionId, created, modified,"
              " exchangeCount: (try (.chatHistory | length) // 0),"
              " firstUserMessage:"
              " (try (first(.chatHistory[]"
              " | .exchange.request_message"
              " | select(. != null)"
              " | select(startswith(\"\\u26a0\") | not)"
              " | select(length > 0))[:200])"
              " // \"\")}\n")))
  decknix--agent-session-jq-filter-file)

;; ---------------------------------------------------------------------------
;; Bulk jq command (kept for grep thorough path backward compatibility)
;; ---------------------------------------------------------------------------

(defun decknix--agent-session-jq-cmd ()
  "Shell command to bulk-extract session metadata via parallel jq.
Used by the grep thorough path (C-u C-u C-c A g) and as the cold-cache
fallback when many files need parsing at once.
Scans at most `decknix--agent-session-cache-max-files' newest files."
  (let* ((jqf (decknix--agent-session-ensure-jq-filter))
         (dir (shell-quote-argument decknix--agent-sessions-dir))
         (max decknix--agent-session-cache-max-files)
         (list-cmd (if max
                       (concat "ls -t1 " dir "/*.json 2>/dev/null"
                               " | head -" (number-to-string max))
                     (concat "find " dir
                             " -maxdepth 1 -name '*.json' -print 2>/dev/null"))))
    (concat
     list-cmd
     " | tr '\\n' '\\0'"
     " | xargs -0 -P8 -I{} jq -Mc -f "
     (shell-quote-argument jqf)
     " {} 2>/dev/null"
     " | jq -Msc 'sort_by(.modified) | reverse'")))

;; ---------------------------------------------------------------------------
;; Internal: parse a set of files (small = sequential, large = parallel jq)
;; ---------------------------------------------------------------------------

(defun decknix--session-refresh-parse-files (files)
  "Parse FILES and return a list of session alists.
For small sets (< 20 files) parse sequentially; for larger sets use
parallel jq via a temp file list for speed (cold-cache initial fill)."
  (if (< (length files) 20)
      (delq nil (mapcar #'decknix--session-parse-file files))
    ;; Large set: write paths to a temp file, fan out to parallel jq.
    (let* ((jqf (decknix--agent-session-ensure-jq-filter))
           (list-file (make-temp-file "auggie-files-")))
      (unwind-protect
          (progn
            (with-temp-file list-file
              (dolist (f files) (insert f "\n")))
            (decknix--agent-session-parse
             (shell-command-to-string
              (concat "cat " (shell-quote-argument list-file)
                      " | tr '\\n' '\\0'"
                      " | xargs -0 -P8 -I{} jq -Mc -f "
                      (shell-quote-argument jqf)
                      " {} 2>/dev/null"
                      " | jq -Msc 'sort_by(.modified) | reverse'"))))
        (when (file-exists-p list-file)
          (delete-file list-file))))))

;; Internal helper: update mtime cache entries for a list of parsed alists.
(defun decknix--session-store-parsed (alist-list)
  "Store ALIST-LIST entries in `decknix--session-meta-cache' keyed by path+mtime."
  (dolist (data alist-list)
    (let* ((sid  (alist-get 'sessionId data))
           (path (when sid
                   (expand-file-name (concat sid ".json")
                                     decknix--agent-sessions-dir)))
           (mtime (and path (decknix--session-file-mtime path))))
      (when (and path mtime)
        (puthash path (list :mtime mtime :data data)
                 decknix--session-meta-cache)))))

;; ---------------------------------------------------------------------------
;; Public refresh functions
;; ---------------------------------------------------------------------------

(defun decknix--agent-session-refresh-sync ()
  "Synchronously refresh `decknix--agent-session-cache' using mtime-keyed data.
Files already in the persistent cache cost only a hash lookup; only new
or modified files trigger a jq parse.  The result is sorted newest-first
and the persistent cache is saved if any new entries were written."
  (let* ((files (decknix--session-list-files decknix--agent-session-cache-max-files))
         (cached-data nil)
         (new-files nil))
    ;; Partition: cached (mtime match) vs new/changed.
    (dolist (path files)
      (let* ((mtime (decknix--session-file-mtime path))
             (entry (gethash path decknix--session-meta-cache))
             (cached-mtime (and entry (plist-get entry :mtime))))
        (if (and mtime cached-mtime (= mtime cached-mtime))
            (let ((data (plist-get entry :data)))
              (when data (push data cached-data)))
          (when mtime (push path new-files)))))
    (setq new-files (nreverse new-files))
    (let* ((before (hash-table-count decknix--session-meta-cache))
           (new-data (when new-files
                       (decknix--session-refresh-parse-files new-files))))
      ;; Update mtime cache for newly parsed files and persist.
      (when new-data
        (decknix--session-store-parsed new-data))
      (when (/= (hash-table-count decknix--session-meta-cache) before)
        (decknix--session-meta-cache-save))
      ;; Assemble result: cached (already sorted newest-first by ls -t)
      ;; followed by newly parsed.
      (setq decknix--agent-session-cache
            (append (nreverse cached-data) (or new-data '()))
            decknix--agent-session-cache-time (float-time)))))

(defun decknix--agent-session-refresh-async ()
  "Refresh `decknix--agent-session-cache' without blocking.
On a warm cache (common case) this completes synchronously in < 1 ms
since only file-attribute lookups are needed.  When new files exist,
small sets are parsed synchronously; large sets (cold cache) run jq
in a background subprocess."
  (when (or (null decknix--agent-session-refresh-proc)
            (not (process-live-p decknix--agent-session-refresh-proc)))
    (let* ((files (decknix--session-list-files decknix--agent-session-cache-max-files))
           (cached-data nil)
           (new-files nil))
      ;; Partition files.
      (dolist (path files)
        (let* ((mtime (decknix--session-file-mtime path))
               (entry (gethash path decknix--session-meta-cache))
               (cached-mtime (and entry (plist-get entry :mtime))))
          (if (and mtime cached-mtime (= mtime cached-mtime))
              (let ((data (plist-get entry :data)))
                (when data (push data cached-data)))
            (when mtime (push path new-files)))))
      (setq new-files (nreverse new-files))
      (if (null new-files)
          ;; Fully warm: assemble from memory, no subprocess.
          (setq decknix--agent-session-cache (nreverse cached-data)
                decknix--agent-session-cache-time (float-time))
        (if (< (length new-files) 20)
            ;; Small new set: parse synchronously (fast per-file jq).
            (let ((new-data (delq nil (mapcar #'decknix--session-parse-file new-files))))
              (decknix--session-store-parsed new-data)
              (when new-data (decknix--session-meta-cache-save))
              (setq decknix--agent-session-cache
                    (append (nreverse cached-data) new-data)
                    decknix--agent-session-cache-time (float-time)))
          ;; Large new set (cold cache): spawn a subprocess for parallel jq.
          (let* ((jqf (decknix--agent-session-ensure-jq-filter))
                 (list-file (make-temp-file "auggie-files-"))
                 (cmd nil))
            (with-temp-file list-file
              (dolist (f new-files) (insert f "\n")))
            (setq cmd
                  (concat "cat " (shell-quote-argument list-file)
                          " | tr '\\n' '\\0'"
                          " | xargs -0 -P8 -I{} jq -Mc -f "
                          (shell-quote-argument jqf)
                          " {} 2>/dev/null"
                          " | jq -Msc 'sort_by(.modified) | reverse'"))
            (let ((buf (generate-new-buffer " *auggie-session-list*")))
              (setq decknix--agent-session-refresh-proc
                    (start-process-shell-command "auggie-session-list" buf cmd))
              (set-process-sentinel
               decknix--agent-session-refresh-proc
               ;; Lexical closure captures c-data and list-file.
               (let ((c-data (nreverse cached-data))
                     (lfile list-file))
                 (lambda (proc _event)
                   (when (eq (process-status proc) 'exit)
                     (let ((pbuf (process-buffer proc)))
                       (when (buffer-live-p pbuf)
                         (let ((new-parsed
                                (decknix--agent-session-parse
                                 (with-current-buffer pbuf (buffer-string)))))
                           (when new-parsed
                             (decknix--session-store-parsed new-parsed)
                             (decknix--session-meta-cache-save)
                             (setq decknix--agent-session-cache
                                   (append c-data new-parsed)
                                   decknix--agent-session-cache-time (float-time))))
                         (kill-buffer pbuf)))
                     (when (file-exists-p lfile)
                       (delete-file lfile)))))))))))))

;; ---------------------------------------------------------------------------
;; Public cache read
;; ---------------------------------------------------------------------------

(defun decknix--agent-session-list ()
  "Return cached auggie sessions, refreshing as needed.
On first call (empty cache) or after cache invalidation, blocks briefly
for a synchronous mtime-keyed refresh (fast on a warm cache).
Triggers an async mtime-keyed refresh when the cache is stale."
  (when (and (null decknix--agent-session-cache)
             (= decknix--agent-session-cache-time 0))
    (decknix--agent-session-refresh-sync))
  (when (> (- (float-time) decknix--agent-session-cache-time)
           decknix--agent-session-cache-ttl)
    (decknix--agent-session-refresh-async))
  decknix--agent-session-cache)

(provide 'decknix-agent-session-cache)
;;; decknix-agent-session-cache.el ends here
