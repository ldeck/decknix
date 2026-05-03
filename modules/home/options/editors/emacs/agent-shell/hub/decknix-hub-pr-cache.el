;;; decknix-hub-pr-cache.el --- Hub PR status cache + persistence -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, pr, cache

;;; Commentary:
;;
;; In-process PR status cache for hub-rendered rows.  The hub daemon
;; polls a curated list of PRs (Requests + WIP) and writes their state
;; to JSON files under `~/.config/decknix/hub/'; the heredoc-resident
;; orchestrator (`decknix--hub-pr-status' in
;; `agent-shell/hub-bulk/decknix-agent-shell-hub.el') queries the
;; daemon's data first and falls back to per-PR `gh pr view' fetches
;; for anything the daemon hasn't seen — those fetches land here.
;;
;; This module owns:
;;
;;   `decknix--hub-pr-cache'             — the URL -> (TS . STATUS-ALIST)
;;                                          hash table itself
;;   `decknix--hub-pr-cache-ttl'         — staleness threshold (180 s)
;;   `decknix--hub-pr-cache-orphan-ttl'  — short TTL for PRs that just
;;                                          dropped off the hub data
;;   `decknix--hub-pr-cache-file'        — persistence path
;;   `decknix--hub-pr-pending-fetches'   — in-flight URL -> proc map
;;   `decknix--hub-pr-cache-save'        — flush hash to disk
;;   `decknix--hub-pr-cache-restore'     — repopulate hash from disk
;;
;; Persistence is atomic-ish: write the entire alist in one
;; `with-temp-file' so a partial write can never leave the cache file
;; in a half-readable state.  Both save and restore wrap their I/O in
;; `condition-case' and downgrade failures to a `message' so a corrupt
;; cache file never prevents the daemon / sidebar from starting.
;;
;; Reader (`decknix--hub-pr-cache-get') and the async fetcher
;; (`decknix--hub-pr-fetch-async') stay in their existing homes:
;; cache-get lives in `decknix-hub-pr-lookup' (pure data accessor),
;; the async fetcher lives in `decknix-agent-shell-hub' (orchestrates
;; the `gh pr view' subprocess and refreshes the sidebar on completion).

;;; Code:

(require 'cl-lib)

(defvar decknix--hub-pr-cache (make-hash-table :test 'equal)
  "Cache for PR status looked up via `gh pr view'.
Keys are PR URLs; values are (TIMESTAMP . STATUS-ALIST).")

(defvar decknix--hub-pr-cache-ttl 180
  "Time-to-live in seconds for cached PR lookups (default 3 min).
Used for cache-only renders where a stale entry should still be shown
to the user but a background refresh is desirable.  Kept conservative
to bound `gh pr view' invocations across many linked PRs.")

(defvar decknix--hub-pr-cache-orphan-ttl 30
  "Refresh interval for PRs that just dropped off the hub.
When `decknix--hub-pr-status' finds no entry in the hub WIP/Reviews
data but has a non-terminal cached state, the PR has most likely
merged or closed since the last hub poll.  This shorter TTL is used
in that path so the columnar state catches up to GitHub within a
single hub cycle (~60s) instead of waiting for the global TTL.")

(defvar decknix--hub-pr-cache-file
  (expand-file-name "~/.config/decknix/hub/pr-cache.el")
  "File for persisting PR cache across Emacs restarts.")

(defvar decknix--hub-pr-pending-fetches (make-hash-table :test 'equal)
  "Set of PR URLs currently being fetched (to avoid duplicate requests).")

(defun decknix--hub-pr-cache-save ()
  "Persist the PR cache to disk for fast restoration on restart."
  (when (> (hash-table-count decknix--hub-pr-cache) 0)
    (condition-case err
        (let ((entries nil))
          (maphash (lambda (url val)
                     (push (cons url val) entries))
                   decknix--hub-pr-cache)
          (make-directory (file-name-directory decknix--hub-pr-cache-file) t)
          (with-temp-file decknix--hub-pr-cache-file
            (insert ";; Auto-generated PR cache — do not edit\n")
            (prin1 entries (current-buffer))
            (insert "\n")))
      (error
       (message "hub-pr-cache: save failed: %s"
                (error-message-string err))))))

(defun decknix--hub-pr-cache-restore ()
  "Restore the PR cache from disk.
Entries are loaded with their original timestamps so TTL expiry
still applies.  For entries older than TTL, they are kept as stale
data (available via `decknix--hub-pr-cache-get-stale') but an async
refresh is triggered."
  (when (file-exists-p decknix--hub-pr-cache-file)
    (condition-case err
        (let ((entries (with-temp-buffer
                         (insert-file-contents
                          decknix--hub-pr-cache-file)
                         (read (current-buffer)))))
          (when (listp entries)
            (dolist (entry entries)
              (when (consp entry)
                (puthash (car entry) (cdr entry) decknix--hub-pr-cache)))))
      (error
       (message "hub-pr-cache: restore failed: %s"
                (error-message-string err))))))

(provide 'decknix-hub-pr-cache)
;;; decknix-hub-pr-cache.el ends here
