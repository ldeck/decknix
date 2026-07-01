;;; decknix-hub-path-facts.el --- Cached filesystem facts for sidebar render -*- lexical-binding: t -*-

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;;
;; The 2-second workspace-sidebar render used to call `file-equal-p',
;; `file-truename', `file-exists-p' and `file-attributes' per hub row --
;; synchronous disk stats + symlink resolution on the MAIN THREAD.  When
;; any path is a cold iCloud-backed / removed-worktree path a single
;; stat blocks input for seconds (the "type, nothing happens, then it
;; all catches up" freeze).
;;
;; This module moves every such probe OFF the render tick.  A background
;; idle worker (`decknix--hub-path-facts-refresh', cooperative -- it
;; yields the moment input is pending) canonicalises paths and records
;; existence + mtime into `decknix--hub-path-facts'.  The render path
;; then reads ONLY the cache via the pure `decknix--hub-path-equal-p'
;; and `decknix--hub-path-mtime' accessors, which fall back to a
;; disk-free `expand-file-name' comparison when a path has not been
;; probed yet.  Net effect: the render tick performs zero filesystem
;; I/O, so it can never block on a slow stat.

;;; Code:

(defvar decknix--hub-path-facts (make-hash-table :test 'equal)
  "Cache: canonical PATH key -> plist (:truename :exists :mtime :ts).
Populated OFF the main thread by `decknix--hub-path-facts-refresh';
read on the render path by the pure `decknix--hub-path-*' accessors.")

(defvar decknix-hub-path-facts-ttl 10.0
  "Seconds a cached path-fact entry stays fresh before a re-probe.")

(defun decknix--hub-path-key (path)
  "Return the canonical hash key for PATH (expanded, no trailing slash).
Pure -- string manipulation only, never touches the filesystem."
  (directory-file-name (expand-file-name path)))

(defun decknix--hub-path-facts-clear ()
  "Drop every cached path fact (used by tests + on registry reset)."
  (clrhash decknix--hub-path-facts))

(defun decknix--hub-path-facts-put (path &optional force)
  "Probe PATH on disk and store its facts; skip when still fresh.
With FORCE non-nil re-probe even a fresh entry.  This is the ONLY
function here that touches the filesystem, so it must run off the
render tick (idle worker / async sentinel)."
  (let* ((key (decknix--hub-path-key path))
         (cur (gethash key decknix--hub-path-facts))
         (ts (and cur (plist-get cur :ts))))
    (if (and (not force) ts
             (< (- (float-time) ts) decknix-hub-path-facts-ttl))
        cur
      (let* ((exists (file-exists-p key))
             (tn (directory-file-name (file-truename key)))
             (mtime (and exists
                         (file-attribute-modification-time
                          (file-attributes key)))))
        (puthash key
                 (list :truename tn :exists exists
                       :mtime mtime :ts (float-time))
                 decknix--hub-path-facts)))))

(defun decknix--hub-path-facts-refresh (paths &optional force)
  "Probe each of PATHS into the cache, yielding on pending input.
Cooperative: returns early (leaving the rest for the next idle
tick) as soon as `input-pending-p' reports the user has resumed
typing, so a cold-iCloud stat storm can never hold the main thread
for more than a single path.  FORCE re-probes fresh entries."
  (catch 'decknix--hub-path-facts-yield
    (dolist (p paths)
      (when (input-pending-p)
        (throw 'decknix--hub-path-facts-yield nil))
      (when (and p (stringp p))
        (ignore-errors (decknix--hub-path-facts-put p force))))))

(defun decknix--hub-path-truename (path)
  "Return the cached truename for PATH, or a disk-free fallback.
Never touches the filesystem: when PATH has not been probed yet the
fallback is the expanded, slash-normalised path, which is correct
for the common (non-symlinked, already-absolute) case and
self-corrects once the idle worker records the real truename."
  (and path
       (let ((facts (gethash (decknix--hub-path-key path)
                             decknix--hub-path-facts)))
         (or (and facts (plist-get facts :truename))
             (decknix--hub-path-key path)))))

(defun decknix--hub-path-equal-p (a b)
  "Return non-nil when paths A and B resolve to the same location.
Disk-free replacement for `file-equal-p' on the render path -- it
compares cached truenames (falling back to expanded paths)."
  (and a b
       (string= (decknix--hub-path-truename a)
                (decknix--hub-path-truename b))))

(defun decknix--hub-path-mtime (path)
  "Return the cached modification time for PATH, or nil.
Nil when PATH is unknown to the cache or does not exist -- callers
treat nil as \"age unknown\" (rendered `?') rather than blocking to
find out."
  (and path
       (let ((facts (gethash (decknix--hub-path-key path)
                             decknix--hub-path-facts)))
         (and facts (plist-get facts :exists)
              (plist-get facts :mtime)))))

(provide 'decknix-hub-path-facts)
;;; decknix-hub-path-facts.el ends here
