;;; decknix-hub-mention-bot.el --- Hub mention-filter + bot visibility predicates -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, filter

;;; Commentary:
;;
;; Pure visibility-filter helpers extracted from the agent-shell heredoc.
;; Two co-resident clusters that both decide whether a hub PR item is
;; rendered into the Requests / WIP sections:
;;
;; -- mention-filter cluster --
;;
;;   `decknix--hub-mention-filter'         (defvar, state symbol)
;;   `decknix--hub-mention-filter-cycle'   (defvar, cycle order)
;;   `decknix--hub-mention-filter-normalize'   (legacy boolean migration)
;;   `decknix--hub-mention-filter-label'   (state -> short label)
;;   `decknix--hub-item-author-p'          (viewer-equality predicate)
;;   `decknix--hub-item-mentioned-p'       (alist gate)
;;   `decknix--hub-item-team-requested-p'  (alist gate)
;;   `decknix--hub-mention-visible-p'      (combines the above per state)
;;
;; -- bot cluster --
;;
;;   `decknix--hub-show-bots'                  (defvar, tri-state symbol)
;;   `decknix--hub-show-bots-cycle'            (defvar, cycle order)
;;   `decknix--hub-show-bots-normalize'        (legacy boolean migration)
;;   `decknix--hub-show-bots-label'            (state -> short label)
;;   `decknix--hub-bot-patterns'               (defvar, regexp list)
;;   `decknix--hub-bot-author-p'               (regexp predicate over author)
;;   `decknix--hub-item-others-requested-p'    (alist gate: other users tagged)
;;   `decknix--hub-item-bot-mentioned-p'       (me OR team-without-others)
;;   `decknix--hub-bot-visible-p'              (item-level visibility, tri-state)
;;
;; The interactive sidebar mutators stay in the heredoc — they refresh
;; the sidebar, which is a heredoc-side concern:
;;
;;   `decknix--hub-cycle-mention-filter'   (mutates state + refreshes)
;;   `decknix--hub-toggle-mention-filter'  (defalias)
;;   `decknix--hub-cycle-bot-filter'       (mutates state + refreshes)
;;   `decknix--hub-toggle-bot-filter'      (defalias for legacy callers)
;;
;; The free defvar consumed here (`decknix--hub-reviews') is populated
;; by the heredoc's hub refresh code and is forward-declared below so
;; the byte-compiler stays clean while runtime load order — heredoc
;; defvars first, this module via `(require ...)' second — provides
;; the actual binding.

;;; Code:

(require 'seq)

;; -- Forward declaration: defined elsewhere in agent-shell config --
(defvar decknix--hub-reviews)

;; -- Mention filter ----------------------------------------------------

(defvar decknix--hub-mention-filter nil
  "Mention-filter state for the Requests section.
A symbol with one of these values:
  nil       — no filtering (all visible).
  me        — only PRs where I am directly requested / @-mentioned.
  team      — only PRs where one of my teams is requested.  This
              includes PRs where I am *also* directly requested; it
              only excludes PRs requested of me alone with no team.
  me+team   — PRs where EITHER (1) I am directly requested, OR (2) a
              team is requested and NO specific individuals are (i.e.
              a pure team ask with no `mentioned'/`others_requested').
              A team PR that also tags other individuals is treated as
              team-noise someone else is already on, and hidden.

In every non-nil state, PRs I authored are excluded.

For backward compatibility, a legacy boolean `t' is migrated to `me'.")

(defvar decknix--hub-mention-filter-cycle
  '(nil me team me+team)
  "Cycle order for `decknix--hub-cycle-mention-filter'.")

(defun decknix--hub-mention-filter-normalize (val)
  "Coerce a persisted VAL into a valid mention-filter state.
Migrates legacy boolean state: `t' → `me', `nil' stays `nil'."
  (cond
   ((memq val decknix--hub-mention-filter-cycle) val)
   ((eq val t) 'me)
   (t nil)))

(defun decknix--hub-mention-filter-label ()
  "Return a short label for the current mention-filter state."
  (pcase decknix--hub-mention-filter
    ('me      "me")
    ('team    "team")
    ('me+team "me+team")
    (_        "off")))

(defun decknix--hub-item-author-p (item)
  "Return non-nil if ITEM was authored by the current viewer.
Uses the `viewer' field from the reviews JSON file when available;
falls back to a no-op (returns nil) when the field is missing so
the filter remains permissive on older hub versions."
  (let ((viewer (and (boundp 'decknix--hub-reviews)
                     decknix--hub-reviews
                     (alist-get 'viewer decknix--hub-reviews)))
        (author (alist-get 'author item)))
    (and viewer author
         (string-equal-ignore-case viewer author))))

(defun decknix--hub-item-mentioned-p (item)
  "Return non-nil if ITEM has the `mentioned' flag set.
Used to show the @ indicator and to filter when the mention state
includes `me'."
  (eq (alist-get 'mentioned item) t))

(defun decknix--hub-item-team-requested-p (item)
  "Return non-nil if ITEM has the `team_requested' flag set.
True when one of the viewer's teams was requested as a reviewer."
  (eq (alist-get 'team_requested item) t))

(defun decknix--hub-mention-visible-p (item)
  "Return non-nil if ITEM passes the current mention filter.
Always returns t when filter is `nil'.  When filtering, PRs I
authored are excluded so I never see them under any mention state.
See `decknix--hub-mention-filter' for the per-state semantics."
  (let ((state decknix--hub-mention-filter))
    (cond
     ((null state) t)
     ((decknix--hub-item-author-p item) nil)
     (t
      (let ((me     (decknix--hub-item-mentioned-p item))
            (team   (decknix--hub-item-team-requested-p item))
            (others (decknix--hub-item-others-requested-p item)))
        (pcase state
          ;; me: I am directly requested.
          ('me      me)
          ;; team: a team is requested -- includes team+me, excludes
          ;; PRs requested of me alone (no team).
          ('team    team)
          ;; me+team: I am requested, OR a pure team ask with no
          ;; specific individuals tagged (not me, not others).
          ('me+team (or me (and team (not me) (not others))))
          (_        t)))))))

;; -- Bot filter --------------------------------------------------------

(defvar decknix--hub-show-bots nil
  "Bot-author visibility state for the Requests section.
A symbol with one of these values:
  nil        — hide PRs authored by bots (default).
  show       — show all bot-authored PRs.
  mentioned  — show bot-authored PRs only when I am directly
               requested / @-mentioned, OR when one of my teams is
               requested AND no other individuals are tagged
               (i.e. team-noise that someone else is already on
               is filtered out).

For backward compatibility, a legacy boolean `t' is migrated to `show'.")

(defvar decknix--hub-show-bots-cycle
  '(nil show mentioned)
  "Cycle order for `decknix--hub-cycle-bot-filter'.")

(defun decknix--hub-show-bots-normalize (val)
  "Coerce a persisted VAL into a valid show-bots state.
Migrates legacy boolean state: `t' → `show', `nil' stays `nil'."
  (cond
   ((memq val decknix--hub-show-bots-cycle) val)
   ((eq val t) 'show)
   (t nil)))

(defun decknix--hub-show-bots-label ()
  "Return a short label for the current show-bots state."
  (pcase decknix--hub-show-bots
    ('show      "show")
    ('mentioned "mention")
    (_          "hide")))

(defvar decknix--hub-bot-patterns
  '("\\[bot\\]$" "^dependabot" "^renovate" "^greenkeeper")
  "Regexps matched against the PR author to detect bot accounts.")

(defun decknix--hub-bot-author-p (author)
  "Return non-nil if AUTHOR matches a known bot pattern."
  (and author
       (seq-some (lambda (pat)
                   (string-match-p pat author))
                 decknix--hub-bot-patterns)))

(defun decknix--hub-item-others-requested-p (item)
  "Return non-nil if ITEM has the `others_requested' flag set.
True when any User reviewer other than the viewer is requested.
Used by the `mentioned' bot-filter state to distinguish a clean
team-request (only my team tagged, no specific individuals) from
team-noise where someone else is already handling the review."
  (eq (alist-get 'others_requested item) t))

(defun decknix--hub-item-bot-mentioned-p (item)
  "Return non-nil if ITEM matches the bot-filter `mentioned' criterion.
True when:
  - I am directly requested or @-mentioned (`mentioned' flag), OR
  - one of my teams is requested AND no other individuals are
    requested (clean team-request, no other reviewer in flight)."
  (or (decknix--hub-item-mentioned-p item)
      (and (decknix--hub-item-team-requested-p item)
           (not (decknix--hub-item-others-requested-p item)))))

(defun decknix--hub-bot-visible-p (item)
  "Return non-nil if ITEM passes the bot filter.
Three states for `decknix--hub-show-bots' drive the answer:
  nil        — bots hidden: non-bot items always visible; bot items
               always hidden.
  show       — bots visible: every item is visible.
  mentioned  — bots visible only when the item matches the bot-filter
               `mentioned' criterion (see
               `decknix--hub-item-bot-mentioned-p'); non-bot items
               remain visible."
  (let ((state decknix--hub-show-bots)
        (is-bot (decknix--hub-bot-author-p (alist-get 'author item))))
    (pcase state
      ('show      t)
      ('mentioned (or (not is-bot)
                      (decknix--hub-item-bot-mentioned-p item)))
      (_          (not is-bot)))))

(provide 'decknix-hub-mention-bot)
;;; decknix-hub-mention-bot.el ends here
