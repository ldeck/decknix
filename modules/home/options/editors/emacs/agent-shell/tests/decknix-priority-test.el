;;; decknix-priority-test.el --- Tests for decknix-priority -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-priority "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning the pure decision layer of `decknix-priority': lane
;; classification for reviews / WIP / tasks, the stable item keys, the
;; age helper, the within-lane comparator (mention-first then oldest),
;; and the `collect' aggregator that turns the three hub wrappers into
;; the four ordered lanes (Discussions -> Reviews -> Tasks -> Queue).

;;; Code:

(require 'ert)
(require 'decknix-priority)

(defconst decknix-priority-test--now
  (date-to-time "2026-06-28T00:00:00Z")
  "Fixed clock so age-based ordering is deterministic.")

;; -- Lane classification --------------------------------------------

(ert-deftest decknix-priority/review-lane ()
  (should (eq 'discussions
             (decknix-priority-review-lane '((replies_to_me . t)))))
  (should (eq 'reviews (decknix-priority-review-lane '((mentioned . t)))))
  (should (eq 'reviews (decknix-priority-review-lane '()))))

(ert-deftest decknix-priority/wip-lane ()
  (should-not (decknix-priority-wip-lane '((state . "MERGED"))))
  (should-not (decknix-priority-wip-lane '((state . "CLOSED"))))
  (should-not (decknix-priority-wip-lane '((state . "OPEN")
                                           (merged_at . "2026-06-01T00:00:00Z"))))
  (should (eq 'discussions
             (decknix-priority-wip-lane '((state . "OPEN") (replies_to_me . t)))))
  (should (eq 'queue (decknix-priority-wip-lane '((state . "OPEN"))))))

(ert-deftest decknix-priority/task-lane ()
  (should-not (decknix-priority-task-lane '((status_category . "done"))))
  (should (eq 'tasks (decknix-priority-task-lane '((status_category . "indeterminate")))))
  (should (eq 'tasks (decknix-priority-task-lane '()))))

;; -- Age helper -----------------------------------------------------

(ert-deftest decknix-priority/age-seconds ()
  (should (= 86400
            (decknix-priority-age-seconds
             "2026-06-27T00:00:00Z" decknix-priority-test--now)))
  (should-not (decknix-priority-age-seconds nil decknix-priority-test--now))
  (should-not (decknix-priority-age-seconds "not-a-date" decknix-priority-test--now)))

;; -- Comparator -----------------------------------------------------

(ert-deftest decknix-priority/item-less-p-mention-first ()
  (should (decknix-priority-item-less-p '((mention . t) (age . 1))
                                        '((mention . nil) (age . 999))))
  (should-not (decknix-priority-item-less-p '((mention . nil) (age . 999))
                                            '((mention . t) (age . 1)))))

(ert-deftest decknix-priority/item-less-p-oldest-first ()
  (should (decknix-priority-item-less-p '((mention . nil) (age . 500))
                                        '((mention . nil) (age . 100))))
  ;; nil age sorts last
  (should (decknix-priority-item-less-p '((mention . nil) (age . 100))
                                        '((mention . nil) (age . nil)))))

;; -- Aggregator -----------------------------------------------------

(defconst decknix-priority-test--reviews
  '((items . (((repo . "o/r") (number . 1) (title . "t1") (url . "u1")
               (updated . "2026-06-01T00:00:00Z") (mentioned . t))
              ((repo . "o/r") (number . 2) (title . "t2") (url . "u2")
               (updated . "2026-06-10T00:00:00Z") (replies_to_me . t))))))

(defconst decknix-priority-test--wip
  '((repos . (((repo . "o/r")
               (prs . (((number . 3) (state . "OPEN") (url . "u3")
                        (updated . "2026-06-05T00:00:00Z"))
                       ((number . 4) (state . "MERGED") (url . "u4")))))))))

(defconst decknix-priority-test--tasks
  '((items . (((key . "NC-1") (summary . "s1") (url . "ut1")
               (status_category . "indeterminate") (updated . "2026-06-02T00:00:00Z"))
              ((key . "NC-2") (summary . "s2") (status_category . "done"))))))

(ert-deftest decknix-priority/collect-lanes ()
  (let* ((lanes (decknix-priority-collect
                 decknix-priority-test--reviews
                 decknix-priority-test--wip
                 decknix-priority-test--tasks
                 decknix-priority-test--now))
         (disc (alist-get 'discussions lanes))
         (rev  (alist-get 'reviews lanes))
         (task (alist-get 'tasks lanes))
         (queue (alist-get 'queue lanes)))
    ;; Discussions: the review with a human reply awaiting me.
    (should (= 1 (length disc)))
    (should (string= "review:o/r#2" (alist-get 'key (car disc))))
    ;; Reviews: the directly-mentioned review request.
    (should (= 1 (length rev)))
    (should (string= "review:o/r#1" (alist-get 'key (car rev))))
    (should (alist-get 'mention (car rev)))
    ;; Tasks: the non-done Jira task only.
    (should (= 1 (length task)))
    (should (string= "task:NC-1" (alist-get 'key (car task))))
    ;; Queue: the open WIP PR; the merged one is excluded.
    (should (= 1 (length queue)))
    (should (string= "wip:o/r#3" (alist-get 'key (car queue))))))

(ert-deftest decknix-priority/collect-empty ()
  "No data yields four empty lanes, not an error."
  (let ((lanes (decknix-priority-collect nil nil nil
                                         decknix-priority-test--now)))
    (should (equal decknix-priority-lanes (mapcar #'car lanes)))
    (should (seq-every-p (lambda (l) (null (cdr l))) lanes))))

(provide 'decknix-priority-test)
;;; decknix-priority-test.el ends here
