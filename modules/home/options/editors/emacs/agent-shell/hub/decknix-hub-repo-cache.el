;;; decknix-hub-repo-cache.el --- Repo HEAD status cache + persistence -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, cache, repo

;;; Commentary:
;;
;; Repo HEAD status cache extracted from the agent-shell heredoc.
;; Linked repos (type="repo") don't flow through the hub daemon;
;; the surrounding hub-bulk code fetches their HEAD commit + combined
;; CI state directly via `gh api graphql' and persists the result
;; here, keyed per (OWNER/REPO, branch).
;;
;; This module owns:
;;
;;   `decknix--hub-repo-cache'           hash table of "OWNER/REPO#BRANCH"
;;                                       -> (TIMESTAMP . STATUS-ALIST)
;;   `decknix--hub-repo-cache-ttl'       seconds (default 300 = 5 min)
;;   `decknix--hub-repo-cache-file'      ~/.config/decknix/hub/repo-cache.el
;;   `decknix--hub-repo-pending-fetches' dedupe set for in-flight fetches
;;
;;   `decknix--hub-repo-cache-save'      persist hash to disk
;;   `decknix--hub-repo-cache-restore'   load hash from disk
;;
;; The async fetcher (`decknix--hub-repo-fetch-async') and the
;; cache-reader / status orchestrator (`decknix--hub-repo-cache-get'
;; and `decknix--hub-repo-status') stay in hub-bulk because they
;; call the fetcher, which keeps the orchestration co-resident with
;; the side-effectful subprocess code.
;;
;; Direct parallel to `decknix-hub-pr-cache' (PR B.24) — same shape,
;; same persistence pattern, same per-restart save+restore contract.
;; The two share no code by design; the keys, TTLs, and storage
;; formats are independent so a future refactor can change either
;; one without touching the other.

;;; Code:

(require 'cl-lib)

(defvar decknix--hub-repo-cache (make-hash-table :test 'equal)
  "Cache for repo+branch HEAD status.
Keys are \"OWNER/REPO#BRANCH\"; values are (TIMESTAMP . STATUS-ALIST).")

(defvar decknix--hub-repo-cache-ttl 300
  "Time-to-live in seconds for cached repo+branch lookups.")

(defvar decknix--hub-repo-cache-file
  (expand-file-name "~/.config/decknix/hub/repo-cache.el")
  "File for persisting repo cache across Emacs restarts.")

(defvar decknix--hub-repo-pending-fetches (make-hash-table :test 'equal)
  "Set of repo+branch keys currently being fetched.")

(defun decknix--hub-repo-cache-save ()
  "Persist the repo cache to disk."
  (when (> (hash-table-count decknix--hub-repo-cache) 0)
    (condition-case err
        (let (entries)
          (maphash (lambda (k v) (push (cons k v) entries))
                   decknix--hub-repo-cache)
          (make-directory (file-name-directory
                           decknix--hub-repo-cache-file) t)
          (with-temp-file decknix--hub-repo-cache-file
            (insert ";; Auto-generated repo cache — do not edit\n")
            (prin1 entries (current-buffer))
            (insert "\n")))
      (error
       (message "hub-repo-cache: save failed: %s"
                (error-message-string err))))))

(defun decknix--hub-repo-cache-restore ()
  "Restore the repo cache from disk."
  (when (file-exists-p decknix--hub-repo-cache-file)
    (condition-case err
        (let ((entries (with-temp-buffer
                         (insert-file-contents
                          decknix--hub-repo-cache-file)
                         (read (current-buffer)))))
          (when (listp entries)
            (dolist (entry entries)
              (when (consp entry)
                (puthash (car entry) (cdr entry)
                         decknix--hub-repo-cache)))))
      (error
       (message "hub-repo-cache: restore failed: %s"
                (error-message-string err))))))

(provide 'decknix-hub-repo-cache)
;;; decknix-hub-repo-cache.el ends here
