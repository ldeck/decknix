;;; decknix-hub-repo-name.el --- Hub repo-name cap state + helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, ui

;;; Commentary:
;;
;; Repo-name cap cluster carved out of the agent-shell hub heredoc.
;; Decides how aggressively the repo segment of an ungrouped PR
;; line is truncated when rendered in the sidebar.  Three flavours
;; of cap (`short' = 12 chars, `medium' = 20 chars, `none' =
;; uncapped) are exposed via a single defvar plus a pure
;; `apply' helper and an interactive cycler.
;;
;; Three entry points:
;;
;;   `decknix--hub-repo-name-cap'
;;       Defvar holding the current cap symbol.  Read by the
;;       columnar PR row renderers in hub-bulk and the footer
;;       toggle label in workspace-bulk.
;;   `decknix--hub-repo-name-apply'
;;       Pure: truncate REPO per the current cap.  Called from
;;       the row renderers on every paint.
;;   `decknix--hub-cycle-repo-name-cap'
;;       Interactive cycler bound to `N' in the toggles transient.
;;       Refreshes the sidebar after mutating the state -- the
;;       refresh call is guarded by a `get-buffer' check so the
;;       cycle is safe to call before the sidebar exists.
;;
;; The transient suffix that invokes the cycler stays in hub-bulk
;; per AGENTS.md Rule 2 (transient UI is heredoc-side); this
;; module only owns the data layer + the imperative verb itself.

;;; Code:

;; -- Forward declaration: defined in upstream `agent-shell-workspace' --
(declare-function agent-shell-workspace-sidebar-refresh "agent-shell-workspace")
(defvar agent-shell-workspace-sidebar-buffer-name "*Agent Sidebar*")

(defvar decknix--hub-repo-name-cap 'short
  "Cap for the repo segment of an ungrouped PR line.
`short' = 12 chars, `medium' = 20 chars, `none' = uncapped.
Irrelevant when PRs are grouped under a repo sub-header.")

(defun decknix--hub-repo-name-apply (repo)
  "Truncate REPO per `decknix--hub-repo-name-cap'."
  (let* ((limit (pcase decknix--hub-repo-name-cap
                  ('short  12)
                  ('medium 20)
                  ('none   nil)
                  (_       12))))
    (if (and limit (> (length repo) limit))
        (substring repo 0 limit)
      repo)))

(defun decknix--hub-cycle-repo-name-cap ()
  "Cycle the repo-name cap: short → medium → none → short."
  (interactive)
  (setq decknix--hub-repo-name-cap
        (pcase decknix--hub-repo-name-cap
          ('short  'medium)
          ('medium 'none)
          ('none   'short)
          (_       'short)))
  (when (get-buffer agent-shell-workspace-sidebar-buffer-name)
    (agent-shell-workspace-sidebar-refresh))
  (message "Repo name cap: %s" decknix--hub-repo-name-cap))

(provide 'decknix-hub-repo-name)
;;; decknix-hub-repo-name.el ends here
