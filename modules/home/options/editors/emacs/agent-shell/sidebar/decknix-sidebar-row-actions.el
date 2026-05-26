;;; decknix-sidebar-row-actions.el --- Sidebar row-level action commands -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, sidebar, tools

;;; Commentary:
;;
;; Interactive `at-point' commands invoked on individual saved-session
;; rows in the agent-shell-workspace sidebar.  Today: hide / un-hide
;; and delete the session under point.
;;
;; Hide / un-hide commands read the `decknix-sidebar-saved-conv-key'
;; text property at the start of the current line, mutate the
;; conversation hidden flag via `decknix--agent-conversation-set-hidden',
;; and refresh the sidebar.  When point is not on a saved-session row
;; (no conv-key property), each command echoes "No saved session at
;; point" and is a no-op.
;;
;; The `agent-shell-workspace-sidebar-delete-killed' command (requested
;; by NC-141) provides a robust way to permanently remove a session.
;; It handles both "Saved Sessions" (via `decknix-sidebar-saved-session'
;; / `*-saved-conv-key' properties) and "Previous Sessions" (via
;; `decknix-previous-session' alist property).  It:
;;   1. Confirms destruction with the user.
;;   2. Calls `decknix--session-delete-by-id' which:
;;        a. Deletes the JSON file in `~/.augment/sessions/'.
;;        b. Removes the conversation and bookmark from the tags store.
;;        c. Removes the entry from `decknix--sidebar-previous-sessions'.
;;        d. Forgets the session from the live-sessions file.
;;        e. Invalidates the metadata cache.
;;   3. Refreshes the sidebar and shows a confirmation message.
;;
;; `decknix--session-delete-by-id (sid conv-key)' is the shared
;; no-UI core used by both the sidebar command above and the session
;; picker's C-d (delete) key action.  It performs all filesystem /
;; metadata mutations without any prompting or refreshing.
;;
;; All calls into the heredoc-side world are guarded with `fboundp'
;; so this module loads cleanly in batch tests without dragging
;; agent-shell-workspace into the load-path.

;;; Code:

(require 'cl-lib)
(require 'seq)

;; -- Forward declarations: defined elsewhere in agent-shell config --
(declare-function agent-shell-workspace-sidebar-refresh "ext:agent-shell-workspace")
(declare-function agent-shell-workspace-sidebar--buffer-at-point "ext:agent-shell-workspace")
(declare-function decknix--agent-conversation-set-hidden "ext:decknix-agent")
(declare-function decknix--agent-session-file "ext:decknix-agent-session-history")
(declare-function decknix--agent-tags-read "ext:decknix-agent-tags-store")
(declare-function decknix--agent-tags-write "ext:decknix-agent-tags-store" (store))
(declare-function decknix--agent-tags-conversations "ext:decknix-agent-tags-store" (store))
(declare-function decknix--live-sessions-forget "ext:decknix-agent-live-sessions" (conv-key sid))

(defvar decknix--sidebar-previous-sessions)
(defvar decknix--agent-session-cache)
(defvar decknix--agent-session-cache-time)

(defun decknix--session-delete-by-id (sid conv-key)
  "Permanently delete session SID (conversation key CONV-KEY).
Removes the JSON history file from `~/.augment/sessions/', clears the
conversation and bookmark entries from the tags store, removes the
entry from `decknix--sidebar-previous-sessions', forgets the session
from the live-sessions file, and invalidates the session metadata cache.
Does NOT prompt for confirmation, show messages, or refresh the sidebar
— callers are responsible for all three."
  ;; 1. Delete JSON file
  (let ((file (when (fboundp 'decknix--agent-session-file)
                (decknix--agent-session-file sid))))
    (if (and file (file-exists-p file))
        (delete-file file)
      (when file (message "Warning: session file %s not found" file))))
  ;; 2. Remove from tags store (conversation and bookmark)
  (when (fboundp 'decknix--agent-tags-read)
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (bookmarks (gethash "bookmarks" store)))
      (when conv-key (remhash conv-key convs))
      (when (and sid bookmarks) (remhash sid bookmarks))
      (decknix--agent-tags-write store)))
  ;; 3. Remove from Previous list
  (when (boundp 'decknix--sidebar-previous-sessions)
    (setq decknix--sidebar-previous-sessions
          (seq-filter (lambda (e)
                        (not (string= (alist-get 'session-id e) sid)))
                      decknix--sidebar-previous-sessions)))
  ;; 4. Forget from live-sessions file
  (when (and conv-key (fboundp 'decknix--live-sessions-forget))
    (decknix--live-sessions-forget conv-key sid))
  ;; 5. Invalidate metadata cache
  (when (boundp 'decknix--agent-session-cache)
    (setq decknix--agent-session-cache nil
          decknix--agent-session-cache-time 0)))

(defun agent-shell-workspace-sidebar-delete-killed ()
  "Delete the killed/saved session at point from disk and metadata.
Prompts for confirmation before permanently removing the session JSON
file in `~/.augment/sessions/', the conversation entry in
`agent-sessions.json', tags and bookmarks, and the Previous Sessions
list entry.  Aborts if the session is live (has an active buffer).
The actual filesystem/metadata work is delegated to
`decknix--session-delete-by-id'."
  (interactive)
  (let* ((saved-id (get-text-property (line-beginning-position) 'decknix-sidebar-saved-session))
         (saved-key (get-text-property (line-beginning-position) 'decknix-sidebar-saved-conv-key))
         (prev (get-text-property (line-beginning-position) 'decknix-previous-session))
         (sid (or saved-id (alist-get 'session-id prev)))
         (conv-key (or saved-key (alist-get 'conv-key prev)))
         (live (or (get-text-property (line-beginning-position) 'decknix-sidebar-saved-live)
                   (and (fboundp 'agent-shell-workspace-sidebar--buffer-at-point)
                        (agent-shell-workspace-sidebar--buffer-at-point)))))
    (cond
     ((not sid)
      (message "No saved/previous session at point"))
     (live
      (user-error "Cannot delete a live session — kill the buffer first"))
     ((yes-or-no-p (format "Permanently delete session %s and its history? "
                           (substring sid 0 (min 8 (length sid)))))
      (decknix--session-delete-by-id sid conv-key)
      (when (fboundp 'agent-shell-workspace-sidebar-refresh)
        (agent-shell-workspace-sidebar-refresh))
      (message "Session %s deleted" (substring sid 0 (min 8 (length sid))))))))

(defun decknix-sidebar-hide-at-point ()
  "Mark the saved session at point as hidden (background/automated).
The session will be excluded from the Sessions list unless `H' toggle is on."
  (interactive)
  (let ((conv-key (get-text-property
                   (line-beginning-position)
                   'decknix-sidebar-saved-conv-key)))
    (if conv-key
        (progn
          (decknix--agent-conversation-set-hidden conv-key t)
          (when (fboundp 'agent-shell-workspace-sidebar-refresh)
            (agent-shell-workspace-sidebar-refresh))
          (message "Session hidden — press H to show hidden sessions"))
      (message "No saved session at point"))))

(defun decknix-sidebar-unhide-at-point ()
  "Un-hide the saved session at point (make visible again)."
  (interactive)
  (let ((conv-key (get-text-property
                   (line-beginning-position)
                   'decknix-sidebar-saved-conv-key)))
    (if conv-key
        (progn
          (decknix--agent-conversation-set-hidden conv-key nil)
          (when (fboundp 'agent-shell-workspace-sidebar-refresh)
            (agent-shell-workspace-sidebar-refresh))
          (message "Session un-hidden"))
      (message "No saved session at point"))))

(provide 'decknix-sidebar-row-actions)
;;; decknix-sidebar-row-actions.el ends here
