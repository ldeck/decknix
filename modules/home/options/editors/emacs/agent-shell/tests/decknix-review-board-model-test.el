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

(ert-deftest decknix-rb--author-splits-only-live-sessions ()
  "Bot and human sessions split into their own lanes."
  (should (eq 'grouped (decknix-review-board--lane t nil nil t)))
  (should (eq 'human   (decknix-review-board--lane t nil nil nil))))

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
  (should (eq 'human (decknix-review-board--lane t nil 'stale nil)))
  (should (eq 'human (decknix-review-board--lane t nil 'answered nil))))

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
    (should (eq 'grouped (plist-get row :lane)))))

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
  "Needs-you first, finished second: the cheapest lane to clear must not
be buried at the bottom where it never gets cleared."
  (should (equal '(needs-you finished human grouped idle)
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

(provide 'decknix-review-board-model-test)
;;; decknix-review-board-model-test.el ends here
