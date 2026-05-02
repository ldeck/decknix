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
;;   `decknix--hub-show-bots'              (defvar, override flag)
;;   `decknix--hub-bot-patterns'           (defvar, regexp list)
;;   `decknix--hub-bot-author-p'           (regexp predicate over author)
;;   `decknix--hub-bot-visible-p'          (item-level visibility)
;;
;; The interactive sidebar mutators stay in the heredoc — they refresh
;; the sidebar, which is a heredoc-side concern:
;;
;;   `decknix--hub-cycle-mention-filter'   (mutates state + refreshes)
;;   `decknix--hub-toggle-mention-filter'  (defalias)
;;   `decknix--hub-toggle-bot-filter'      (mutates state + refreshes)
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
  me        — only PRs where I am directly requested or @-mentioned.
  team      — only PRs where one of my teams is requested
              (and I am not directly requested / mentioned).
  me+team   — union of `me' and `team'.

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
authored are excluded so I never see them under any mention state."
  (let ((state decknix--hub-mention-filter))
    (cond
     ((null state) t)
     ((decknix--hub-item-author-p item) nil)
     (t
      (let ((me (decknix--hub-item-mentioned-p item))
            (team (decknix--hub-item-team-requested-p item)))
        (pcase state
          ('me      me)
          ('team    (and team (not me)))
          ('me+team (or me team))
          (_        t)))))))

;; -- Bot filter --------------------------------------------------------

(defvar decknix--hub-show-bots nil
  "When nil (default), hide PRs authored by bots (e.g. dependabot).
When non-nil, show all PRs including bot-authored ones.")

(defvar decknix--hub-bot-patterns
  '("\\[bot\\]$" "^dependabot" "^renovate" "^greenkeeper")
  "Regexps matched against the PR author to detect bot accounts.")

(defun decknix--hub-bot-author-p (author)
  "Return non-nil if AUTHOR matches a known bot pattern."
  (and author
       (seq-some (lambda (pat)
                   (string-match-p pat author))
                 decknix--hub-bot-patterns)))

(defun decknix--hub-bot-visible-p (item)
  "Return non-nil if ITEM passes the bot filter.
Always returns t when `decknix--hub-show-bots' is non-nil."
  (or decknix--hub-show-bots
      (not (decknix--hub-bot-author-p
            (alist-get 'author item)))))

(provide 'decknix-hub-mention-bot)
;;; decknix-hub-mention-bot.el ends here
