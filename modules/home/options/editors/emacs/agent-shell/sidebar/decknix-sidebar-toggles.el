;;; decknix-sidebar-toggles.el --- Sidebar visibility/filter toggles -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, sidebar, tools

;;; Commentary:
;;
;; State variables and `interactive' commands that flip what the
;; agent-shell-workspace sidebar shows: key listing, hidden sessions,
;; live-backed saved rows, unknown-workspace rows, the saved Sessions
;; block as a whole, and a cycling age filter on saved sessions.
;;
;; All toggles guard their refresh call with `fboundp' so the module
;; loads cleanly in batch tests without dragging agent-shell-workspace
;; into the load-path.

;;; Code:

(require 'cl-lib)
;; Shared age-filter presets — Sessions cycle reuses the Requests
;; preset list so labels (`all/1d/3d/7d/14d/30d') stay aligned.
(require 'decknix-hub-age-presets)

;; -- Forward declarations: defined elsewhere in agent-shell config --
(declare-function agent-shell-workspace-sidebar-refresh "ext:agent-shell-workspace")

(defvar decknix--sidebar-show-keys t
  "When non-nil, show categorised key listing in the sidebar footer.
Defaults to t for discoverability; toggle with K.")

(defvar decknix--sidebar-show-hidden nil
  "When non-nil, include hidden/background sessions in the Sessions list.
Hidden sessions are marked via `decknix--agent-conversation-set-hidden'.
Toggle with `H' in the sidebar.")

(defvar decknix--sidebar-sessions-hide-live nil
  "When non-nil, hide saved sessions whose conversation is currently live.
Default nil so live-backed conversations appear dimmed as context
without competing with the Live section above.  Toggle with `V'
in the Toggles transient.")

(defvar decknix--sidebar-sessions-age-filter nil
  "Age cutoff in seconds for saved Sessions list; nil = no limit.
Cycles through the same presets as Requests
(`decknix--hub-age-presets').  Toggle with `a' in the Toggles
transient.")

(defvar decknix--sidebar-sessions-hide-unknown nil
  "When non-nil, hide saved sessions whose workspace can't be resolved.
These render under the \"unknown\" workspace group today.  Toggle
with `U' in the Toggles transient.")

(defvar decknix--hub-show-saved-sessions t
  "When non-nil (default), the saved Sessions block is rendered.
When nil, the entire Saved Sessions section (heading + per-workspace
groups) is omitted from the sidebar.  Live, Previous, Requests and
WIP sections remain unaffected.  Toggle with `h' in the Toggles
transient.")

(defun decknix--sidebar-sessions-age-label ()
  "Return a short label for the current sessions age filter.
Reuses the shared `decknix--hub-age-presets' alist so the Sessions
and Requests age toggles share vocabulary."
  (or (and (boundp 'decknix--hub-age-presets)
           (alist-get decknix--sidebar-sessions-age-filter
                      decknix--hub-age-presets))
      "all"))

(defun decknix-sidebar-toggle-keys ()
  "Toggle the inline key listing in the sidebar footer."
  (interactive)
  (setq decknix--sidebar-show-keys (not decknix--sidebar-show-keys))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh)))

(defun decknix-sidebar-toggle-hidden ()
  "Toggle visibility of hidden/background sessions in the sidebar."
  (interactive)
  (setq decknix--sidebar-show-hidden (not decknix--sidebar-show-hidden))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Hidden sessions: %s"
           (if decknix--sidebar-show-hidden "shown" "hidden")))

(defun decknix-sidebar-toggle-sessions-hide-live ()
  "Toggle whether live-backed saved sessions are hidden in the sidebar.
When off (default), live-backed conversations render dimmed as
recent context.  When on, they are filtered out entirely (the
Live section above is then the only place they appear)."
  (interactive)
  (setq decknix--sidebar-sessions-hide-live
        (not decknix--sidebar-sessions-hide-live))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Sessions: live-backed rows %s"
           (if decknix--sidebar-sessions-hide-live "hidden" "dimmed")))

(defun decknix-sidebar-toggle-sessions-hide-unknown ()
  "Toggle whether sessions with unresolved workspace are hidden."
  (interactive)
  (setq decknix--sidebar-sessions-hide-unknown
        (not decknix--sidebar-sessions-hide-unknown))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Sessions: unknown-workspace rows %s"
           (if decknix--sidebar-sessions-hide-unknown "hidden" "shown")))

(defun decknix-sidebar-toggle-saved-sessions ()
  "Toggle visibility of the saved Sessions section in the sidebar."
  (interactive)
  (setq decknix--hub-show-saved-sessions
        (not decknix--hub-show-saved-sessions))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Saved Sessions: %s"
           (if decknix--hub-show-saved-sessions "shown" "hidden")))

(defun decknix-sidebar-cycle-sessions-age-filter ()
  "Cycle the saved-Sessions age filter through presets.
Reuses `decknix--hub-age-presets' so the Sessions and Requests age
toggles share vocabulary (all/1d/3d/7d/14d/30d)."
  (interactive)
  (let* ((presets (if (boundp 'decknix--hub-age-presets)
                      decknix--hub-age-presets
                    '((nil . "all"))))
         (keys (mapcar #'car presets))
         (pos (cl-position decknix--sidebar-sessions-age-filter
                           keys :test #'equal))
         (next-pos (mod (1+ (or pos 0)) (length keys))))
    (setq decknix--sidebar-sessions-age-filter (nth next-pos keys))
    (when (fboundp 'agent-shell-workspace-sidebar-refresh)
      (agent-shell-workspace-sidebar-refresh))
    (message "Sessions age filter: %s"
             (decknix--sidebar-sessions-age-label))))

(provide 'decknix-sidebar-toggles)
;;; decknix-sidebar-toggles.el ends here
