;;; decknix-hub-wip-terminal-filter.el --- WIP "hide terminal-state PRs" toggle -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, ui

;;; Commentary:
;;
;; Sidebar clutter relief for the WIP section (#137).  By default
;; the WIP renderer shows my open PRs grouped by repository -- but
;; the hub's snapshot can carry MERGED / CLOSED rows for some time
;; after a PR's terminal transition (re-render lag, branch retention,
;; deferred GitHub indexing), and the corresponding worktree placeholder
;; rows linger even longer.  All of those rows describe work the user
;; cannot meaningfully act on from the sidebar, so by default they are
;; hidden -- the user can flip the toggle to re-surface them when
;; auditing what is left to clean up.
;;
;; Two entry points:
;;
;;   `decknix--hub-wip-hide-terminal'
;;       Defvar holding the current toggle state (default `t', hide).
;;       Read by the WIP renderer in hub-bulk inside its
;;       `pr-visible-p' lambda and by the footer toggle label in
;;       workspace-bulk.
;;   `decknix--hub-wip-terminal-visible-p'
;;       Pure predicate over a single WIP PR alist; non-nil when the
;;       PR should be rendered.  When the toggle is off, every PR is
;;       visible; when on, PRs whose `state' is `MERGED' / `CLOSED'
;;       are filtered out.  Rows lacking an explicit `state' field
;;       (placeholder rows; rows from older snapshots) are treated as
;;       OPEN to avoid hiding active work.
;;   `decknix--hub-wip-pr-terminal-p'
;;       Pure, toggle-independent predicate -- non-nil when the PR's
;;       `state' is `MERGED' or `CLOSED'.  Used by the WIP renderer
;;       to decorate terminal rows with a `⊘' stale badge (#138)
;;       when the user has flipped the hide-terminal toggle off and
;;       the row is therefore visible.  Symmetric with the
;;       visibility predicate above so both stay in one place.
;;   `decknix--hub-toggle-wip-hide-terminal'
;;       Interactive toggle bound to the `m' suffix in the WIP
;;       section of the sidebar Toggles transient (`T' menu).
;;       Flips the state, refreshes the sidebar (gated by a
;;       `get-buffer' check so cycling before the sidebar exists
;;       is a no-op), and echoes the new value.
;;
;; The transient suffix that surfaces the toggle stays in
;; hub-bulk per AGENTS.md Rule 2 (transient UI is heredoc-side);
;; this module only owns the data layer + the imperative verb
;; itself, mirroring `decknix-hub-wip-link-filter' next door.

;;; Code:

;; -- Forward declaration: defined in upstream `agent-shell-workspace' --
(declare-function agent-shell-workspace-sidebar-refresh "agent-shell-workspace")
(defvar agent-shell-workspace-sidebar-buffer-name "*Agent Sidebar*")

(defvar decknix--hub-wip-hide-terminal t
  "When non-nil (default), hide WIP PRs whose state is terminal.
Terminal means MERGED or CLOSED -- the PR has nothing actionable
left in the sidebar.  Toggle off with `m' in the sidebar Toggles
transient (`T') to audit what remains for worktree cleanup.")

(defun decknix--hub-wip-pr-terminal-p (pr)
  "Return non-nil when PR's `state' is MERGED or CLOSED.
Pure predicate -- does not consult `decknix--hub-wip-hide-terminal'.
A PR with no explicit `state' field is treated as OPEN (matches
`decknix--hub-wip-terminal-visible-p' so the two predicates
disagree only by the toggle, never by the data shape).  Used by
the WIP renderer to decorate terminal rows visible under the
toggle-off path with a stale badge (#138)."
  (let ((state (or (alist-get 'state pr) "OPEN")))
    (member state '("MERGED" "CLOSED"))))

(defun decknix--hub-wip-pr-cleanup-ready-p (pr deployed-to-prod-p)
  "Return non-nil when PR is safe to hide/prune under the deploy gate.
CLOSED PRs are immediately cleanup-ready (nothing left to deploy).  A
MERGED PR is cleanup-ready only once DEPLOYED-TO-PROD-P is non-nil --
until its code positively reaches production it is deliberately kept
visible so its rollout can be tracked and its worktree is not pruned
prematurely.  OPEN / placeholder rows (no terminal `state') are never
cleanup-ready.  Pure -- does not consult `decknix--hub-wip-hide-terminal'.

DEPLOYED-TO-PROD-P is supplied by the WIP renderer from TeamCity deploy
data (`decknix--hub-deployed-to-prod-p'); it is only meaningful for a
MERGED PR."
  (let ((state (or (alist-get 'state pr) "OPEN")))
    (cond ((string= state "CLOSED") t)
          ((string= state "MERGED") (and deployed-to-prod-p t))
          (t nil))))

(defun decknix--hub-wip-terminal-visible-p (pr &optional deployed-to-prod-p)
  "Return non-nil if PR passes the deploy-gated terminal filter.
When `decknix--hub-wip-hide-terminal' is nil, every PR is visible.
When non-nil, a PR is hidden only once it is cleanup-ready
\(`decknix--hub-wip-pr-cleanup-ready-p'): CLOSED, or MERGED with its code
already DEPLOYED-TO-PROD-P.  A merged PR still rolling out to production
stays visible so its deploy can be tracked -- the change that keeps
merged worktrees alive until they ship.
A PR with no explicit `state' field is treated as OPEN so that older
snapshots and placeholder rows do not get accidentally filtered out."
  (or (not decknix--hub-wip-hide-terminal)
      (not (decknix--hub-wip-pr-cleanup-ready-p pr deployed-to-prod-p))))

(defun decknix--hub-toggle-wip-hide-terminal ()
  "Toggle hiding of MERGED / CLOSED PRs from the WIP section."
  (interactive)
  (setq decknix--hub-wip-hide-terminal
        (not decknix--hub-wip-hide-terminal))
  (when (get-buffer agent-shell-workspace-sidebar-buffer-name)
    (agent-shell-workspace-sidebar-refresh))
  (message "WIP hide terminal: %s"
           (if decknix--hub-wip-hide-terminal "on" "off")))

(provide 'decknix-hub-wip-terminal-filter)
;;; decknix-hub-wip-terminal-filter.el ends here
