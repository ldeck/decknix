;;; decknix-review-board-model.el --- Lanes and rows for the review board -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, pr, review, board

;;; Commentary:
;;
;; The pure half of the review board: given the reviews feed and the live
;; review sessions, decide what rows exist and which lane each belongs
;; in.  Rendering, the major mode and the keymap live beside this; every
;; decision worth arguing with lives here, where it can be tested.
;;
;; The model is built from BOTH sources, and that is the load-bearing
;; detail.  A session whose PRs have all merged has no feed item left --
;; `gone' is an absence -- so a feed-driven model cannot see it at all.
;; Those are exactly the sessions still running with nothing to do, which
;; is what the board exists to surface.  Equally, a request with no
;; session has no session to enumerate.  Neither source alone is the
;; worklist.

;;; Code:

(require 'map)
(require 'seq)
;; A hard dependency, not an optional enhancement.  The group-unanimity
;; rule lives in `decknix--hub-review-status-aggregate', and the obvious
;; fallback -- take the first status -- reports `gone' for a group whose
;; first member merged while others are still open.  A silently wrong
;; answer is worse than a missing function, so require it.
(require 'decknix-hub-review-status)

(defconst decknix-review-board-lanes
  '((needs-you . "Needs you")
    (finished  . "Finished")
    (human     . "Human reviews")
    (grouped   . "Grouped")
    (idle      . "Idle"))
  "Ordered (LANE . HEADING) pairs, rendered top to bottom.

`finished' sits second, not last, on purpose: it is the cheapest lane to
clear, clearing it is what reduces the noise the board exists to reduce,
and a lane buried at the bottom never gets cleared.")

(defconst decknix-review-board-attention-states '("waiting" "asking" "netfail")
  "Session states that mean the agent is blocked on the user.
`waiting' is a permission prompt, `asking' a question at the end of a
turn, `netfail' a dropped link (#162) that will not move again until it
is reset.")

(defun decknix-review-board--attention-p (state)
  "Non-nil when a session in STATE is blocked on the user."
  (and (stringp state)
       (member state decknix-review-board-attention-states)
       t))

(defun decknix-review-board--lane (has-session attention status bot-p)
  "Return the lane for a row.  Pure.

HAS-SESSION is whether an agent is attached, ATTENTION whether that
agent is blocked on the user, STATUS the staleness classification
\(`gone' / `stale' / `answered' / nil), and BOT-P whether the author is a
bot.

Precedence is deliberate and only partly obvious:

- Attention outranks everything, including `gone'.  A session asking a
  question still wants an answer even if its PR merged underneath it; it
  may be asking precisely BECAUSE the PR merged.
- `finished' outranks the author split.  Once no review is wanted, which
  kind of author wrote it stops being interesting.
- Bot rows fold whether or not a session exists.  The flood is forty
  bumps, not forty sessions.
- A human request with no session is `idle': individually authored, so
  there is nothing to fold it into."
  (cond
   ((and has-session attention) 'needs-you)
   ((and has-session (eq status 'gone)) 'finished)
   ;; Bot rows fold whether or not anyone is on them yet.  Grouping is a
   ;; property of the WORK, not of whether a session happens to exist:
   ;; forty un-dispatched dependabot bumps are the flood this board was
   ;; built for, and listing them individually would reproduce it
   ;; faithfully on a screen meant to remove it.
   (bot-p 'grouped)
   ((not has-session) 'idle)
   (t 'human)))

(defun decknix-review-board--session-row (session status-fn priority-fn)
  "Build a row plist for SESSION.

SESSION is a plist with `:name', `:conv-key', `:prs' (a list of
`repo#number'), `:state' and `:bot-p'.  STATUS-FN maps a PR key to its
staleness status; PRIORITY-FN maps a PR key to its priority.

A row's priority is its STRONGEST member, so one urgent bump lifts its
whole group rather than being buried inside it."
  (let* ((prs (plist-get session :prs))
         ;; One status per PR, nils INCLUDED.  A nil means "still plainly
         ;; wanted", which is the member that keeps a group alive --
         ;; dropping nils here would hand the aggregate a list of only
         ;; the finished members and it would report unanimity, defeating
         ;; the very rule it exists to enforce.
         (statuses (mapcar status-fn prs))
         (priorities (delq nil (mapcar priority-fn prs)))
         (attention (decknix-review-board--attention-p (plist-get session :state))))
    (list :kind (if (> (length prs) 1) 'group 'single)
          :name (plist-get session :name)
          :conv-key (plist-get session :conv-key)
          :prs prs
          :state (plist-get session :state)
          :statuses statuses
          :priority (if priorities (apply #'max priorities) 0)
          :session t
          :lane (decknix-review-board--lane
                 t attention
                 ;; A group is finished only when every member is; the
                 ;; aggregate encodes that unanimity rule.
                 (decknix--hub-review-status-aggregate statuses)
                 (plist-get session :bot-p)))))

(defun decknix-review-board--covered-p (pr-key sessions)
  "Non-nil when PR-KEY appears in any SESSIONS entry's `:prs'."
  (seq-some (lambda (s) (member pr-key (plist-get s :prs))) sessions))

(defun decknix-review-board-build (items sessions key-fn status-fn priority-fn bot-fn)
  "Return the board model: an alist of (LANE . ROWS).  Pure.

ITEMS is the reviews feed, SESSIONS the live review sessions (see
`decknix-review-board--session-row').  KEY-FN maps a feed item to its
`repo#number', STATUS-FN and PRIORITY-FN map a key to its status and
priority, BOT-FN maps a feed item to whether its author is a bot.

Every session becomes a row.  Every feed item NOT already covered by a
session becomes an `idle' row.  The asymmetry is the point: a session
outlives its feed item, and a request precedes its session, so the two
sources have to be unioned rather than either taken as the worklist.

Rows sort by priority descending within each lane.  Empty lanes are
retained, so a lane's position on screen is learnable rather than
shifting with the contents."
  (let* ((session-rows (mapcar (lambda (s)
                                 (decknix-review-board--session-row
                                  s status-fn priority-fn))
                               sessions))
         (uncovered (seq-filter
                     (lambda (item)
                       (let ((key (funcall key-fn item)))
                         (and key (not (decknix-review-board--covered-p key sessions)))))
                     items))
         ;; Human requests stay individual; bot requests fold by repo, so
         ;; a service's un-dispatched bumps occupy one row rather than
         ;; forty.  Same rule the dispatcher groups by, so a row here is
         ;; exactly what would be launched as one session.
         (human-idle (seq-remove (lambda (i) (funcall bot-fn i)) uncovered))
         (bot-idle (seq-filter (lambda (i) (funcall bot-fn i)) uncovered))
         (bot-groups (let (acc)
                       (dolist (item bot-idle)
                         (let* ((repo (car (last (split-string
                                                  (or (map-elt item 'repo) "") "/"))))
                                (cell (assoc repo acc)))
                           (if cell (setcdr cell (cons item (cdr cell)))
                             (push (cons repo (list item)) acc))))
                       (nreverse acc)))
         (idle-rows
          (append
           (mapcar
            (lambda (item)
              (let ((key (funcall key-fn item)))
                (list :kind 'single :name key :conv-key nil :prs (list key)
                      :state nil :statuses (list (funcall status-fn key))
                      :priority (or (funcall priority-fn key) 0)
                      :item item :session nil
                      :lane (decknix-review-board--lane nil nil nil nil))))
            human-idle)
           (mapcar
            (lambda (cell)
              (let* ((group (nreverse (cdr cell)))
                     (keys (delq nil (mapcar key-fn group)))
                     (priorities (mapcar (lambda (k) (or (funcall priority-fn k) 0)) keys)))
                (list :kind (if (> (length keys) 1) 'group 'single)
                      :name (car cell) :conv-key nil :prs keys
                      :state nil :statuses (mapcar status-fn keys)
                      ;; Strongest member, so one urgent bump lifts its
                      ;; service rather than hiding inside it.
                      :priority (if priorities (apply #'max priorities) 0)
                      :items group :session nil
                      :lane (decknix-review-board--lane nil nil nil t))))
            bot-groups)))
         (all (append session-rows idle-rows)))
    (mapcar
     (lambda (lane)
       (cons (car lane)
             (sort (seq-filter (lambda (r) (eq (plist-get r :lane) (car lane))) all)
                   (lambda (a b) (> (plist-get a :priority)
                                    (plist-get b :priority))))))
     decknix-review-board-lanes)))

(defun decknix-review-board-count (model)
  "Return the total number of rows in MODEL."
  (apply #'+ (mapcar (lambda (lane) (length (cdr lane))) model)))


;; ── marks and verb targeting ─────────────────────────────────────────

(defun decknix-review-board-row-key (row)
  "Return a stable identity for ROW, for carrying marks across refreshes.

A session's conv-key is stable; an unstarted row has none, so its PR set
stands in.  A group's key therefore CHANGES when a member merges, which
drops the mark -- correct rather than unfortunate: the thing that was
marked is not the thing now on screen."
  (or (plist-get row :conv-key)
      (mapconcat #'identity (plist-get row :prs) ",")))

(defconst decknix-review-board-session-verbs '(jump quit detach)
  "Verbs that need a live session to act on.")

(defconst decknix-review-board-unstarted-verbs '(dispatch)
  "Verbs that only make sense for a row with no session yet.")

(defun decknix-review-board-verb-applicable-p (verb row)
  "Non-nil when VERB can act on ROW."
  (let ((has-session (and (plist-get row :session) t)))
    (cond
     ((memq verb decknix-review-board-session-verbs) has-session)
     ((memq verb decknix-review-board-unstarted-verbs) (not has-session))
     (t t))))

(defun decknix-review-board-partition-targets (verb rows)
  "Split ROWS into (ACTIONABLE . SKIPPED) for VERB.  Pure.

Skipped rows are returned rather than dropped so the caller can SAY what
it did not do.  Marking five rows and pressing a key that quietly acts on
three is the failure mode this exists to prevent: the two that were
ignored look identical to the two that succeeded."
  (let (ok skip)
    (dolist (row rows)
      (if (decknix-review-board-verb-applicable-p verb row)
          (push row ok)
        (push row skip)))
    (cons (nreverse ok) (nreverse skip))))

(defun decknix-review-board-rows (model)
  "Return every row in MODEL, in lane order."
  (apply #'append (mapcar #'cdr model)))

(defun decknix-review-board-lane-rows (model lane)
  "Return the rows of LANE in MODEL."
  (alist-get lane model))


;; ── shipping ─────────────────────────────────────────────────────────
;;
;; The board never posts to GitHub itself.  It builds a plan and hands it
;; to `/merge-train', which owns train ordering and its own confirmation
;; gate.  There is deliberately no `approve' verb: `submit-pr-review' is
;; deprecated, and approval now happens INSIDE `/review-service-pr' and
;; `/review-and-ship-bot-pr', behind the mandatory review gate.  A board
;; verb that approved directly would route around that gate, which the
;; workflow rules treat as a serious failure rather than a shortcut.

(defun decknix-review-board-ship-blocker (row status)
  "Return why ROW cannot be shipped, or nil when it can.  Pure.

STATUS is the row's aggregated staleness.  The refusals are the ones that
cannot be recovered from afterwards:

- `stale': the author pushed since, so whatever approval exists was
  earned by a different diff.  Merging it merges something nobody read.
- `gone': already merged, closed, or no longer requested.  There is
  nothing left to merge, and trying would be noise at best.
- no PR numbers: nothing to name in the train."
  (cond
   ((eq status 'stale) "author pushed since review")
   ((eq status 'gone) "already merged or closed")
   ((null (plist-get row :prs)) "no PR")
   (t nil)))

(defun decknix-review-board--row-repo (row)
  "Return ROW's repo, from the first PR key."
  (when-let* ((key (car (plist-get row :prs))))
    (when (string-match "\\`\\(.+\\)#[0-9]+\\'" key)
      (match-string 1 key))))

(defun decknix-review-board--row-numbers (row)
  "Return ROW's PR numbers as strings."
  (delq nil (mapcar (lambda (k)
                      (when (string-match "\\`.+#\\([0-9]+\\)\\'" k)
                        (match-string 1 k)))
                    (plist-get row :prs))))

(defun decknix-review-board-ship-plan (rows status-fn)
  "Return (BY-REPO . BLOCKED) for shipping ROWS.  Pure.

BY-REPO is an alist of (REPO . NUMBERS); BLOCKED is a list of
(ROW . REASON).  Grouped by repo because `/merge-train' takes bare PR
numbers and resolves the repository from its workspace -- one train per
repo, never a mixed list that would merge into whichever repo happened to
be current.

Blocked rows are returned, not filtered away.  A ship that silently
dropped the stale ones would look identical to a ship that merged them."
  (let (by-repo blocked)
    (dolist (row rows)
      (let ((reason (decknix-review-board-ship-blocker
                     row (funcall status-fn row))))
        (if reason
            (push (cons row reason) blocked)
          (let* ((repo (decknix-review-board--row-repo row))
                 (nums (decknix-review-board--row-numbers row))
                 (cell (assoc repo by-repo)))
            (if cell
                (setcdr cell (append (cdr cell) nums))
              (push (cons repo nums) by-repo))))))
    (cons (nreverse by-repo) (nreverse blocked))))

(provide 'decknix-review-board-model)
;;; decknix-review-board-model.el ends here
