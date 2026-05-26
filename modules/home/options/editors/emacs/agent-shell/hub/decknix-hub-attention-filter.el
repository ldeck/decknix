;;; decknix-hub-attention-filter.el --- Hub Requests/WIP attention filters -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: decknix, hub, filter, attention

;;; Commentary:
;;
;; The hub daemon emits three orthogonal "attention" signals per
;; PR -- `needs_reply' (a non-bot reviewer is awaiting my reply),
;; `bot_pending' (a bot posted the latest comment / review and the
;; author still needs to act), and `replies_to_me' (a human posted
;; in a thread I had already participated in).  The two sidebar
;; sections that surface PR rows (Requests + WIP) each own an
;; independent toggle triple over those signals so a PR can be
;; filtered out of one list while staying visible in the other --
;; e.g. hiding bot-pending PRs from Requests because they aren't
;; review-ready, but keeping them visible in WIP because as the
;; author I want to see them.
;;
;; This module owns the toggle state, the predicate engine, and
;; the per-bucket toggle commands wired to the sidebar Toggles
;; transient (`T') and the sidebar footer.  The transient suffix
;; / prefix forms themselves stay in `decknix-agent-shell-hub'
;; (hub-bulk) because they live alongside the wider sidebar
;; transient cluster (mention-filter, bot-filter, CI-filter).
;;
;; Storage:
;;   `decknix--hub-requests-hide-needs-reply'   bound nil  (toggle `c')
;;   `decknix--hub-requests-hide-bot-pending'   bound t    (toggle `b')
;;   `decknix--hub-requests-only-my-replies'    bound nil  (toggle `M')
;;   `decknix--hub-requests-hide-reviewed'      bound t    (toggle `v')
;;   `decknix--hub-requests-hide-conflict'      bound t    (toggle `X')
;;   `decknix--hub-requests-sort-reverse'       bound nil  (toggle `s')
;;   `decknix--hub-wip-hide-needs-reply'        bound nil  (toggle `n')
;;   `decknix--hub-wip-hide-bot-pending'        bound nil  (toggle `u')
;;   `decknix--hub-wip-only-my-replies'         bound nil  (toggle `r')
;;
;; Engine:
;;   `decknix--hub-sort-requests'                stable sort honouring
;;                                                the reverse flag
;;   `decknix--hub-attention-visible-p'          shared three-arg
;;                                                predicate
;;   `decknix--hub-requests-attention-visible-p' Requests-flavoured
;;                                                wrapper
;;   `decknix--hub-wip-attention-visible-p'      WIP-flavoured wrapper
;;
;; Toggle commands:
;;   `decknix--hub-toggle-and-refresh'           shared
;;                                                set-then-refresh helper
;;   `decknix--hub-toggle-requests-hide-needs-reply'   (`c')
;;   `decknix--hub-toggle-requests-hide-bot-pending'   (`b')
;;   `decknix--hub-toggle-requests-only-my-replies'    (`M')
;;   `decknix--hub-toggle-requests-hide-reviewed'      (`v')
;;   `decknix--hub-toggle-requests-hide-conflict'      (`X')
;;   `decknix--hub-toggle-requests-sort-reverse'       (`s')
;;   `decknix--hub-toggle-wip-hide-needs-reply'        (`n')
;;   `decknix--hub-toggle-wip-hide-bot-pending'        (`u')
;;   `decknix--hub-toggle-wip-only-my-replies'         (`r')
;;
;; The sidebar refresh side-effect inside `toggle-and-refresh' is
;; gated on `(fboundp 'agent-shell-workspace-sidebar-refresh)' so
;; this module loads cleanly when the workspace feature is
;; disabled and so tests can flip toggles without invoking the UI.

;;; Code:

(require 'cl-lib)

(declare-function agent-shell-workspace-sidebar-refresh "agent-shell-workspace")

;; -- defvars: Requests section state ------------------------------

(defvar decknix--hub-requests-hide-needs-reply nil
  "When non-nil, hide Requests PRs carrying the 💬 icon.
Suppresses PRs where the latest non-bot activity is from someone
other than me — i.e. the ball is in another reviewer's or the
author's court and nothing is waiting on me.  Toggle with `c'.")

(defvar decknix--hub-requests-hide-bot-pending t
  "When non-nil (default), hide Requests PRs carrying the 🤖 icon.
A bot posted the latest comment/review, typically a lint/CI/coverage
signal the author must address with another commit.  Approving before
that lands risks stale-review dismissal, so the PR isn't review-ready.
Toggle with `b'.")

(defvar decknix--hub-requests-only-my-replies nil
  "When non-nil, only show Requests PRs carrying the ↩ icon.
Filters IN PRs where a human posted a reply after one of my own
comments or reviews.  Toggle with `M'.")

(defvar decknix--hub-requests-hide-reviewed t
  "When non-nil (default), hide Requests PRs that no longer need attention.
Hides PRs where: (a) I have already submitted APPROVED or CHANGES_REQUESTED
and the author has not re-requested my review (mentioned = nil); OR (b) the
aggregate `review_decision' is APPROVED or CHANGES_REQUESTED (a colleague has
already approved or blocked the PR).  When the author re-requests my review
(mentioned = t), the PR reappears regardless.  Toggle with `v'.")

(defvar decknix--hub-requests-hide-conflict t
  "When non-nil (default), hide Requests PRs with a merge conflict.
Merge-conflicting PRs (GitHub `mergeable = CONFLICTING') cannot be
landed without a rebase or merge-commit; reviewing them is premature
because the code will change after the conflict is resolved.  Hiding
them by default keeps the list focused on PRs that are actually
review-ready.  Toggle with `X' in the Requests section of the Toggles
transient.")

(defvar decknix--hub-requests-sort-reverse nil
  "When nil (default), Requests are sorted oldest-first.
When non-nil, the order is reversed (newest-first).  The same
ordering applies to both the sidebar Requests section and the
`R' review picker so the two stay in sync.  Toggle with `s' in the
sidebar toggles transient or with M-s live inside the picker
(picker toggles are let-scoped and do not persist).")

;; -- defvars: WIP section state -----------------------------------

(defvar decknix--hub-wip-hide-needs-reply nil
  "When non-nil, hide WIP PRs carrying the 💬 icon.
Suppresses PRs where reviewers posted the latest activity — useful
when I want to focus on PRs still awaiting first review.  Toggle
with `n'.")

(defvar decknix--hub-wip-hide-bot-pending nil
  "When non-nil, hide WIP PRs carrying the 🤖 icon.
Suppresses my own PRs where a bot posted the latest activity.
Defaults to off because as the author I usually want to see these
so I can push a fix.  Toggle with `u'.")

(defvar decknix--hub-wip-only-my-replies nil
  "When non-nil, only show WIP PRs carrying the ↩ icon.
Filters IN my PRs where a reviewer replied to one of my comments.
Toggle with `r'.")

;; -- engine: sort + visibility predicates -------------------------

(defun decknix--hub-sort-requests (items)
  "Return ITEMS sorted by `created' ascending (oldest first).
When `decknix--hub-requests-sort-reverse' is non-nil, sort descending
(newest first) instead.  Items without a `created' field sort last
regardless of direction.  Uses a stable sort on a fresh copy so the
caller's list is never mutated."
  (let ((reverse (and (boundp 'decknix--hub-requests-sort-reverse)
                      decknix--hub-requests-sort-reverse)))
    (sort (copy-sequence (or items '()))
          (lambda (a b)
            (let ((ca (alist-get 'created a))
                  (cb (alist-get 'created b)))
              (cond
               ;; Items without a created timestamp drift to the end.
               ((and (null ca) (null cb)) nil)
               ((null ca) nil)
               ((null cb) t)
               (reverse (string> ca cb))
               (t       (string< ca cb))))))))

(defun decknix--hub-attention-visible-p (item hide-reply hide-bot only-my)
  "Return non-nil if ITEM passes the three attention filters.
HIDE-REPLY, HIDE-BOT, and ONLY-MY are the three toggle states for
the owning section."
  (let ((needs-reply   (eq (alist-get 'needs_reply item) t))
        (bot-pending   (eq (alist-get 'bot_pending item) t))
        (replies-to-me (eq (alist-get 'replies_to_me item) t)))
    (and
     ;; Hide needs-reply suppresses only the non-bot case
     ;; (bot-pending is handled by its own toggle so we don't
     ;; double-suppress when both are true).
     (or (not hide-reply)
         (not (and needs-reply (not bot-pending))))
     (or (not hide-bot)
         (not bot-pending))
     (or (not only-my)
         replies-to-me))))

(defun decknix--hub-requests-attention-visible-p (item)
  "Return non-nil if ITEM passes the Requests attention filters."
  (decknix--hub-attention-visible-p
   item
   decknix--hub-requests-hide-needs-reply
   decknix--hub-requests-hide-bot-pending
   decknix--hub-requests-only-my-replies))

(defun decknix--hub-requests-reviewed-visible-p (item)
  "Return non-nil if ITEM passes the hide-reviewed filter.
When `decknix--hub-requests-hide-reviewed' is non-nil, hides PRs that
already have a conclusive review outcome and don't need further attention:
- I reviewed (APPROVED/CHANGES_REQUESTED) and the author has not re-requested.
- A colleague approved or requested changes (`review_decision' is APPROVED or
  CHANGES_REQUESTED).
When the author re-requests my review (`mentioned' = t), always shows."
  (or (not decknix--hub-requests-hide-reviewed)
      ;; Re-requested → always show regardless of review state
      (eq (alist-get 'mentioned item) t)
      ;; No conclusive review state → show
      (let ((my-review (alist-get 'my_review item))
            (review-decision (alist-get 'review_decision item)))
        (not (or (member my-review '("APPROVED" "CHANGES_REQUESTED"))
                 (member review-decision '("APPROVED" "CHANGES_REQUESTED")))))))

(defun decknix--hub-requests-conflict-visible-p (item)
  "Return non-nil if ITEM passes the conflict filter.
When `decknix--hub-requests-hide-conflict' is non-nil (default), hides
PRs whose `mergeable' field is \"CONFLICTING\" (GitHub's merge-conflict
marker).  A nil mergeable field (e.g. unknown/queued) is treated as
non-conflicting so new PRs are not inadvertently suppressed."
  (or (not decknix--hub-requests-hide-conflict)
      (not (equal (alist-get 'mergeable item) "CONFLICTING"))))

(defun decknix--hub-wip-attention-visible-p (pr)
  "Return non-nil if PR passes the WIP attention filters."
  (decknix--hub-attention-visible-p
   pr
   decknix--hub-wip-hide-needs-reply
   decknix--hub-wip-hide-bot-pending
   decknix--hub-wip-only-my-replies))

;; -- toggle commands ----------------------------------------------

(defun decknix--hub-toggle-and-refresh (sym message-fmt)
  "Flip SYM and refresh the sidebar, messaging MESSAGE-FMT with the new value."
  (set sym (not (symbol-value sym)))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message message-fmt
           (if (symbol-value sym) "on" "off")))

(defun decknix--hub-toggle-requests-hide-needs-reply ()
  "Toggle hiding Requests PRs with 💬 (non-bot trailing activity)."
  (interactive)
  (decknix--hub-toggle-and-refresh
   'decknix--hub-requests-hide-needs-reply
   "Requests 💬 filter: %s"))

(defun decknix--hub-toggle-requests-hide-bot-pending ()
  "Toggle hiding Requests PRs with 🤖 (latest activity from a bot)."
  (interactive)
  (decknix--hub-toggle-and-refresh
   'decknix--hub-requests-hide-bot-pending
   "Requests 🤖 filter: %s"))

(defun decknix--hub-toggle-requests-only-my-replies ()
  "Toggle showing only Requests PRs with ↩ (human reply in my thread)."
  (interactive)
  (decknix--hub-toggle-and-refresh
   'decknix--hub-requests-only-my-replies
   "Requests ↩ only-my-replies: %s"))

(defun decknix--hub-toggle-requests-hide-reviewed ()
  "Toggle hiding Requests PRs already reviewed or conclusively decided."
  (interactive)
  (decknix--hub-toggle-and-refresh
   'decknix--hub-requests-hide-reviewed
   "Requests reviewed filter: %s"))

(defun decknix--hub-toggle-requests-hide-conflict ()
  "Toggle hiding Requests PRs with a merge conflict (⚠ glyph)."
  (interactive)
  (decknix--hub-toggle-and-refresh
   'decknix--hub-requests-hide-conflict
   "Requests ⚠ conflict filter: %s"))

(defun decknix--hub-toggle-requests-sort-reverse ()
  "Toggle Requests sort direction (oldest↔newest) in the sidebar.
The review picker honours the same flag so pressing `R' from the
sidebar shows items in the same order.  Use M-s inside the picker
for an ephemeral flip that does not persist."
  (interactive)
  (decknix--hub-toggle-and-refresh
   'decknix--hub-requests-sort-reverse
   "Requests sort: %s"))

(defun decknix--hub-toggle-wip-hide-needs-reply ()
  "Toggle hiding WIP PRs with 💬."
  (interactive)
  (decknix--hub-toggle-and-refresh
   'decknix--hub-wip-hide-needs-reply
   "WIP 💬 filter: %s"))

(defun decknix--hub-toggle-wip-hide-bot-pending ()
  "Toggle hiding WIP PRs with 🤖."
  (interactive)
  (decknix--hub-toggle-and-refresh
   'decknix--hub-wip-hide-bot-pending
   "WIP 🤖 filter: %s"))

(defun decknix--hub-toggle-wip-only-my-replies ()
  "Toggle showing only WIP PRs with ↩."
  (interactive)
  (decknix--hub-toggle-and-refresh
   'decknix--hub-wip-only-my-replies
   "WIP ↩ only-my-replies: %s"))

(provide 'decknix-hub-attention-filter)
;;; decknix-hub-attention-filter.el ends here
