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
(require 'decknix-review-board-model)

;; --- lane precedence ---

(ert-deftest decknix-rb--attention-outranks-everything ()
  "A session blocked on the user is `needs-you', even if its PR is gone.
It may be asking precisely BECAUSE the PR merged underneath it, so
filing it under `finished' would bury the question."
  (should (eq 'needs-you (decknix-review-board--lane t t 'gone nil)))
  (should (eq 'needs-you (decknix-review-board--lane t t nil t))))

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
  "Lifecycle order: blocked on you, then in progress, then done, then the
un-started backlog.  The lanes you clear stay high, not buried."
  (should (equal '(needs-you doing finished grouped idle)
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

(provide 'decknix-review-board-model-test)
;;; decknix-review-board-model-test.el ends here
