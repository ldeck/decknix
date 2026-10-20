;;; decknix-review-board-model-test.el --- Tests for the review board model -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification tests for lane assignment and row building.  The
;; interesting cases are the ones where two signals disagree: a session
;; asking a question about a PR that merged underneath it, a group where
;; only some members are done, and a session that outlives its feed item
;; entirely.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-review-board-model)
(require 'decknix-review-gate-fixtures)

;; --- lane precedence ---

(ert-deftest decknix-rb--gone-outranks-attention ()
  "A blocked session whose PR is GONE is `finished', not `needs-you'.

This reverses an earlier decision. The argument for keeping it in
`needs-you' was that the session might be asking precisely BECAUSE the PR
merged. In practice the board filled with questions about PRs the author
had already merged, and the lane whose entire job is \"these want you
now\" stopped meaning that. A question about finished work is still
answerable from `finished'; a needs-you lane you have learned to distrust
is not recoverable.

Attention still outranks everything ELSE: `stale' and `answered' are
statements about the PR, not about whether the agent is stuck."
  (should (eq 'finished (decknix-review-board--lane t t 'gone nil)))
  (should (eq 'needs-you (decknix-review-board--lane t t nil t)))
  (should (eq 'needs-you (decknix-review-board--lane t t 'stale nil)))
  (should (eq 'needs-you (decknix-review-board--lane t t 'answered nil))))

;; --- row face: urgency must reflect the PR, not just the agent ---

(ert-deftest decknix-rb--face-red-only-when-nobody-has-covered-it ()
  "Red is reserved for a blocked session on a PR nobody else has touched."
  (should (eq 'decknix-review-board-needs-you
              (decknix-review-board--row-face t nil))))

(ert-deftest decknix-rb--face-calmer-once-somebody-else-answered ()
  "Approved or reviewed by someone else: still yours, but not urgent.
The work may already be covered, so it must not compete visually with a
review nobody has looked at."
  (should (eq 'decknix-review-board-covered
              (decknix-review-board--row-face t 'answered))))

(ert-deftest decknix-rb--face-calmer-when-the-diff-moved ()
  "A stale review is not urgent either: the analysis is void until re-run."
  (should (eq 'decknix-review-board-covered
              (decknix-review-board--row-face t 'stale))))

(ert-deftest decknix-rb--face-nil-without-attention ()
  "Rows that are not blocked carry no urgency face at all."
  (should-not (decknix-review-board--row-face nil nil))
  (should-not (decknix-review-board--row-face nil 'answered))
  (should-not (decknix-review-board--row-face nil 'gone)))

(ert-deftest decknix-rb--gone-session-is-finished ()
  "A session whose PR left the queue is finished work, whoever wrote it."
  (should (eq 'finished (decknix-review-board--lane t nil 'gone nil)))
  (should (eq 'finished (decknix-review-board--lane t nil 'gone t))))

(ert-deftest decknix-rb--any-live-session-is-doing ()
  "A live session not blocked and not gone is `doing', whoever authored it.
A bot session that has been dispatched is one session doing work, not part
of the un-dispatched flood, so it shows individually in the activity lane
rather than folding into `grouped'."
  (should (eq 'doing (decknix-review-board--lane t nil nil t)))
  (should (eq 'doing (decknix-review-board--lane t nil nil nil))))

(ert-deftest decknix-rb--unsessioned-human-is-idle-bot-is-grouped ()
  "Bot rows fold whether or not anyone is on them yet.

Grouping is a property of the WORK, not of whether a session exists.
Rendering forty un-dispatched dependabot bumps as forty Idle rows would
reproduce the flood faithfully on the screen built to remove it.  A human
request has nothing to fold into, so it stays individual."
  (should (eq 'grouped (decknix-review-board--lane nil nil nil t)))
  (should (eq 'idle    (decknix-review-board--lane nil nil nil nil))))

(ert-deftest decknix-rb--stale-and-answered-do-not-change-lane ()
  "Only `gone' moves a session out of its author lane.
`stale' and `answered' are badges on a row that still needs working."
  (should (eq 'doing (decknix-review-board--lane t nil 'stale nil)))
  (should (eq 'doing (decknix-review-board--lane t nil 'answered nil))))

;; --- attention states ---

(ert-deftest decknix-rb--attention-states ()
  "Blocked states are exactly the three that will not move unaided."
  (should (decknix-review-board--attention-p "waiting"))
  (should (decknix-review-board--attention-p "asking"))
  (should (decknix-review-board--attention-p "netfail"))
  (should-not (decknix-review-board--attention-p "busy"))
  (should-not (decknix-review-board--attention-p "ready"))
  (should-not (decknix-review-board--attention-p nil)))

;; --- rows ---

(defun decknix-rb-test--status (key)
  (pcase key ("a#1" 'gone) ("a#2" 'gone) ("a#3" nil) ("b#9" 'stale) (_ nil)))
(defun decknix-rb-test--priority (key)
  (pcase key ("a#1" 10) ("a#2" 90) ("a#3" 20) ("b#9" 50) (_ 0)))

(ert-deftest decknix-rb--group-priority-is-its-strongest-member ()
  "One urgent bump lifts its group rather than being buried in it."
  (let ((row (decknix-review-board--session-row
              '(:name "pr-a-group" :prs ("a#1" "a#2") :state "ready" :bot-p t)
              #'decknix-rb-test--status #'decknix-rb-test--priority)))
    (should (= 90 (plist-get row :priority)))
    (should (eq 'group (plist-get row :kind)))))

(ert-deftest decknix-rb--partly-merged-group-is-not-finished ()
  "A group with one live member is still work.
Filing it under `finished' would invite quitting a session that still
has a PR under it."
  (let ((row (decknix-review-board--session-row
              '(:name "g" :prs ("a#1" "a#3") :state "ready" :bot-p t)
              #'decknix-rb-test--status #'decknix-rb-test--priority)))
    (should (eq 'doing (plist-get row :lane)))))

(ert-deftest decknix-rb--fully-merged-group-is-finished ()
  "Every member gone means the session has nothing left to do."
  (let ((row (decknix-review-board--session-row
              '(:name "g" :prs ("a#1" "a#2") :state "ready" :bot-p t)
              #'decknix-rb-test--status #'decknix-rb-test--priority)))
    (should (eq 'finished (plist-get row :lane)))))

;; --- the union of feed and sessions ---

(defun decknix-rb-test--key (item) (map-elt item 'key))
(defun decknix-rb-test--bot (item) (eq t (map-elt item 'bot)))

(ert-deftest decknix-rb--session-without-a-feed-item-still-appears ()
  "The motivating case: a session outlives its request.
`gone' is an ABSENCE from the feed, so a feed-driven model cannot see
these at all -- and they are exactly the sessions still running with
nothing to do."
  (let* ((model (decknix-review-board-build
                 nil
                 '((:name "s" :prs ("a#1") :state "ready" :bot-p nil))
                 #'decknix-rb-test--key #'decknix-rb-test--status
                 #'decknix-rb-test--priority #'decknix-rb-test--bot)))
    (should (= 1 (length (alist-get 'finished model))))))

(ert-deftest decknix-rb--request-without-a-session-is-idle ()
  "A request precedes its session, so the feed contributes rows too."
  (let* ((model (decknix-review-board-build
                 '(((key . "a#3") (bot . nil))) nil
                 #'decknix-rb-test--key #'decknix-rb-test--status
                 #'decknix-rb-test--priority #'decknix-rb-test--bot)))
    (should (= 1 (length (alist-get 'idle model))))))

(ert-deftest decknix-rb--covered-request-does-not-double-up ()
  "A PR with a session appears once, as the session, not twice."
  (let* ((model (decknix-review-board-build
                 '(((key . "a#3") (bot . nil)))
                 '((:name "s" :prs ("a#3") :state "ready" :bot-p nil))
                 #'decknix-rb-test--key #'decknix-rb-test--status
                 #'decknix-rb-test--priority #'decknix-rb-test--bot)))
    (should (= 1 (decknix-review-board-count model)))
    (should-not (alist-get 'idle model))))

(ert-deftest decknix-rb--group-member-does-not-resurface-as-idle ()
  "Every member of a group counts as covered, not just the first.
Membership, not the head of the list -- otherwise four of five bumps
would reappear as idle rows and invite a second dispatch."
  (let* ((model (decknix-review-board-build
                 '(((key . "a#1") (bot . t)) ((key . "a#3") (bot . t)))
                 '((:name "g" :prs ("a#1" "a#3") :state "ready" :bot-p t))
                 #'decknix-rb-test--key #'decknix-rb-test--status
                 #'decknix-rb-test--priority #'decknix-rb-test--bot)))
    (should-not (alist-get 'idle model))
    (should (= 1 (decknix-review-board-count model)))))

;; --- lanes and ordering ---

(ert-deftest decknix-rb--empty-lanes-are-retained ()
  "Every lane is present so its position on screen is learnable."
  (let ((model (decknix-review-board-build nil nil
                                           #'decknix-rb-test--key
                                           #'decknix-rb-test--status
                                           #'decknix-rb-test--priority
                                           #'decknix-rb-test--bot)))
    (should (= (length decknix-review-board-lanes) (length model)))
    (should (= 0 (decknix-review-board-count model)))))

(ert-deftest decknix-rb--lane-order-is-fixed ()
  "Lifecycle order: blocked on you, then in progress, then waiting on the
author, then done, then the un-started backlog.  The lanes you clear stay
high, not buried."
  (should (equal '(needs-you doing on-hold finished grouped idle)
                 (mapcar #'car decknix-review-board-lanes))))

(ert-deftest decknix-rb--rows-sort-by-priority-within-a-lane ()
  "Highest priority first, so the top row is the next thing to do."
  (let* ((model (decknix-review-board-build
                 '(((key . "a#3") (bot . nil)) ((key . "b#9") (bot . nil)))
                 nil
                 #'decknix-rb-test--key #'decknix-rb-test--status
                 #'decknix-rb-test--priority #'decknix-rb-test--bot))
         (idle (alist-get 'idle model)))
    (should (equal '("b#9" "a#3") (mapcar (lambda (r) (plist-get r :name)) idle)))))


;; --- un-dispatched bot requests fold by repo ---

(ert-deftest decknix-rb--idle-bots-fold-by-repo ()
  "A service's un-dispatched bumps occupy one row, not five."
  (let* ((items (mapcar (lambda (n) `((key . ,(format "a#%d" n)) (repo . "org/a") (bot . t)))
                        '(1 2 3 4 5)))
         (model (decknix-review-board-build
                 items nil #'decknix-rb-test--key #'decknix-rb-test--status
                 #'decknix-rb-test--priority #'decknix-rb-test--bot))
         (grouped (alist-get 'grouped model)))
    (should (= 1 (length grouped)))
    (should (= 5 (length (plist-get (car grouped) :prs))))
    (should-not (alist-get 'idle model))))

(ert-deftest decknix-rb--idle-bots-split-across-repos ()
  "Folding is per service, so two repos remain two rows."
  (let* ((items '(((key . "a#1") (repo . "org/a") (bot . t))
                  ((key . "b#9") (repo . "org/b") (bot . t))))
         (model (decknix-review-board-build
                 items nil #'decknix-rb-test--key #'decknix-rb-test--status
                 #'decknix-rb-test--priority #'decknix-rb-test--bot)))
    (should (= 2 (length (alist-get 'grouped model))))))

(ert-deftest decknix-rb--idle-group-priority-is-strongest-member ()
  "One urgent bump lifts its service rather than hiding inside it."
  (let* ((items '(((key . "a#1") (repo . "org/a") (bot . t))
                  ((key . "a#2") (repo . "org/a") (bot . t))))
         (model (decknix-review-board-build
                 items nil #'decknix-rb-test--key #'decknix-rb-test--status
                 #'decknix-rb-test--priority #'decknix-rb-test--bot)))
    ;; a#2 scores 90, a#1 scores 10.
    (should (= 90 (plist-get (car (alist-get 'grouped model)) :priority)))))

(ert-deftest decknix-rb--humans-never-fold ()
  "Two human requests on one repo stay two rows."
  (let* ((items '(((key . "a#1") (repo . "org/a") (bot . nil))
                  ((key . "a#3") (repo . "org/a") (bot . nil))))
         (model (decknix-review-board-build
                 items nil #'decknix-rb-test--key #'decknix-rb-test--status
                 #'decknix-rb-test--priority #'decknix-rb-test--bot)))
    (should (= 2 (length (alist-get 'idle model))))))


;; --- marks and verb targeting ---

(ert-deftest decknix-rb--row-key-prefers-conv-key ()
  "A session's identity is its conv-key, which survives renaming."
  (should (equal "ck1" (decknix-review-board-row-key
                        '(:conv-key "ck1" :prs ("a#1")))))
  (should (equal "a#1,a#2" (decknix-review-board-row-key
                            '(:conv-key nil :prs ("a#1" "a#2"))))))

(ert-deftest decknix-rb--dispatch-only-targets-unstarted-rows ()
  "Dispatching a row that already has an agent would duplicate it."
  (should (decknix-review-board-verb-applicable-p 'dispatch '(:session nil)))
  (should-not (decknix-review-board-verb-applicable-p 'dispatch '(:session t))))

(ert-deftest decknix-rb--session-verbs-need-a-session ()
  "Quit, detach and jump have nothing to act on without one."
  (dolist (v '(quit detach jump))
    (should (decknix-review-board-verb-applicable-p v '(:session t)))
    (should-not (decknix-review-board-verb-applicable-p v '(:session nil)))))

(ert-deftest decknix-rb--partition-reports-what-it-skipped ()
  "Skipped rows come back, so the caller can say what it did not do.
Marking five and quietly acting on three is the failure this prevents:
the two ignored look exactly like the two that worked."
  (let* ((rows '((:session t :prs ("a#1")) (:session nil :prs ("a#2"))
                 (:session t :prs ("a#3"))))
         (part (decknix-review-board-partition-targets 'quit rows)))
    (should (= 2 (length (car part))))
    (should (= 1 (length (cdr part))))))

(ert-deftest decknix-rb--partition-of-nothing-is-empty ()
  "No rows yields no work and no complaints."
  (should (equal '(nil) (decknix-review-board-partition-targets 'quit nil))))


;; --- shipping refuses what cannot be undone ---

(ert-deftest decknix-rb--ship-refuses-stale ()
  "A stale row must never ship: the approval was earned by another diff.
Merging it merges something nobody read."
  (should (equal "author pushed since review"
                 (decknix-review-board-merge-blocker '(:prs ("a#1")) 'stale))))

(ert-deftest decknix-rb--ship-refuses-gone ()
  "Nothing left to merge."
  (should (decknix-review-board-merge-blocker '(:prs ("a#1")) 'gone)))

(ert-deftest decknix-rb--ship-refuses-rows-without-prs ()
  "Nothing to name in the train."
  (should (decknix-review-board-merge-blocker '(:prs nil) nil)))

(ert-deftest decknix-rb--ship-allows-answered-and-plain ()
  "`answered' is not a blocker: somebody else reviewing it does not make
it unmergeable, and a plain row is the ordinary case."
  (should-not (decknix-review-board-merge-blocker '(:prs ("a#1")) 'answered))
  (should-not (decknix-review-board-merge-blocker '(:prs ("a#1")) nil)))

(ert-deftest decknix-rb--ship-plan-groups-by-repo ()
  "`/merge-train' takes bare PR numbers and resolves the repo from its
workspace, so a mixed list would merge into whichever repo was current."
  (let* ((rows '((:prs ("a#1" "a#2")) (:prs ("b#9"))))
         (plan (decknix-review-board-merge-plan rows (lambda (_) nil)))
         (by-repo (car plan)))
    (should (= 2 (length by-repo)))
    (should (equal '("1" "2") (alist-get "a" by-repo nil nil #'equal)))
    (should (equal '("9") (alist-get "b" by-repo nil nil #'equal)))))

(ert-deftest decknix-rb--ship-plan-merges-rows-of-one-repo ()
  "Two rows on one repo become one train, not two."
  (let* ((rows '((:prs ("a#1")) (:prs ("a#2"))))
         (plan (decknix-review-board-merge-plan rows (lambda (_) nil))))
    (should (= 1 (length (car plan))))
    (should (equal '("1" "2") (cdar (car plan))))))

(ert-deftest decknix-rb--ship-plan-returns-blocked-rows ()
  "Blocked rows come back with a reason rather than vanishing.
A ship that silently dropped the stale ones would look identical to one
that merged them."
  (let* ((rows '((:prs ("a#1")) (:prs ("a#2"))))
         (plan (decknix-review-board-merge-plan
                rows (lambda (r) (when (equal '("a#2") (plist-get r :prs)) 'stale)))))
    (should (= 1 (length (car plan))))
    (should (= 1 (length (cdr plan))))
    (should (equal "author pushed since review" (cdar (cdr plan))))))


;; --- a row must carry what the verbs need ---

(ert-deftest decknix-rb--session-row-carries-its-buffer ()
  "`:buffer' survives into the row.

Dropped, the row still reported `:session t' while `jump', `quit' and
`detach' all had nothing to act on -- three of the four acting keys
inert, and the board looking correct throughout.  Lane assignment being
right is not the same as a row being usable."
  (let ((row (decknix-review-board--session-row
              '(:name "s" :buffer :the-buffer :prs ("a#3")
                :state "ready" :bot-p nil)
              #'decknix-rb-test--status #'decknix-rb-test--priority)))
    (should (eq :the-buffer (plist-get row :buffer)))))

(ert-deftest decknix-rb--build-preserves-buffer-through-lanes ()
  "The buffer survives `decknix-review-board-build', not just the row
builder -- that is the path the board actually uses."
  (let* ((model (decknix-review-board-build
                 nil
                 '((:name "s" :buffer :the-buffer :prs ("a#3")
                    :state "ready" :bot-p nil))
                 #'decknix-rb-test--key #'decknix-rb-test--status
                 #'decknix-rb-test--priority #'decknix-rb-test--bot))
         (row (car (decknix-review-board-rows model))))
    (should (eq :the-buffer (plist-get row :buffer)))))


;; --- bot PRs never ship via merge-train ---

(ert-deftest decknix-rb--ship-refuses-bot-rows ()
  "A dependency bump must not be rebase-merged by merge-train.

The house process is `/ship' / `/review-and-ship-bot-pr', which runs a
pre-merge validation round in development first; merge-train
rebase-merges ALREADY-APPROVED PRs and skips it.  Shipping a bump that
way merges it without the round that would have caught a regression."
  (should (equal "bot PR — ship via `d' (review-and-ship), not merge-train"
                 (decknix-review-board-merge-blocker
                  '(:prs ("a#1") :bot-p t) nil))))

(ert-deftest decknix-rb--ship-allows-human-rows ()
  "Human PRs are exactly what merge-train is for."
  (should-not (decknix-review-board-merge-blocker '(:prs ("a#1") :bot-p nil) nil)))

(ert-deftest decknix-rb--bot-flag-survives-into-rows ()
  "`:bot-p' reaches the row, or the ship guard cannot fire."
  (let ((session-row (decknix-review-board--session-row
                      '(:name "s" :prs ("a#3") :state "ready" :bot-p t)
                      #'decknix-rb-test--status #'decknix-rb-test--priority))
        (model (decknix-review-board-build
                '(((key . "a#1") (repo . "org/a") (bot . t)))
                nil #'decknix-rb-test--key #'decknix-rb-test--status
                #'decknix-rb-test--priority #'decknix-rb-test--bot)))
    (should (plist-get session-row :bot-p))
    (should (plist-get (car (alist-get 'grouped model)) :bot-p))))


;; --- the activity lane carries verb and progress -----------------------

(ert-deftest decknix-rb--doing-lane-exists-and-sits-after-needs-you ()
  "`doing' is a lane, ordered between `needs-you' and `finished'."
  (let ((lanes (mapcar #'car decknix-review-board-lanes)))
    (should (memq 'doing lanes))
    (should (< (seq-position lanes 'needs-you)
               (seq-position lanes 'doing)))
    (should (< (seq-position lanes 'doing)
               (seq-position lanes 'finished)))))

(ert-deftest decknix-rb--session-row-carries-verb-and-progress ()
  "A session's activity verb and progress ride on its row for the renderer."
  (let ((row (decknix-review-board--session-row
              '(:name "n" :prs ("a#3") :state "working" :bot-p nil
                :verb "merge" :progress "3/5")
              #'decknix-rb-test--status #'decknix-rb-test--priority)))
    (should (equal "merge" (plist-get row :verb)))
    (should (equal "3/5" (plist-get row :progress)))
    (should (eq 'doing (plist-get row :lane)))))

(ert-deftest decknix-rb--session-row-tolerates-absent-verb-and-progress ()
  "A session with no dispatched verb or plan still builds a doing row."
  (let ((row (decknix-review-board--session-row
              '(:name "n" :prs ("a#3") :state "ready" :bot-p nil)
              #'decknix-rb-test--status #'decknix-rb-test--priority)))
    (should-not (plist-get row :verb))
    (should-not (plist-get row :progress))
    (should (eq 'doing (plist-get row :lane)))))


;; --- activity verb from the session's intent tags ---------------------

(ert-deftest decknix-rb--activity-verb-reads-review ()
  (should (equal "review"
                 (decknix-review-board-activity-verb '("auto" "#1" "upside" "review")))))

(ert-deftest decknix-rb--activity-verb-reads-merge ()
  (should (equal "merge"
                 (decknix-review-board-activity-verb '("merge" "upside" "train")))))

(ert-deftest decknix-rb--activity-verb-prefers-the-more-specific-action ()
  "ship and merge outrank review; fix (an action taken) outranks review."
  (should (equal "ship" (decknix-review-board-activity-verb '("ship" "review"))))
  (should (equal "merge" (decknix-review-board-activity-verb '("merge" "review"))))
  (should (equal "fix" (decknix-review-board-activity-verb '("review" "fix")))))

(ert-deftest decknix-rb--activity-verb-nil-when-none-known ()
  (should-not (decknix-review-board-activity-verb '("upside" "#5" "hot")))
  (should-not (decknix-review-board-activity-verb nil)))


;; --- auto-dismiss drops finished rows ---------------------------------

(ert-deftest decknix-rb--drop-finished-empties-that-lane-only ()
  "Auto-dismiss drops finished rows and touches nothing else."
  (let* ((model '((needs-you . (r1))
                  (doing     . (r2 r3))
                  (finished  . (r4 r5))
                  (grouped   . (r6))
                  (idle      . nil)))
         (out (decknix-review-board-drop-finished model)))
    (should-not (alist-get 'finished out))
    (should (equal '(r1) (alist-get 'needs-you out)))
    (should (equal '(r2 r3) (alist-get 'doing out)))
    (should (equal '(r6) (alist-get 'grouped out)))))

(ert-deftest decknix-rb--drop-finished-keeps-the-lane-present ()
  "The lane stays (empty) so its screen position is learnable."
  (let ((out (decknix-review-board-drop-finished '((finished . (r1))))))
    (should (assq 'finished out))
    (should-not (alist-get 'finished out))))


;; --- initiating a review from a pasted url ---------------------------

(ert-deftest decknix-rb-urls--takes-a-single-url ()
  (should (equal '("https://github.com/o/r/pull/12")
                 (decknix-review-board--parse-urls
                  "https://github.com/o/r/pull/12"))))

(ert-deftest decknix-rb-urls--extracts-from-surrounding-prose ()
  "A line copied out of Slack must work without hand-editing."
  (should (equal '("https://github.com/o/r/pull/12")
                 (decknix-review-board--parse-urls
                  "please review https://github.com/o/r/pull/12 when you can"))))

(ert-deftest decknix-rb-urls--takes-several-in-order ()
  (should (equal '("https://github.com/o/r/pull/1" "https://github.com/o/r/pull/2")
                 (decknix-review-board--parse-urls
                  "https://github.com/o/r/pull/1, https://github.com/o/r/pull/2"))))

(ert-deftest decknix-rb-urls--drops-duplicates ()
  "Two sessions racing on one review is the problem this board removes."
  (should (equal '("https://github.com/o/r/pull/7")
                 (decknix-review-board--parse-urls
                  "https://github.com/o/r/pull/7 https://github.com/o/r/pull/7"))))

(ert-deftest decknix-rb-urls--rejects-non-pr-github-links ()
  "An issue or compare link must not be dispatched as a review."
  (should-not (decknix-review-board--parse-urls "https://github.com/o/r/issues/12"))
  (should-not (decknix-review-board--parse-urls "https://github.com/o/r/commit/abc"))
  (should-not (decknix-review-board--parse-urls "https://github.com/o/r")))

(ert-deftest decknix-rb-urls--empty-and-nil-are-nil ()
  (should-not (decknix-review-board--parse-urls ""))
  (should-not (decknix-review-board--parse-urls nil))
  (should-not (decknix-review-board--parse-urls "no urls here")))

;; -- owner/repo#N shorthand -------------------------------------------
;;
;; Requiring the expanded url meant retyping what GitHub had already rendered
;; in a Slack paste or a PR body. Reported alongside the sidebar having no
;; url verb at all: `r' opened a nav transient whose keys are generated per
;; row, so a pasted url could never match and reported "no match".

(ert-deftest decknix-board-urls--accepts-shorthand ()
  "`owner/repo#N' expands to a PR url."
  (should (equal '("https://github.com/UpsideRealty/reapit-service/pull/244")
                 (decknix-review-board--parse-urls
                  "UpsideRealty/reapit-service#244"))))

(ert-deftest decknix-board-urls--several-shorthands-in-one-paste ()
  "A comma-separated Slack line yields both, in order."
  (should (equal '("https://github.com/UpsideRealty/upside/pull/17178"
                   "https://github.com/UpsideRealty/upside/pull/16823")
                 (decknix-review-board--parse-urls
                  "UpsideRealty/upside#17178, UpsideRealty/upside#16823"))))

(ert-deftest decknix-board-urls--a-url-and-its-own-shorthand-dedupe ()
  "The same PR written both ways starts ONE session, not two.
Dispatching twice would put two sessions on one review, which is the
duplicate-reviewer problem the board exists to remove."
  (should (equal '("https://github.com/o/r/pull/5")
                 (decknix-review-board--parse-urls
                  "https://github.com/o/r/pull/5 and o/r#5"))))

(ert-deftest decknix-board-urls--prose-without-a-reference-is-nil ()
  "Free text with no PR reference still yields nothing."
  (should-not (decknix-review-board--parse-urls "no url here"))
  (should-not (decknix-review-board--parse-urls "issue #244"))
  (should-not (decknix-review-board--parse-urls nil)))



;; --- my own review settles the row ------------------------------------

(ert-deftest decknix-rb--my-approval-marks-the-row-reviewed ()
  "Approving a PR from the board left its row exactly as before: the
classifier asked only whether SOMEBODY ELSE had reviewed.  Measured on
attom-integration#325 -- my_review APPROVED, others_reviewed nil,
review_decision empty -- which classified as nil, still wanted."
  (should (eq 'reviewed
              (decknix--hub-review-status
               '((my_review . "APPROVED") (others_reviewed . nil)
                 (review_decision . ""))
               t))))

(ert-deftest decknix-rb--my-changes-requested-also-settles ()
  (should (eq 'reviewed
              (decknix--hub-review-status
               '((my_review . "CHANGES_REQUESTED")) t))))

(ert-deftest decknix-rb--my-review-outranks-someone-elses ()
  "Once I have decided, the row wants nothing from me whatever the others
are doing."
  (should (eq 'reviewed
              (decknix--hub-review-status
               '((my_review . "APPROVED") (others_reviewed . t)) t))))

(ert-deftest decknix-rb--a-stale-pr-outranks-my-review ()
  "The author pushed, so my approval is against a diff that no longer
exists -- telling me the analysis is void is more useful."
  (should (eq 'stale
              (decknix--hub-review-status
               '((review_stale . t) (my_review . "APPROVED")) t))))

(ert-deftest decknix-rb--a-merged-pr-still-outranks-my-review ()
  (should (eq 'gone (decknix--hub-review-status
                     '((my_review . "APPROVED")) nil))))

(ert-deftest decknix-rb--an-unreviewed-pr-is-still-wanted ()
  (should-not (decknix--hub-review-status
               '((my_review . "") (review_decision . "REVIEW_REQUIRED")) t)))

(ert-deftest decknix-rb--a-reviewed-row-leaves-the-active-lanes ()
  "An approved PR sat in `doing\=' as though still mid-flight."
  (should (eq 'finished (decknix-review-board--lane t nil 'reviewed nil))))

(ert-deftest decknix-rb--a-blocked-session-still-wants-me-after-my-review ()
  "My approving the PR does not answer whatever the agent is asking."
  (should (eq 'needs-you (decknix-review-board--lane t t 'reviewed nil))))

(ert-deftest decknix-rb--a-group-is-reviewed-only-when-all-of-it-is ()
  "A group where I have decided one PR and not another still wants me."
  (should (eq 'reviewed (decknix--hub-review-status-aggregate
                         '(reviewed reviewed))))
  (should-not (decknix--hub-review-status-aggregate '(reviewed nil))))

(ert-deftest decknix-rb--mixed-mine-and-theirs-aggregates-to-answered ()
  (should (eq 'answered (decknix--hub-review-status-aggregate
                         '(reviewed answered)))))

(ert-deftest decknix-rb--reviewed-has-its-own-badge ()
  "It must not read as somebody else\='s response."
  (let ((mine (decknix--hub-review-status-glyph 'reviewed))
        (theirs (decknix--hub-review-status-glyph 'answered)))
    (should mine)
    (should-not (equal (car mine) (car theirs)))))

;; --- a PR taken back to draft ----------------------------------------
;;
;; attom-integration#341: marked ready at 04:30, auto-review dispatched a
;; session, converted back to draft at 04:36.  The session sat in Needs
;; you as though a review were wanted.

(ert-deftest decknix-rb--a-draft-pr-puts-its-session-on-hold ()
  (should (eq 'on-hold (decknix-review-board--lane t nil 'draft nil))))

(ert-deftest decknix-rb--draft-outranks-attention ()
  "An agent asking about a PR the author has withdrawn is not a call on
your time yet."
  (should (eq 'on-hold (decknix-review-board--lane t t 'draft nil))))

(ert-deftest decknix-rb--merged-still-outranks-draft ()
  (should (eq 'finished (decknix-review-board--lane t t 'gone nil))))

(ert-deftest decknix-rb--a-draft-with-no-session-stays-where-it-was ()
  "On hold is about a session; an undispatched request keeps its lane."
  (should (eq 'idle (decknix-review-board--lane nil nil 'draft nil))))

(ert-deftest decknix-rb--on-hold-is-a-rendered-lane ()
  (should (assq 'on-hold decknix-review-board-lanes))
  (should (assq 'on-hold decknix-review-board-lane-help)))

(ert-deftest decknix-rb--a-draft-cannot-be-merged ()
  (should (equal "PR is a draft"
                 (decknix-review-board-merge-blocker '(:prs ("r#1")) 'draft))))

;; --- review phases: assessing, at the gate, posting, posted ---

(defun decknix-rb-test--ask (text)
  "What a turn closing on TEXT asks, as turn-signals reports it."
  (list :verdict (decknix-agent-turn-ask-verdict text)
        :reply (decknix-agent-turn-ask-reply text)))

(defun decknix-rb-test--answered (text reply)
  (list :ask (decknix-rb-test--ask text) :reply reply))

(ert-deftest decknix-rb--phase-assessing-until-you-answer ()
  "Working with no answer behind it: Phase 1, reading the PR."
  (should (eq 'assessing (decknix-review-board-phase "working" nil nil nil))))

(ert-deftest decknix-rb--phase-awaiting-at-a-gate-with-a-verdict ()
  (should (eq 'awaiting (decknix-review-board-phase
                         "asking" (decknix-rb-test--ask decknix-fixture-gate-choose-one)
                         nil nil)))
  (should (eq 'asking (decknix-review-board-phase
                       "asking" (decknix-rb-test--ask "Which branch should this target?")
                       nil nil))))

(ert-deftest decknix-rb--phase-posting-after-a-go-ahead ()
  "Answering the gate with yes, or the number of a yes, starts Phase 2."
  (dolist (answered (list (decknix-rb-test--answered decknix-fixture-gate-choose-one "1")
                          (decknix-rb-test--answered decknix-fixture-gate-yes-edit-cancel "yes")))
    (should (eq 'actioned (decknix-review-board-phase "working" nil nil answered)))))

(ert-deftest decknix-rb--phase-revising-after-an-edit ()
  (should (eq 'revising
              (decknix-review-board-phase
               "working" nil nil
               (decknix-rb-test--answered decknix-fixture-gate-choose-one "2")))))

(ert-deftest decknix-rb--phase-posted-outranks-a-courtesy-question ()
  "On GitHub and asking \"anything else?\" is finished work, not a call on you."
  (should (eq 'posted
              (decknix-review-board-phase
               "asking" (decknix-rb-test--ask decknix-fixture-posted-then-asks)
               t nil))))

(ert-deftest decknix-rb--phase-feed-review-does-not-answer-the-gate ()
  "My review on GitHub names a settled session, but a gate still wants me."
  (should (eq 'posted (decknix-review-board-phase "ready" nil nil nil t)))
  (should (eq 'awaiting
              (decknix-review-board-phase
               "asking" (decknix-rb-test--ask decknix-fixture-gate-choose-one) nil nil t))))

(ert-deftest decknix-rb--phase-blocks-pass-through ()
  (should (eq 'waiting (decknix-review-board-phase "waiting" nil nil nil)))
  (should (eq 'netfail (decknix-review-board-phase "netfail" nil nil nil)))
  (should (eq 'idle (decknix-review-board-phase "ready" nil nil nil)))
  (should (eq 'idle (decknix-review-board-phase "closing" nil nil nil))))

(ert-deftest decknix-rb--phase-detail-names-verdict-and-reply ()
  (let ((numbered (decknix-rb-test--ask decknix-fixture-gate-choose-one))
        (words (decknix-rb-test--ask decknix-fixture-gate-yes-edit-cancel)))
    (should (equal "APPROVE · reply 1-3, rec 1"
                   (decknix-review-board-phase-detail 'awaiting numbered nil)))
    (should (equal "APPROVE · reply yes/edit/cancel"
                   (decknix-review-board-phase-detail 'awaiting words nil)))
    (should (equal "APPROVE"
                   (decknix-review-board-phase-detail
                    'actioned nil (list :ask numbered :reply "1"))))
    (should-not (decknix-review-board-phase-detail 'assessing nil nil))))

(ert-deftest decknix-rb--a-gate-is-in-needs-you-not-in-progress ()
  "The reported bug: a session that had presented its verdict sat in
In progress.  Its row now lands in Needs you, saying what it wants."
  (let ((row (decknix-review-board--session-row
              (list :name "pr-1" :prs '("b#9") :state "asking"
                    :ask (decknix-rb-test--ask decknix-fixture-gate-yes-edit-cancel))
              #'decknix-rb-test--status #'decknix-rb-test--priority)))
    (should (eq 'needs-you (plist-get row :lane)))
    (should (eq 'awaiting (plist-get row :phase)))
    (should (equal "APPROVE · reply yes/edit/cancel" (plist-get row :phase-detail)))))

(ert-deftest decknix-rb--in-progress-rows-say-which-phase ()
  (let ((assessing (decknix-review-board--session-row
                    '(:name "pr-1" :prs ("b#9") :state "working")
                    #'decknix-rb-test--status #'decknix-rb-test--priority))
        (posting (decknix-review-board--session-row
                  (list :name "pr-2" :prs '("b#9") :state "working"
                        :answered (decknix-rb-test--answered
                                   decknix-fixture-gate-choose-one "1"))
                  #'decknix-rb-test--status #'decknix-rb-test--priority)))
    (should (eq 'doing (plist-get assessing :lane)))
    (should (eq 'assessing (plist-get assessing :phase)))
    (should (eq 'doing (plist-get posting :lane)))
    (should (eq 'actioned (plist-get posting :phase)))))

(ert-deftest decknix-rb--a-posted-review-is-finished ()
  "Filed with finished work as soon as the session reports it, not when
the feed next notices."
  (let ((row (decknix-review-board--session-row
              (list :name "pr-1" :prs '("b#9") :state "asking"
                    :ask (decknix-rb-test--ask decknix-fixture-posted-then-asks)
                    :posted t)
              #'decknix-rb-test--status #'decknix-rb-test--priority)))
    (should (eq 'finished (plist-get row :lane)))
    (should (eq 'posted (plist-get row :phase)))))

;; --- answering from the board ---

(require 'decknix-review-board)
(require 'decknix-agent-turn-signals)

(ert-deftest decknix-rb--reply-keys-answer-only-the-row-at-point ()
  "The digit pressed goes to the session on the row at point, once."
  (let ((calls nil) (session (generate-new-buffer "pr-1")))
    (unwind-protect
        (with-temp-buffer
          (insert (propertize "row\n" 'decknix-review-board-row
                              (list :buffer session :session t)))
          (goto-char (point-min))
          (cl-letf (((symbol-function 'decknix-agent-turn-quick-reply)
                     (lambda (buf key) (push (cons buf key) calls) nil)))
            (let ((last-command-event ?2))
              (decknix-review-board-reply))
            (let ((last-command-event ?y))
              (decknix-review-board-reply)))
          (should (equal (list (cons session 'yes) (cons session 2)) calls)))
      (kill-buffer session))))

(ert-deftest decknix-rb--reply-keys-need-a-session ()
  (with-temp-buffer
    (insert (propertize "row\n" 'decknix-review-board-row (list :session nil)))
    (goto-char (point-min))
    (let ((last-command-event ?1))
      (should-error (decknix-review-board-reply) :type 'user-error))))

(ert-deftest decknix-rb--reply-keys-are-bound ()
  (should (eq #'decknix-review-board-reply
              (lookup-key decknix-review-board-mode-map (kbd "y"))))
  (dolist (d '("1" "5" "9"))
    (should (eq #'decknix-review-board-reply
                (lookup-key decknix-review-board-mode-map (kbd d))))))

(provide 'decknix-review-board-model-test)
;;; decknix-review-board-model-test.el ends here
