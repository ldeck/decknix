;;; decknix-ship-progress.el --- Read the progress records /ship writes -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-ship "0.1"))
;; Keywords: agent, deploy

;;; Commentary:
;;
;; A ship workflow (the /ship command, or anything else) records how far a
;; PR has got in `~/.local/state/decknix/ship/<owner>-<repo>-<number>.json':
;;
;;   {"repo": "owner/repo", "number": 12, "stage": "us-stg",
;;    "status": "verified", "verified_at": "2026-11-19T01:02:03Z"}
;;
;; `status' is `promoting', `verified', `failed' or `done'.  The record is
;; what someone actually verified, so `decknix-ship-status' prefers it to
;; the deploy feeds.
;;
;; The directory is watched; a change re-reads only that file (a few hundred
;; bytes) in the watcher callback, bumps `decknix-ship-progress-generation'
;; and asks for a coalesced repaint.  Nothing here runs on the paint path:
;; lookups are a hash read.

;;; Code:

(require 'decknix-ship)
(require 'filenotify)
(require 'json)

(declare-function decknix--sidebar-schedule-paint "decknix-hub-sidebar-paint" (fn))
(declare-function decknix--sidebar-paint-tick "decknix-hub-sidebar-paint" ())

(defvar decknix-ship-progress-dir
  (expand-file-name "~/.local/state/decknix/ship/")
  "Directory of per-PR ship progress records.")

(defvar decknix-ship-progress--records (make-hash-table :test 'equal)
  "\"owner/repo#N\" (lower case) -> progress alist.")

(defvar decknix-ship-progress--watch nil
  "File-notify descriptor for `decknix-ship-progress-dir'.")

(defun decknix-ship-progress-key (repo number)
  "Return the record key for REPO and NUMBER."
  (downcase (format "%s#%s" repo number)))

(defun decknix-ship-progress-parse (text)
  "Return the progress alist in TEXT, or nil when it is not a valid record."
  (let ((rec (ignore-errors
               (json-parse-string text :object-type 'alist :null-object nil
                                  :false-object nil))))
    (and (consp rec)
         (stringp (alist-get 'repo rec))
         (integerp (alist-get 'number rec))
         (stringp (alist-get 'stage rec))
         rec)))

(defun decknix-ship-progress--read-file (file)
  "Read FILE into the record table; drop its record when FILE is gone."
  (let* ((rec (and (file-readable-p file)
                   (decknix-ship-progress-parse
                    (with-temp-buffer
                      (insert-file-contents file)
                      (buffer-string))))))
    (if rec
        (puthash (decknix-ship-progress-key (alist-get 'repo rec) (alist-get 'number rec))
                 (cons file rec) decknix-ship-progress--records)
      (maphash (lambda (k v) (when (equal (car v) file)
                               (remhash k decknix-ship-progress--records)))
               decknix-ship-progress--records))))

(defun decknix-ship-progress-lookup (repo number)
  "Return the /ship progress record for REPO#NUMBER, or nil.  No I/O."
  (cdr (gethash (decknix-ship-progress-key repo number) decknix-ship-progress--records)))

(defun decknix-ship-progress--changed ()
  "Note that a record changed and ask for a repaint."
  (setq decknix-ship-progress-generation (1+ decknix-ship-progress-generation))
  (when (fboundp 'decknix--sidebar-schedule-paint)
    (decknix--sidebar-schedule-paint #'decknix--sidebar-paint-tick)))

(defun decknix-ship-progress--on-event (event)
  "Handle file-notify EVENT for the progress directory."
  (let ((file (nth 2 event)))
    (when (and (stringp file) (string-suffix-p ".json" file))
      (decknix-ship-progress--read-file file)
      (decknix-ship-progress--changed))))

(defun decknix-ship-progress-load-all ()
  "Read every record in `decknix-ship-progress-dir'."
  (clrhash decknix-ship-progress--records)
  (when (file-directory-p decknix-ship-progress-dir)
    (dolist (f (directory-files decknix-ship-progress-dir t "\\.json\\'"))
      (decknix-ship-progress--read-file f)))
  (decknix-ship-progress--changed))

(defun decknix-ship-progress-start ()
  "Load the records and watch for new ones; idempotent."
  (make-directory decknix-ship-progress-dir t)
  (setq decknix-ship-progress-function #'decknix-ship-progress-lookup)
  (decknix-ship-progress-load-all)
  (unless decknix-ship-progress--watch
    (setq decknix-ship-progress--watch
          (ignore-errors
            (file-notify-add-watch decknix-ship-progress-dir '(change)
                                   #'decknix-ship-progress--on-event)))))

(provide 'decknix-ship-progress)
;;; decknix-ship-progress.el ends here
