;;; decknix-agent-review-followup-io.el --- Follow-up stash JSON persistence -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, review, followup, persistence

;;; Commentary:
;;
;; The follow-up stash is a flat JSON list at
;; `~/.config/decknix/review-followups.json' written by
;; `decknix-agent-review-mode' when the user flags a paragraph with
;; `C-c C-f'.  Each entry is an alist with keys: id, ts, session,
;; workspace, author, title, body, route ("local"|"github"|"jira"),
;; status ("open"|"done").
;;
;; This module owns the storage layer:
;;
;;   `decknix-agent-review-followups-file'
;;       User-tunable path to the stash JSON.  Defaults to
;;       `~/.config/decknix/review-followups.json'.
;;
;;   `decknix--agent-review-followups-read'
;;       Returns the parsed list (or nil for missing/corrupt files;
;;       parse errors are reported via `message' so the calling
;;       command can still proceed with an empty stash).
;;
;;   `decknix--agent-review-followups-write'
;;       Writes ITEMS atomically via `with-temp-file', creating the
;;       parent directory on demand.  Trailing newline preserved so
;;       diff-based tooling stays well-behaved.
;;
;;   `decknix--agent-review-followup-set-status'
;;       Read-modify-write: walks the stash, replaces the matching
;;       entry's `status' cell, persists.
;;
;;   `decknix--agent-review-followup-delete'
;;       Read-filter-write after `yes-or-no-p' confirm.  No-op if
;;       the user declines.
;;
;; The pure formatters (`-followup-id', `-followup-describe') live
;; in the sibling `decknix-agent-review-followup-format' package.
;; The interactive commands that compose these helpers (`-flag-
;; followup', `-list-followups') stay in `decknix-agent-shell-main'
;; alongside the other review-mode commands.

;;; Code:

(require 'json)
(require 'seq)

(defvar decknix-agent-review-followups-file
  (expand-file-name "~/.config/decknix/review-followups.json")
  "JSON file storing follow-ups flagged during review sessions.
A list of objects with keys: id, ts, session, workspace, author,
title, body, route (\"local\"|\"github\"|\"jira\"), status
(\"open\"|\"done\").")

(defun decknix--agent-review-followups-read ()
  "Return the current follow-ups list (may be empty)."
  (let ((f decknix-agent-review-followups-file))
    (if (file-exists-p f)
        (condition-case err
            (let ((json-array-type 'list)
                  (json-object-type 'alist)
                  (json-key-type 'symbol))
              (json-read-file f))
          (error
           (message "review-followups: failed to read %s — %s"
                    f (error-message-string err))
           nil))
      nil)))

(defun decknix--agent-review-followups-write (items)
  "Persist ITEMS to `decknix-agent-review-followups-file'."
  (let ((f decknix-agent-review-followups-file))
    (make-directory (file-name-directory f) t)
    (with-temp-file f
      (insert (json-encode items))
      (insert "\n"))))

(defun decknix--agent-review-followup-set-status (entry status)
  "Update ENTRY's status to STATUS and persist."
  (let* ((id (alist-get 'id entry))
         (items (decknix--agent-review-followups-read))
         (updated
          (mapcar
           (lambda (e)
             (if (string= (alist-get 'id e) id)
                 (cons (cons 'status status)
                       (assq-delete-all 'status (copy-sequence e)))
               e))
           items)))
    (decknix--agent-review-followups-write updated)
    (message "Follow-up %s → %s" id status)))

(defun decknix--agent-review-followup-delete (entry)
  "Remove ENTRY from the stash (after confirm)."
  (when (yes-or-no-p (format "Delete follow-up %s? "
                             (alist-get 'id entry)))
    (let* ((id (alist-get 'id entry))
           (items (decknix--agent-review-followups-read))
           (filtered (seq-remove
                      (lambda (e) (string= (alist-get 'id e) id))
                      items)))
      (decknix--agent-review-followups-write filtered)
      (message "Deleted follow-up %s" id))))

(provide 'decknix-agent-review-followup-io)
;;; decknix-agent-review-followup-io.el ends here
