;;; decknix-sidebar-layout-render.el --- Session-first sidebar render -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-sidebar-layout "0.1"))
;; Keywords: agent, hub, sidebar

;;; Commentary:
;;
;; Side-effecting half of `decknix-sidebar-layout': the Reviews and WIP
;; sections, their expansion state, and the row properties the actions read.
;;
;; Gated on `decknix-sidebar-layout-enable'.  With it nil the sidebar renders
;; exactly as before, because this replaces three established sections
;; (Requests, WIP, Live) at once and a single variable is a cheaper rollback
;; than a revert.

;;; Code:

(require 'decknix-sidebar-layout)
(require 'decknix-hub-icons)
(require 'seq)

(declare-function decknix--hub-review-session-snapshot "decknix-agent-shell-hub" ())
(declare-function decknix--hub-requests-attention-visible-p
                  "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-requests-reviewed-visible-p
                  "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-requests-draft-visible-p
                  "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-requests-conflict-visible-p
                  "decknix-hub-attention-filter" (item))
(declare-function agent-shell-workspace-sidebar-refresh "agent-shell-workspace" ())

(defvar decknix-sidebar-layout-enable t
  "When non-nil, render the session-first Reviews/WIP/Unattached sections.
Set nil to fall back to the previous Requests/WIP/Live layout.")

(defvar decknix-sidebar-layout-reviews-attention-only t
  "When non-nil (default), Reviews lists only repos that want something.

That means a blocked session or a PR with no session.  A repo whose
sessions are all `working' or `ready' is in flight and wants nothing; at
the top of the sidebar it competes with the rows that do.  Toggle with
\[decknix-layout-toggle-attention-only]; the count held back is always
shown, so the section never shrinks silently.")

(defvar decknix--layout-expanded (make-hash-table :test 'equal)
  "Repo -> non-nil when its Reviews group is expanded.")

(defvar decknix--layout-state-file
  (expand-file-name "~/.config/decknix/hub/sidebar-layout.el")
  "Where expansion state is persisted across restarts.")

(declare-function decknix--sidebar-render-section-header
                  "decknix-sidebar-format" (title &optional section-id))

(defun decknix--layout-save-state ()
  "Persist which groups are expanded."
  (ignore-errors
    (let ((repos nil))
      (maphash (lambda (k v) (when v (push k repos))) decknix--layout-expanded)
      (with-temp-file decknix--layout-state-file
        (prin1 (sort repos #'string<) (current-buffer))))))

(defun decknix--layout-load-state ()
  "Restore expansion state, if any was saved."
  (ignore-errors
    (when (file-readable-p decknix--layout-state-file)
      (let ((repos (with-temp-buffer
                     (insert-file-contents decknix--layout-state-file)
                     (read (current-buffer)))))
        (clrhash decknix--layout-expanded)
        (dolist (r repos) (puthash r t decknix--layout-expanded))))))

(defun decknix--layout-expanded-p (repo)
  "Return non-nil when REPO's group is expanded."
  (gethash repo decknix--layout-expanded))

(defun decknix-layout-toggle-expand ()
  "Expand or collapse the Reviews group on this row."
  (interactive)
  (let ((repo (get-text-property (line-beginning-position) 'decknix-layout-repo)))
    (unless repo (user-error "Not on a Reviews group row"))
    (if (decknix--layout-expanded-p repo)
        (remhash repo decknix--layout-expanded)
      (puthash repo t decknix--layout-expanded))
    (decknix--layout-save-state)
    (when (fboundp 'agent-shell-workspace-sidebar-refresh)
      (agent-shell-workspace-sidebar-refresh))))

(defun decknix-layout-toggle-attention-only ()
  "Toggle whether Reviews lists only repos that want something."
  (interactive)
  (setq decknix-sidebar-layout-reviews-attention-only
        (not decknix-sidebar-layout-reviews-attention-only))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Reviews: %s"
           (if decknix-sidebar-layout-reviews-attention-only
               "only what wants me" "everything")))

(defun decknix-layout-toggle-enable ()
  "Turn the session-first sidebar layout on or off.

Off restores the previous Requests/WIP/Live sections, which is why the
toggles for those are only offered when it IS off -- under the new layout
their renders are skipped, so they would be switches that change nothing."
  (interactive)
  (setq decknix-sidebar-layout-enable (not decknix-sidebar-layout-enable))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Sidebar layout: %s"
           (if decknix-sidebar-layout-enable "session-first" "previous")))

;; Defined above their cyclers: a `setq' on a variable whose `defvar' comes
;; later compiles as a free-variable assignment, which is a warning now and
;; a lexical-binding trap the moment this file is reorganised.
(defvar decknix-sidebar-layout-items-per-repo 5
  "Most PRs plus worktrees to list under one repo, or nil for all.

Listing every item flat gave the two followupboss sessions eleven rows
each.  A handful per repo restores the visibility the refactor lost without
returning to that; the remainder is reported, never silently dropped.")

(defvar decknix-sidebar-layout-dormant-limit 12
  "Most Dormant repo groups to render, or nil for all.
Dormant is a backlog, not a queue; an unbounded list of every branch ever
left behind pushes the sections that need action off screen.  The number
held back is always reported.")

(defconst decknix-sidebar-layout-items-cycle '(3 5 10 nil)
  "Cycle for `decknix-sidebar-layout-items-per-repo'; nil means all.")

(defun decknix-layout-cycle-items-per-repo ()
  "Cycle how many items are listed under one repo in WIP."
  (interactive)
  (let* ((cur decknix-sidebar-layout-items-per-repo)
         (pos (seq-position decknix-sidebar-layout-items-cycle cur))
         (next (nth (mod (1+ (or pos -1))
                         (length decknix-sidebar-layout-items-cycle))
                    decknix-sidebar-layout-items-cycle)))
    (setq decknix-sidebar-layout-items-per-repo next)
    (when (fboundp 'agent-shell-workspace-sidebar-refresh)
      (agent-shell-workspace-sidebar-refresh))
    (message "WIP items per repo: %s" (or next "all"))))

(defconst decknix-sidebar-layout-dormant-cycle '(6 12 24 nil)
  "Cycle for `decknix-sidebar-layout-dormant-limit'; nil means all.")

(defun decknix-layout-cycle-dormant-limit ()
  "Cycle how many Dormant repo groups are listed."
  (interactive)
  (let* ((cur decknix-sidebar-layout-dormant-limit)
         (pos (seq-position decknix-sidebar-layout-dormant-cycle cur))
         (next (nth (mod (1+ (or pos -1))
                         (length decknix-sidebar-layout-dormant-cycle))
                    decknix-sidebar-layout-dormant-cycle)))
    (setq decknix-sidebar-layout-dormant-limit next)
    (when (fboundp 'agent-shell-workspace-sidebar-refresh)
      (agent-shell-workspace-sidebar-refresh))
    (message "Dormant repos shown: %s" (or next "all"))))

(defun decknix--layout-sidebar-width ()
  "Return the width of the sidebar window, falling back to the selected one.

Resolved from the buffer rather than from `window-width' with no argument:
the render runs with whatever window is selected, so the bare call answered
for the wrong one and padded every row to it."
  (let ((win (get-buffer-window (current-buffer))))
    (if (window-live-p win) (window-width win) (window-width))))

(defun decknix--layout-sessions ()
  "Return the live session snapshot, or nil."
  (and (fboundp 'decknix--hub-review-session-snapshot)
       (ignore-errors (decknix--hub-review-session-snapshot))))

(defvar decknix--hub-reviews)

(defun decknix--layout-feed-items ()
  "Return the hub's request items, or nil.

Reads the same `decknix--hub-reviews' the old Requests render used, and
applies the SAME visibility filters -- otherwise folding Requests into
Reviews would quietly re-show every draft, conflicted and already-reviewed
PR those filters exist to hide."
  (let ((items (and (boundp 'decknix--hub-reviews)
                    (alist-get 'items decknix--hub-reviews))))
    (if (fboundp 'decknix--hub-requests-attention-visible-p)
        (seq-filter
         (lambda (item)
           (and (decknix--hub-requests-attention-visible-p item)
                (decknix--hub-requests-reviewed-visible-p item)
                (decknix--hub-requests-draft-visible-p item)
                (decknix--hub-requests-conflict-visible-p item)))
         items)
      items)))

(defvar decknix--hub-wip)
(defvar decknix--agent-provider-id)

(declare-function decknix--sidebar-render-subagents
                  "decknix-agent-shell-workspace" (line-num session-id provider-id))
(declare-function decknix--agent-buffer-session-id
                  "decknix-agent-buffer-lookup" (&optional buf))

(defun decknix--layout-render-subagents (line-num buffer-name)
  "Render BUFFER-NAME's sub-agents under its row.  Returns LINE-NUM.

Reuses the Live section's renderer, which the layout no longer calls --
so sub-agents vanished from the sidebar entirely at the refactor. It
colours each row by derived liveness (running / active / done) and honours
`decknix--sidebar-hide-completed-subagents', both of which would have to be
reimplemented to render them here instead.

Needs a LIVE buffer: the renderer reads the session id and provider off
buffer-locals, and treats the parent as live when classifying state."
  (let ((buf (and buffer-name (get-buffer buffer-name))))
    (when (and buf (buffer-live-p buf)
               (fboundp 'decknix--sidebar-render-subagents))
      (let ((sid (ignore-errors (decknix--agent-buffer-session-id buf)))
            (provider (and (local-variable-p 'decknix--agent-provider-id buf)
                           (buffer-local-value 'decknix--agent-provider-id buf))))
        (when (and sid provider)
          (setq line-num (ignore-errors
                           (decknix--sidebar-render-subagents
                            line-num sid provider)))))))
  line-num)

(defun decknix--layout-wip-repos ()
  "Return the hub WIP feed's repos list, or nil."
  (and (boundp 'decknix--hub-wip)
       (alist-get 'repos decknix--hub-wip)))

(declare-function decknix--hub-wt-audit-refresh-if-stale "decknix-hub-wt-stale" ())

(defun decknix--layout-worktrees ()
  "Return cached worktree records, kicking an async audit when stale.

The kick used to live inside `decknix--hub-render-wip', which this layout
no longer calls -- so nothing refreshed the cache and every repo reported
`0 wt' forever.  Measured straight after a switch: `wt-cache-ready' nil,
0 rows, and the worktree a session was actually sitting in invisible.

`-if-stale' is async and self-guarding (one subprocess at a time), so
calling it from the render path cannot queue an audit per paint."
  (when (fboundp 'decknix--hub-wt-audit-refresh-if-stale)
    (ignore-errors (decknix--hub-wt-audit-refresh-if-stale)))
  (and (fboundp 'decknix-hub-wt-rows)
       (ignore-errors (decknix-hub-wt-rows))))

(defun decknix--layout-short-name (buffer-name)
  "Return BUFFER-NAME without the agent wrapper."
  (replace-regexp-in-string
   "\\`\\*\\(Claude\\|Pi\\|Auggie\\|Codex\\|Gemini\\)?:? ?\\|\\*\\'" ""
   (or buffer-name "")))

(defun decknix--layout-render-reviews (line-num width)
  "Render the Reviews section.  Returns the updated LINE-NUM."
  (let* ((sessions (decknix--layout-sessions))
         (items (decknix--layout-feed-items))
         (all-groups (decknix--layout-review-groups sessions items))
         (split (decknix--layout-filter-groups
                 all-groups decknix-sidebar-layout-reviews-attention-only))
         (groups (car split))
         (held (cdr split))
         (dups (decknix--layout-duplicate-prs sessions))
         (total (apply #'+ (mapcar (lambda (g) (or (plist-get g :sessions) 0))
                                   all-groups)))
         (asking (apply #'+ (mapcar (lambda (g) (or (plist-get g :asking) 0))
                                    all-groups))))
    (when (or groups (> held 0))
      (decknix--sidebar-render-section-header
       (if (> asking 0)
           (format "Reviews (%d) — %d need you" total asking)
         (format "Reviews (%d)" total))
       'reviews)
      (setq line-num (1+ line-num))
      (dolist (group groups)
        (let ((repo (plist-get group :repo)))
          (insert (propertize (decknix--layout-group-label group width)
                              'face (if (> (or (plist-get group :asking) 0) 0)
                                        'warning 'default)
                              'decknix-layout-repo repo
                              'decknix-layout-group group)
                  "\n")
          (setq line-num (1+ line-num))
          (when (decknix--layout-expanded-p repo)
            (dolist (pr (plist-get group :prs))
              (insert (propertize (decknix--layout-pr-label pr)
                                  'face (if (decknix--layout-attention-p
                                             (plist-get pr :state))
                                            'warning 'font-lock-comment-face)
                                  'decknix-layout-pr pr
                                  'decknix-hub-type 'request
                                  'decknix-hub-repo (alist-get 'repo (plist-get pr :item))
                                  'decknix-hub-number (plist-get pr :number)
                                  'decknix-hub-url (alist-get 'url (plist-get pr :item)))
                      "\n")
              (setq line-num (1+ line-num))
              ;; A review session is normally implied by its PR row, so
              ;; listing it as well would double every review.  MORE than one
              ;; session on a PR is the exception worth naming: 16 PRs have
              ;; two agents on them, which is invisible from a single row and
              ;; is the thing to act on.
              (let ((covering (decknix--layout-pr-sessions
                               sessions (plist-get pr :key))))
                ;; One covering session: the PR row IS that session, so its
                ;; sub-agents belong directly under it.
                (when (= (length covering) 1)
                  (setq line-num (decknix--layout-render-subagents
                                  line-num (nth 0 (car covering)))))
                (when (> (length covering) 1)
                  (dolist (cs covering)
                    (insert (propertize
                             (format "      %s %s"
                                     (decknix--layout-state-glyph (nth 3 cs))
                                     (decknix--layout-short-name (nth 0 cs)))
                             'face 'error
                             'decknix-layout-session cs
                             'decknix-layout-buffer (nth 0 cs))
                            "\n")
                    (setq line-num (1+ line-num))
                    (setq line-num (decknix--layout-render-subagents
                                    line-num (nth 0 cs))))))))))
      (when (> held 0)
        (insert (propertize
                 (format " ·  %d more in flight, nothing waiting" held)
                 'face 'font-lock-comment-face
                 'decknix-layout-held held)
                "\n")
        (setq line-num (1+ line-num)))
      (when dups
        (insert (propertize (format " ⚠  %d PRs have 2+ sessions" (length dups))
                            'face 'error
                            'decknix-layout-duplicates dups)
                "\n")
        (setq line-num (1+ line-num)))))
  line-num)

(defun decknix--layout-render-wip (line-num width)
  "Render WIP: my live sessions with their own work nested beneath each.

Nesting rather than a separate PR-centric section: the old layout listed my
PRs and worktrees under a second heading also called \"WIP\", with nothing
stating which session was on which.  An item may appear under two sessions
when both share a workspace, which is preferred over picking a winner and
hiding the sharing."
  (let* ((sessions (decknix--layout-sessions))
         (wip (decknix--layout-wip-sessions sessions))
         (tree (decknix--layout-wip-tree wip (decknix--layout-wip-repos)
                                         (decknix--layout-worktrees))))
    (when wip
      (insert "\n")
      (setq line-num (1+ line-num))
      (decknix--sidebar-render-section-header
       (format "WIP (%d)" (length wip)) 'wip-sessions)
      (setq line-num (1+ line-num))
      (dolist (row (decknix--layout-dedup-claims (plist-get tree :sessions)))
        (let* ((session (plist-get row :session))
               (state (nth 3 session))
               (name (decknix--layout-short-name (nth 0 session)))
               (left (format " %s  %s" (decknix--layout-state-glyph state) name))
               (right (or state ""))
               (pad (max 1 (- width (string-width left) (string-width right)))))
          ;; Coloured by state, not just bolded on attention.  At 48 columns
          ;; the trailing status word is off-screen, so colour and the
          ;; left-hand glyph are the only state the user can actually read.
          (insert (propertize (concat left (make-string pad ?\s) right)
                              'face (decknix--layout-state-face state)
                              'decknix-layout-session session
                              'decknix-layout-buffer (nth 0 session))
                  "\n")
          (setq line-num (1+ line-num))
          (setq line-num (decknix--layout-render-subagents
                          line-num (nth 0 session)))
          (dolist (claim (plist-get row :repos))
            (setq line-num (decknix--layout-render-claim
                            line-num width claim session)))))
      (setq line-num (decknix--layout-render-dormant
                      line-num width (plist-get tree :dormant)))))
  line-num)

(defun decknix--layout-item-title (pr)
  "Return PR\='s title, falling back to its branch then its number.

The title rather than the branch: a branch name is mostly the ticket key
repeated from the title, and the old sidebar showed titles."
  (let ((raw (plist-get pr :pr)))
    (or (alist-get 'title raw)
        (plist-get pr :branch)
        (format "#%s" (plist-get pr :number)))))

(defun decknix--layout-pr-row (pr width)
  "Return the rendered line for PR, fitted to WIDTH.

Built from the hub\='s own icon vocabulary -- author provenance, primary
state, activity -- each carrying its OWN colour, rather than one severity
face painted over the whole row.  The row had become a uniformly coloured
string of flat ASCII, which is legible only if you already know what you
are looking at; the glyph colours are what make draft-versus-conflicting
or human-versus-bot readable without decoding.

The title is truncated rather than allowed to push the glyphs out of the
window, since the glyphs are the part worth keeping when space runs out."
  (let* ((raw (plist-get pr :pr))
         (icons (concat (decknix--hub-author-icon raw)
                        (decknix--hub-primary-status-icon raw 'wip)
                        (decknix--hub-activity-icons raw)))
         (age (decknix--hub-format-age (alist-get 'updated raw)))
         (num (format "#%s" (plist-get pr :number)))
         (lead (format "    %s %-3s %s " icons age num))
         (room (max 1 (- width (string-width lead))))
         (title (decknix--layout-item-title pr))
         (title (if (> (string-width title) room)
                    (concat (truncate-string-to-width title (max 1 (1- room))) "…")
                  title)))
    (concat lead (propertize title 'face 'shadow))))

(defun decknix--layout-render-claim (line-num width claim session)
  "Render one repo CLAIM under SESSION, with its items.  Returns LINE-NUM.

The repo line takes its colour from the WORST item beneath it, so a
collapsed repo still shows that something in there is blocked."
  (if (plist-get claim :duplicate)
      (decknix--layout-render-duplicate-claim line-num width claim session)
    (decknix--layout-render-claim-1 line-num width claim session)))

(defun decknix--layout-render-duplicate-claim (line-num width claim session)
  "Render CLAIM as one line, its items having been shown under an earlier
session.  Keeps the sharing visible without repeating the whole subtree."
  (let* ((left (format "    ⇡ %s" (plist-get claim :repo)))
         (right "shared ↑")
         (pad (max 1 (- width (string-width left) (string-width right)))))
    (insert (propertize (concat left (make-string pad ?\s) right)
                        'face 'font-lock-comment-face
                        'decknix-layout-claim claim
                        'decknix-layout-session session)
            "\n")
    (1+ line-num)))

(defun decknix--layout-render-claim-1 (line-num width claim session)
  "Render CLAIM and its nested items.  Returns LINE-NUM."
  (let* ((prs (plist-get claim :pr-items))
         (wts (plist-get claim :wt-items))
         (left (format "    ⇡ %s" (plist-get claim :repo)))
         (right (decknix--layout-count-label (plist-get claim :prs)
                                             (plist-get claim :worktrees)))
         (pad (max 1 (- width (string-width left) (string-width right))))
         (budget decknix-sidebar-layout-items-per-repo)
         (shown-prs (if budget (seq-take prs budget) prs))
         (left-budget (and budget (max 0 (- budget (length shown-prs)))))
         (shown-wts (if budget (seq-take wts left-budget) wts))
         (held (- (+ (length prs) (length wts))
                  (+ (length shown-prs) (length shown-wts)))))
    (insert (propertize (concat left (make-string pad ?\s) right)
                        'face (decknix--layout-severity-face
                               (plist-get claim :severity))
                        'decknix-layout-claim claim
                        'decknix-layout-session session)
            "\n")
    (setq line-num (1+ line-num))
    (dolist (pr shown-prs)
      (insert (propertize
               (decknix--layout-pr-row pr width)
               'decknix-hub-type 'wip
               'decknix-hub-repo (plist-get pr :repo)
               'decknix-hub-number (plist-get pr :number)
               'decknix-hub-url (alist-get 'url (plist-get pr :pr)))
              "\n")
      (setq line-num (1+ line-num)))
    (dolist (wt shown-wts)
      (insert (propertize
               (format "    %s   wt %s" (decknix--layout-wt-glyph wt)
                       (propertize (or (plist-get wt :branch) "?") 'face 'shadow))
               'decknix-layout-worktree wt)
              "\n")
      (setq line-num (1+ line-num)))
    (when (> held 0)
      (insert (propertize (format "      … %d more" held)
                          'face 'font-lock-comment-face)
              "\n")
      (setq line-num (1+ line-num))))
  line-num)


(defun decknix--layout-render-dormant (line-num width dormant)
  "Render the Dormant section: work with no live session on it.

Separate from WIP because the distinction is the whole point -- WIP is work
an agent is on, Dormant is work sitting there without one."
  (let* ((groups (decknix--layout-dormant-by-repo dormant))
         (shown (if decknix-sidebar-layout-dormant-limit
                    (seq-take groups decknix-sidebar-layout-dormant-limit)
                  groups))
         (held (- (length groups) (length shown))))
    (when groups
      (insert "\n")
      (setq line-num (1+ line-num))
      (decknix--sidebar-render-section-header
       (format "Dormant (%d)" (length groups)) 'dormant)
      (setq line-num (1+ line-num))
      (dolist (g shown)
        (let* ((left (format " ·  %s" (plist-get g :repo)))
               (right (decknix--layout-count-label
                       (length (plist-get g :prs))
                       (length (plist-get g :worktrees))))
               (pad (max 1 (- width (string-width left) (string-width right)))))
          (insert (propertize (concat left (make-string pad ?\s) right)
                              'face 'font-lock-comment-face
                              'decknix-layout-dormant g)
                  "\n")
          (setq line-num (1+ line-num))))
      (when (> held 0)
        (insert (propertize (format " ·  %d more repos dormant" held)
                            'face 'font-lock-comment-face)
                "\n")
        (setq line-num (1+ line-num)))))
  line-num)

(provide 'decknix-sidebar-layout-render)
;;; decknix-sidebar-layout-render.el ends here
