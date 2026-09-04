;;; decknix-hub-review-priority.el --- Which review to do next -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, pr, review, priority

;;; Commentary:
;;
;; Requests were ordered by `updated' descending -- most recent activity
;; first.  That is a recency feed, not a queue: an Augment nitpick bumps a
;; PR to the top exactly as hard as a genuine re-request, and a three-day
;; old PR blocking a colleague sinks below a bot's typo note.  With
;; several open there was no order to work in, so you cycled at random.
;;
;; This scores an item instead.  Higher sorts first.  Two axes, because
;; they answer different questions and neither subsumes the other:
;;
;;   WHAT is it?    Incident work (HOT/PIR/DOS/ALR) outranks feature work,
;;                  which outranks EH.  Taken from the ticket prefix in
;;                  the title, which every PR here carries.
;;
;;   WHERE is it?   Somebody waiting on a reply outranks a re-request,
;;                  which outranks a stale review, which outranks an
;;                  untouched personal ask, which outranks a team ask.
;;
;; A composite integer rather than tiers, because the two axes genuinely
;; cross: a HOT PR nobody has touched should beat a feature PR that is
;; merely waiting on a reply, and strict tiers cannot express that
;; without doubling every level.  Every weight is a named constant with
;; its reasoning, so the ordering can be argued with rather than reverse
;; engineered from behaviour.
;;
;; Age contributes a small, capped nudge.  Waiting matters -- somebody is
;; blocked -- but it must never let a two-week-old EH draft outrank a HOT
;; PR raised an hour ago, so the cap is deliberately below one tier step.

;;; Code:

(require 'map)

(defconst decknix--hub-review-incident-prefixes '("HOT" "PIR" "DOS" "ALR")
  "Ticket prefixes that mean incident work.  Reviewed before anything else.")

(defconst decknix--hub-review-deferred-prefixes '("EH")
  "Ticket prefixes that are explicitly lower priority than feature work.")

;; --- weights, each with the reason it is the size it is ---

(defconst decknix--hub-review-w-incident 100
  "Bonus for incident work.  Larger than any engagement gap, so a HOT PR
nobody has touched still beats a feature PR someone is waiting on.")

(defconst decknix--hub-review-w-deferred -30
  "Penalty for EH work: below feature work, but not below a draft or a
bot, because it is still real work somebody asked for.")

(defconst decknix--hub-review-w-replies-to-me 60
  "Someone has replied TO ME and is waiting.  The strongest engagement
signal: a human is blocked on my next sentence.")

(defconst decknix--hub-review-w-needs-reply 50
  "A thread needs a reply, though not necessarily to me.")

(defconst decknix--hub-review-w-re-requested 45
  "The author has explicitly asked me back after changes.")

(defconst decknix--hub-review-w-stale 40
  "The author pushed since my review: my previous pass is void and they
are waiting on a fresh one.")

(defconst decknix--hub-review-w-mentioned 30
  "Requested of me personally, untouched.")

(defconst decknix--hub-review-w-team 15
  "A team ask: mine to pick up, but not mine specifically.")

(defconst decknix--hub-review-w-baseline 10
  "Anything else still in the queue.")

(defconst decknix--hub-review-w-answered -25
  "Another reviewer has responded, so this is probably covered.  A
penalty rather than a floor: a HOT PR someone else answered can still
outrank an untouched feature PR.")

(defconst decknix--hub-review-w-draft -40
  "Draft: the author is not finished asking.")

(defconst decknix--hub-review-w-bot -35
  "Bot-authored: real, but rarely what should be read first.")

(defconst decknix--hub-review-w-gone -1000
  "The PR left the review queue.  Sinks below everything; nothing else
about it matters once no review is wanted.")

(defconst decknix--hub-review-age-cap 14
  "Maximum days of age bonus, at 1 point per day.
Capped below one tier step on purpose: waiting should break ties within
a band, never promote an old low-priority item over a fresh urgent one.")

(defun decknix--hub-review-ticket-prefix (title)
  "Return the uppercase ticket prefix of TITLE, or nil.
Matches a leading `ABC-123:' style key, which is the convention every
repo here follows."
  (when (and (stringp title)
             (string-match "\\`\\([A-Za-z]\\{2,6\\}\\)-[0-9]+" title))
    (upcase (match-string 1 title))))

(defun decknix--hub-review-workstream-score (title)
  "Return the workstream component of TITLE's priority."
  (let ((prefix (decknix--hub-review-ticket-prefix title)))
    (cond
     ((member prefix decknix--hub-review-incident-prefixes)
      decknix--hub-review-w-incident)
     ((member prefix decknix--hub-review-deferred-prefixes)
      decknix--hub-review-w-deferred)
     (t 0))))

(defun decknix--hub-review-engagement-score (item)
  "Return the engagement component for ITEM.
Exactly one band applies -- the strongest that matches -- so the bands
stay comparable to the workstream bonus rather than accumulating."
  (cond
   ((eq (map-elt item 'replies_to_me) t) decknix--hub-review-w-replies-to-me)
   ((eq (map-elt item 'needs_reply) t)   decknix--hub-review-w-needs-reply)
   ((eq (map-elt item 're_requested) t)  decknix--hub-review-w-re-requested)
   ((eq (map-elt item 'review_stale) t)  decknix--hub-review-w-stale)
   ((eq (map-elt item 'mentioned) t)     decknix--hub-review-w-mentioned)
   ((eq (map-elt item 'team_requested) t) decknix--hub-review-w-team)
   (t decknix--hub-review-w-baseline)))

(defun decknix--hub-review-age-score (age-days)
  "Return the capped age bonus for AGE-DAYS."
  (cond
   ((not (numberp age-days)) 0)
   ((< age-days 0) 0)
   (t (min (truncate age-days) decknix--hub-review-age-cap))))

(defun decknix--hub-review-priority (item &optional status age-days)
  "Return ITEM's review priority as an integer; higher sorts first.

STATUS is the staleness classification from
`decknix--hub-review-status' (`gone' sinks the item).  AGE-DAYS is days
since last activity.  Pure: every input is passed in, so an ordering can
be justified without a live feed."
  (if (eq status 'gone)
      decknix--hub-review-w-gone
    (+ (decknix--hub-review-workstream-score (map-elt item 'title))
       (decknix--hub-review-engagement-score item)
       (decknix--hub-review-age-score age-days)
       (if (eq status 'answered) decknix--hub-review-w-answered 0)
       (if (eq (map-elt item 'draft) t) decknix--hub-review-w-draft 0)
       (if (equal (map-elt item 'author_kind) "bot")
           decknix--hub-review-w-bot 0))))

(defun decknix--hub-review-priority-explain (item &optional status age-days)
  "Return a human-readable breakdown of ITEM's priority.
For `help-echo' and for arguing with the ordering when it looks wrong."
  (if (eq status 'gone)
      "gone: no review wanted"
    (let ((parts nil)
          (prefix (decknix--hub-review-ticket-prefix (map-elt item 'title))))
      (when (member prefix decknix--hub-review-incident-prefixes)
        (push (format "incident(%s) +%d" prefix decknix--hub-review-w-incident) parts))
      (when (member prefix decknix--hub-review-deferred-prefixes)
        (push (format "deferred(%s) %d" prefix decknix--hub-review-w-deferred) parts))
      (push (format "engagement +%d" (decknix--hub-review-engagement-score item)) parts)
      (let ((a (decknix--hub-review-age-score age-days)))
        (when (> a 0) (push (format "age +%d" a) parts)))
      (when (eq status 'answered)
        (push (format "answered %d" decknix--hub-review-w-answered) parts))
      (when (eq (map-elt item 'draft) t)
        (push (format "draft %d" decknix--hub-review-w-draft) parts))
      (when (equal (map-elt item 'author_kind) "bot")
        (push (format "bot %d" decknix--hub-review-w-bot) parts))
      (format "priority %d = %s"
              (decknix--hub-review-priority item status age-days)
              (string-join (nreverse parts) ", ")))))

(provide 'decknix-hub-review-priority)
;;; decknix-hub-review-priority.el ends here
