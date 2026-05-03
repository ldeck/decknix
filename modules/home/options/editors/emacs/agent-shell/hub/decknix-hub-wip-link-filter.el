;;; decknix-hub-wip-link-filter.el --- WIP "hide linked" toggle -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, ui

;;; Commentary:
;;
;; WIP de-dupe toggle carved out of the agent-shell hub heredoc.
;; When non-nil (the default), PRs that are already live as an
;; agent-shell session are hidden from the sidebar's WIP section
;; -- the rationale being that a live session makes the WIP row
;; redundant noise.  Flipping the toggle off shows every WIP PR
;; regardless of session linkage, which is occasionally useful
;; when you need a complete picture of in-flight work.
;;
;; Two entry points:
;;
;;   `decknix--hub-wip-hide-linked'
;;       Defvar holding the current toggle state.  Read by the
;;       WIP renderer in hub-bulk (line ~2590) and by the footer
;;       toggle label in workspace-bulk; both call sites keep
;;       their existing forward declarations.
;;   `decknix--hub-toggle-wip-hide-linked'
;;       Interactive toggle bound to the `L' suffix in the WIP
;;       section of the sidebar Toggles transient (`T' menu).
;;       Flips the state, refreshes the sidebar (gated by a
;;       `get-buffer' check so cycling before the sidebar exists
;;       is a no-op), and echoes the new value.
;;
;; The transient suffix that surfaces the toggle stays in
;; hub-bulk per AGENTS.md Rule 2 (transient UI is heredoc-side);
;; this module only owns the data layer + the imperative verb
;; itself.

;;; Code:

;; -- Forward declaration: defined in upstream `agent-shell-workspace' --
(declare-function agent-shell-workspace-sidebar-refresh "agent-shell-workspace")

(defvar decknix--hub-wip-hide-linked t
  "When non-nil, hide WIP PRs that are linked to a live session.
The default is on -- a live session makes the WIP row redundant.
Toggle with `L' in the sidebar Toggles transient.")

(defun decknix--hub-toggle-wip-hide-linked ()
  "Toggle hiding of live-session-linked PRs from the WIP section."
  (interactive)
  (setq decknix--hub-wip-hide-linked
        (not decknix--hub-wip-hide-linked))
  (when (get-buffer "*agent-shell-sidebar*")
    (agent-shell-workspace-sidebar-refresh))
  (message "WIP hide linked: %s"
           (if decknix--hub-wip-hide-linked "on" "off")))

(provide 'decknix-hub-wip-link-filter)
;;; decknix-hub-wip-link-filter.el ends here
