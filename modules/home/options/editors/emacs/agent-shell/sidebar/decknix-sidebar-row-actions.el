;;; decknix-sidebar-row-actions.el --- Sidebar row-level action commands -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, sidebar, tools

;;; Commentary:
;;
;; Interactive `at-point' commands invoked on individual saved-session
;; rows in the agent-shell-workspace sidebar.  Today: hide / un-hide
;; the session under point.
;;
;; Each command reads the `decknix-sidebar-saved-conv-key' text
;; property at the start of the current line, mutates the conversation
;; hidden flag via `decknix--agent-conversation-set-hidden', and
;; refreshes the sidebar.  When point is not on a saved-session row
;; (no conv-key property), each command echoes "No saved session at
;; point" and is a no-op.
;;
;; Both calls into the heredoc-side world are guarded with `fboundp'
;; so this module loads cleanly in batch tests without dragging
;; agent-shell-workspace into the load-path.

;;; Code:

;; -- Forward declarations: defined elsewhere in agent-shell config --
(declare-function agent-shell-workspace-sidebar-refresh "ext:agent-shell-workspace")
(declare-function decknix--agent-conversation-set-hidden "ext:decknix-agent")

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
