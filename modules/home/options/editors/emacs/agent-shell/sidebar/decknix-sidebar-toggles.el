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

(defvar decknix--sidebar-show-toggles t
  "When non-nil, show the Toggles state line in the sidebar footer.
Toggle with `T' in the transient (Planned) or via other means.")

(defvar decknix--sidebar-live-view-mode 'flat
  "View mode for live sessions in the sidebar.
Valid values: `flat' (as-is), `workspace' (grouped by workspace),
`path' (grouped by workspace last path, excluding matching tags).
Toggle with `z' in the sidebar Toggles transient (Live section).")

(defvar decknix--sidebar-wip-group-mode 'repo
  "Grouping mode for the WIP section.
Valid values:
`repo'       group by repository only (default).
`workspace'  group by full workspace path, then repo/branch within.
`worktree'   group by workspace short name; show repo sub-header only
             when the repo name differs from the workspace name.")

(defvar decknix--sidebar-requests-display-mode nil
  "Display mode for the Requests section; nil means inherit from global.
Valid values: nil, `A' (Full), `B' (Scoped), `C' (Label), `D' (Minimal).")

(defvar decknix--sidebar-wip-display-mode nil
  "Display mode for the WIP section; nil means inherit from global.
Valid values: nil, `A' (Full), `B' (Scoped), `C' (Label), `D' (Minimal).")

(defvar decknix--sidebar-live-display-mode nil
  "Display mode for the Live section (linked PRs); nil means inherit from global.
Valid values: nil, `A' (Full), `B' (Scoped), `C' (Label), `D' (Minimal).")

(defvar decknix--sidebar-sessions-display-mode 'name
  "What to show for saved sessions in the sidebar.
Valid values: `name' (tags/preview), `tags' (raw tags), `both' (tags + name).")

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
Two failure modes are folded together (#139):
- `unresolved' -- the session JSON lacks a workspace field, or the
  workspace conv-key doesn't map to a known directory (rendered
  under the \"unknown\" workspace group today).
- `vanished'   -- the workspace path resolved fine but the directory
  no longer exists on disk (e.g. a `git worktree remove' cleaned
  it up after the session was archived).

Both are treated the same: the row is dropped so the Sessions list
only carries entries the user can actually open.  Toggle with `U'
in the Toggles transient.")

(defvar decknix--hub-display-mode 'A
  "Display mode for hub items (Requests/WIP).
Valid values: `A' (Full), `B' (Scoped), `C' (Label), `D' (Minimal).
Toggle with `D' in the sidebar.")

(defvar decknix--hub-show-saved-sessions nil
  "When non-nil, the saved Sessions block is rendered in the sidebar.
When nil (default), the entire Saved Sessions section (heading +
per-workspace groups) is omitted.  Live, Previous, Requests and WIP
sections remain unaffected.  Toggle with `h' in the Toggles
transient to show/hide the section.")

(defun decknix--sidebar-sessions-age-label ()
  "Return a short label for the current sessions age filter.
Reuses the shared `decknix--hub-age-presets' alist so the Sessions
and Requests age toggles share vocabulary."
  (or (and (boundp 'decknix--hub-age-presets)
           (alist-get decknix--sidebar-sessions-age-filter
                      decknix--hub-age-presets))
      "all"))

(defun decknix-sidebar-toggle-toggles ()
  "Toggle the visibility of the Toggles state in the sidebar footer."
  (interactive)
  (setq decknix--sidebar-show-toggles (not decknix--sidebar-show-toggles))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Sidebar toggles: %s"
           (if decknix--sidebar-show-toggles "shown" "hidden")))

(defun decknix-sidebar-cycle-live-view-mode ()
  "Cycle live-session view mode: flat → workspace → path → flat."
  (interactive)
  (setq decknix--sidebar-live-view-mode
        (pcase decknix--sidebar-live-view-mode
          ('flat 'workspace)
          ('workspace 'path)
          (_ 'flat)))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Live view mode: %s" decknix--sidebar-live-view-mode))

(defun decknix-sidebar-toggle-wip-group-mode ()
  "Cycle WIP grouping mode: repo → workspace → worktree → repo."
  (interactive)
  (setq decknix--sidebar-wip-group-mode
        (pcase decknix--sidebar-wip-group-mode
          ('repo      'workspace)
          ('workspace 'worktree)
          (_          'repo)))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "WIP grouping: %s" decknix--sidebar-wip-group-mode))

(defun decknix-sidebar-cycle-requests-display-mode ()
  "Cycle Requests display mode: inherit → A → B → C → D → inherit."
  (interactive)
  (setq decknix--sidebar-requests-display-mode
        (pcase decknix--sidebar-requests-display-mode
          ('nil 'A)
          ('A   'B)
          ('B   'C)
          ('C   'D)
          (_    nil)))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Requests layout: %s"
           (or decknix--sidebar-requests-display-mode "inherit")))

(defun decknix-sidebar-cycle-wip-display-mode ()
  "Cycle WIP display mode: inherit → A → B → C → D → inherit."
  (interactive)
  (setq decknix--sidebar-wip-display-mode
        (pcase decknix--sidebar-wip-display-mode
          ('nil 'A)
          ('A   'B)
          ('B   'C)
          ('C   'D)
          (_    nil)))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "WIP layout: %s"
           (or decknix--sidebar-wip-display-mode "inherit")))

(defun decknix-sidebar-cycle-live-display-mode ()
  "Cycle Live display mode: inherit → A → B → C → D → inherit."
  (interactive)
  (setq decknix--sidebar-live-display-mode
        (pcase decknix--sidebar-live-display-mode
          ('nil 'A)
          ('A   'B)
          ('B   'C)
          ('C   'D)
          (_    nil)))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Live layout: %s"
           (or decknix--sidebar-live-display-mode "inherit")))

(defun decknix-sidebar-cycle-sessions-display-mode ()
  "Cycle sidebar display mode for sessions: name → tags → both → name."
  (interactive)
  (setq decknix--sidebar-sessions-display-mode
        (pcase decknix--sidebar-sessions-display-mode
          ('name 'tags)
          ('tags 'both)
          ('both 'name)
          (_ 'name)))
  (message "Sessions display: %s" decknix--sidebar-sessions-display-mode)
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh)))

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

(defun decknix--sidebar-session-workspace-visible-p (workspace)
  "Return non-nil if WORKSPACE passes the unknown-ws filter (#139).
When `decknix--sidebar-sessions-hide-unknown' is nil, every
WORKSPACE is visible (including unresolved and vanished).  When
the toggle is on, WORKSPACE must be both non-nil and refer to a
directory that currently exists on disk (`file-directory-p').

A WORKSPACE that points at a path that no longer exists -- e.g.
a worktree the user removed via `git worktree remove' after the
session was archived -- is treated the same as an unresolved
workspace and dropped from the saved Sessions list."
  (or (not decknix--sidebar-sessions-hide-unknown)
      (and workspace
           (file-directory-p workspace))))

(defun decknix-sidebar-toggle-sessions-hide-unknown ()
  "Toggle whether sessions with unresolved or vanished workspace are hidden."
  (interactive)
  (setq decknix--sidebar-sessions-hide-unknown
        (not decknix--sidebar-sessions-hide-unknown))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Sessions: unresolved/vanished workspace rows %s"
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


;; == Worktree toggles (§3.6.12) ==

(defvar decknix--sidebar-wt-live-only nil
  "When non-nil, show only WIP placeholder rows whose worktree has a
live session (⎇* badge).  Collapses the placeholder list to actively
in-flight branches so the user can focus on current work.
Toggle with `l' in the `T → w' Worktrees group.")

(defvar decknix--sidebar-wt-group-by-repo t
  "When non-nil (default), group worktree rows by repository.
When nil, render a flat alphabetical list (requires §3.6.10 Worktrees
section — flat mode is a no-op until that section ships).
Toggle with `r' in the `T → w' Worktrees group.")

(defvar decknix--sidebar-wt-age-filter nil
  "Age cutoff in seconds for WIP placeholder rows; nil = no limit.
Cycles through `all / 7d / 14d / 30d' using the dedicated
`decknix--sidebar-wt-age-presets' alist.
Toggle with `a' in the `T → w' Worktrees group.")

(defvar decknix--sidebar-wt-hide-clean nil
  "When non-nil, hide worktrees with no uncommitted changes.
Requires async `git status' checks; filtering is deferred pending
the §3.6.10 Worktrees section.  The variable persists now so the
preference survives across sessions and the toggle is discoverable.
Toggle with `f' (filthy/dirty-only) in the `T → Worktrees' group.")

(defvar decknix--sidebar-wt-hide-placeholders nil
  "When non-nil, hide all WIP placeholder rows (worktrees without a PR).
Disables the §3.6.7 placeholder feature entirely so only real PRs
appear in the WIP section.
Toggle with `p' in the `T → w' Worktrees group.")

(defvar decknix--sidebar-wt-hide-merged nil
  "When non-nil, hide WIP placeholder rows whose branch is fully merged.
Requires merged-PR tracking across the WIP dataset; filtering is
deferred until the hub daemon surfaces closed/merged state for
branches without an active open PR.  The variable persists now.
Toggle with `o' in the `T → w' Worktrees group.")

(defvar decknix--sidebar-wt-age-presets
  '((nil . "all")
    (604800  . "7d")
    (1209600 . "14d")
    (2592000 . "30d"))
  "Age presets for the Worktree age filter (`T → w a').
Subset of `decknix--hub-age-presets': all / 7d / 14d / 30d.")

(defun decknix--sidebar-wt-age-label ()
  "Return a short label for the current worktree age filter."
  (or (alist-get decknix--sidebar-wt-age-filter
                 decknix--sidebar-wt-age-presets)
      "all"))

(defun decknix-sidebar-toggle-wt-live-only ()
  "Toggle whether only live-session worktrees are shown in WIP placeholders."
  (interactive)
  (setq decknix--sidebar-wt-live-only
        (not decknix--sidebar-wt-live-only))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Worktrees: live-only %s"
           (if decknix--sidebar-wt-live-only "on" "off")))

(defun decknix-sidebar-toggle-wt-group-by-repo ()
  "Toggle whether worktrees are grouped by repo."
  (interactive)
  (setq decknix--sidebar-wt-group-by-repo
        (not decknix--sidebar-wt-group-by-repo))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Worktrees: group-by-repo %s"
           (if decknix--sidebar-wt-group-by-repo "on" "off")))

(defun decknix-sidebar-cycle-wt-age-filter ()
  "Cycle the worktree age filter through presets (all/7d/14d/30d)."
  (interactive)
  (let* ((presets decknix--sidebar-wt-age-presets)
         (keys (mapcar #'car presets))
         (pos (cl-position decknix--sidebar-wt-age-filter
                           keys :test #'equal))
         (next-pos (mod (1+ (or pos 0)) (length keys))))
    (setq decknix--sidebar-wt-age-filter (nth next-pos keys))
    (when (fboundp 'agent-shell-workspace-sidebar-refresh)
      (agent-shell-workspace-sidebar-refresh))
    (message "Worktrees age filter: %s"
             (decknix--sidebar-wt-age-label))))

(defun decknix-sidebar-toggle-wt-hide-clean ()
  "Toggle whether clean (non-dirty) worktrees are hidden."
  (interactive)
  (setq decknix--sidebar-wt-hide-clean
        (not decknix--sidebar-wt-hide-clean))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Worktrees: hide-clean %s"
           (if decknix--sidebar-wt-hide-clean "on (pending §3.6.10)" "off")))

(defun decknix-sidebar-toggle-wt-hide-placeholders ()
  "Toggle whether WIP placeholder rows are hidden globally."
  (interactive)
  (setq decknix--sidebar-wt-hide-placeholders
        (not decknix--sidebar-wt-hide-placeholders))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Worktrees: placeholders %s"
           (if decknix--sidebar-wt-hide-placeholders "hidden" "shown")))

(defun decknix-sidebar-toggle-wt-hide-merged ()
  "Toggle whether worktrees with fully-merged branches are hidden."
  (interactive)
  (setq decknix--sidebar-wt-hide-merged
        (not decknix--sidebar-wt-hide-merged))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Worktrees: hide-merged %s"
           (if decknix--sidebar-wt-hide-merged "on (pending hub support)" "off")))

(defun decknix-sidebar-toggle-hub-display-mode ()
  "Cycle hub display mode: A → B → C → D → A."
  (interactive)
  (setq decknix--hub-display-mode
        (pcase decknix--hub-display-mode
          ('A 'B)
          ('B 'C)
          ('C 'D)
          (_  'A)))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Hub layout: %s" decknix--hub-display-mode))

(provide 'decknix-sidebar-toggles)
;;; decknix-sidebar-toggles.el ends here
