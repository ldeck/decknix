;;; decknix-hub-cache-write.el --- Write a cache file only when it changed -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: decknix, hub, cache, performance

;;; Commentary:
;;
;; The hub's PR, repo and worktree caches were each flushed on a 120 s
;; `run-with-timer' by printing the whole hash into `with-temp-file',
;; whether or not anything had changed since the last flush.  On a busy
;; disk that write is the slow part (21 s observed for the worktree
;; cache, ~15 min when the disk was full), and it ran on the main
;; thread, so a cache nobody had touched still froze typing every two
;; minutes.
;;
;; `decknix-hub-cache-write' prints the data, compares a digest of the
;; text against the digest it last wrote to the same file, and returns
;; without touching the disk when they match.  Printing and hashing an
;; in-memory alist costs milliseconds; the write is what it saves.
;; When the data did change, it is written to a temporary file in the
;; same directory and renamed over the target, so a reader (or a crash
;; mid-write) never sees half a file.

;;; Code:

(require 'decknix-state-io)

(defvar decknix--hub-cache-write-digests (make-hash-table :test 'equal)
  "Absolute cache FILE -> SHA-1 of the text last written there.")

(defun decknix--hub-cache-write-text (header data)
  "Return the file text for HEADER (a string, may be nil) and DATA.  Pure."
  (concat (or header "") (decknix-state-io-to-string data) "\n"))

(defun decknix-hub-cache-write-string (file text &optional force)
  "Write TEXT to FILE, but only when it differs from the last write there.

Returns non-nil when FILE was written, nil when TEXT matched the last
write to FILE and FILE still exists.  FORCE writes regardless.  The write
goes to a temporary sibling that is then renamed over FILE, so FILE is
always either the old content or the new, never a partial one."
  (let* ((file (expand-file-name file))
         (digest (secure-hash 'sha1 text)))
    (unless (and (not force)
                 (equal digest (gethash file decknix--hub-cache-write-digests))
                 (file-exists-p file))
      (let ((dir (file-name-directory file)))
        (make-directory dir t)
        (let ((tmp (make-temp-file (expand-file-name ".cache-write-" dir))))
          (condition-case err
              (let ((coding-system-for-write 'utf-8-unix)
                    (write-region-inhibit-fsync t))
                (write-region text nil tmp nil 'silent)
                (rename-file tmp file t))
            (error (ignore-errors (delete-file tmp))
                   (signal (car err) (cdr err))))))
      (puthash file digest decknix--hub-cache-write-digests)
      t)))

(defun decknix-hub-cache-write (file header data &optional force)
  "Write HEADER and printed DATA to FILE, but only when that text changed.
See `decknix-hub-cache-write-string' for the return value, FORCE and the
atomic replace."
  (decknix-hub-cache-write-string
   file (decknix--hub-cache-write-text header data) force))

(provide 'decknix-hub-cache-write)
;;; decknix-hub-cache-write.el ends here
