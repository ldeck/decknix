;;; decknix-review-board-rereview-test.el --- Tests for re-review detection -*- lexical-binding: t -*-

;;; Commentary:
;;
;; A PR I reviewed with feedback, then the author pushed: the board must
;; notice, place the row where it is seen, and (in `auto') start exactly
;; one re-review per new head.  Pushes that change nothing a reviewer
;; cares about -- a merge of the base branch, a rebase with the same diff
;; -- must not.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-review-board-model)
(require 'decknix-review-board-rereview)

(defun decknix-rr-test--item (&rest overrides)
  "A feed item: I commented at sha A, head now B with two commits.
OVERRIDES is an alist of fields replacing the defaults."
  (let ((base `((repo . "org/widget") (number . 7) (key . "widget#7")
                (my_review . "COMMENTED") (my_review_feedback . t)
                (my_review_sha . "aaaaaaaaaa") (head_sha . "bbbbbbbbbb")
                (updated . "2026-11-12T00:00:00Z")
                (my_threads . 2) (my_threads_resolved . 1) (my_threads_answered . 2)
                (since_review . ((from . "aaaaaaaaaa") (to . "bbbbbbbbbb")
                                 (status . "ahead") (files . 3)
                                 (commits . (((sha . "c1c1c1c1c1") (headline . "Address review")
                                              (author . "dev"))
                                             ((sha . "bbbbbbbbbb") (headline . "Rename helper")
                                              (author . "dev")))))))))
    (dolist (o (car overrides) base)
      (setq base (cons o (assq-delete-all (car o) (copy-alist base)))))))

;; --- detection ----------------------------------------------------------

(ert-deftest decknix-rr--reviewed-at-a-then-head-b-is-updated ()
  (let ((info (decknix-review-board-rereview-info (decknix-rr-test--item) nil "me")))
    (should info)
    (should (eq 'mine (plist-get info :reason)))
    (should (equal "aaaaaaaaaa" (plist-get info :from)))
    (should (equal "bbbbbbbbbb" (plist-get info :head)))
    (should (= 2 (plist-get info :count)))
    (should (= 3 (plist-get info :files)))
    (should (equal '(:mine 2 :resolved 1 :answered 2) (plist-get info :threads)))))

(ert-deftest decknix-rr--head-unchanged-is-not-updated ()
  (should-not (decknix-review-board-rereview-info
               (decknix-rr-test--item '((head_sha . "aaaaaaaaaa") (since_review)))
               nil "me")))

(ert-deftest decknix-rr--merge-from-base-only-is-not-updated-by-default ()
  (let ((item (decknix-rr-test--item
               '((since_review . ((from . "aaaaaaaaaa") (to . "bbbbbbbbbb")
                                  (status . "ahead") (files . 40) (diff_unchanged . t)
                                  (commits . (((sha . "bbbbbbbbbb")
                                               (headline . "Merge branch 'main' into f")
                                               (author . "dev") (merge_from_base . t))))))))))
    (should-not (decknix-review-board-rereview-info item nil "me"))
    (let ((decknix-review-board-rereview-ignore-base-merges nil))
      (should (eq 'base-merge
                  (plist-get (decknix-review-board-rereview-info item nil "me") :noise))))))

(ert-deftest decknix-rr--rebase-with-the-same-diff-is-not-updated-by-default ()
  (let ((item (decknix-rr-test--item
               '((since_review . ((from . "aaaaaaaaaa") (to . "bbbbbbbbbb")
                                  (status . "diverged") (files . 0) (diff_unchanged . t)
                                  (commits . (((sha . "bbbbbbbbbb") (headline . "Fix")
                                               (author . "dev"))))))))))
    (should-not (decknix-review-board-rereview-info item nil "me"))
    (let ((decknix-review-board-rereview-ignore-rebases nil))
      (should (plist-get (decknix-review-board-rereview-info item nil "me") :rebased)))))

(ert-deftest decknix-rr--a-rebase-that-changed-the-diff-is-updated-and-says-rebased ()
  (let ((info (decknix-review-board-rereview-info
               (decknix-rr-test--item
                '((since_review . ((from . "aaaaaaaaaa") (to . "bbbbbbbbbb")
                                   (status . "diverged") (files . 1) (diff_unchanged . nil)
                                   (commits . (((sha . "bbbbbbbbbb") (headline . "Fix")
                                                (author . "dev"))))))))
               nil "me")))
    (should (plist-get info :rebased))
    (should (string-match-p "rebased" (decknix-review-board-rereview-summary info)))))

(ert-deftest decknix-rr--other-reviewers-feedback-counts-only-for-a-settled-session ()
  "Someone else requested changes, the author pushed, and my session is
Finished: that is a re-review.  Without a settled session it is not mine."
  (let ((item (decknix-rr-test--item
               '((my_review) (my_review_feedback) (my_review_sha)
                 (feedback_review . ((author . "alice") (state . "CHANGES_REQUESTED")
                                     (at . "2026-11-10T00:00:00Z") (sha . "aaaaaaaaaa")))))))
    (should-not (decknix-review-board-rereview-info item nil "me"))
    (let ((info (decknix-review-board-rereview-info item t "me")))
      (should (eq 'others (plist-get info :reason)))
      (should (equal "alice" (plist-get info :by)))
      (should (string-match-p "@alice" (decknix-review-board-rereview-prompt info))))))

(ert-deftest decknix-rr--draft-is-not-updated ()
  (should-not (decknix-review-board-rereview-info
               (decknix-rr-test--item '((draft . t))) t "me")))

(ert-deftest decknix-rr--closed-pr-has-no-item-and-is-not-updated ()
  "A merged or closed PR leaves the feed; nil item, nothing to re-review."
  (should-not (decknix-review-board-rereview-info nil t "me")))

(ert-deftest decknix-rr--a-bare-approval-is-not-updated-unless-asked ()
  (let ((item (decknix-rr-test--item '((my_review . "APPROVED") (my_review_feedback . nil)
                                       (my_threads . 0)))))
    (should-not (decknix-review-board-rereview-info item nil "me"))
    (let ((decknix-review-board-rereview-bare-approvals t))
      (should (decknix-review-board-rereview-info item nil "me")))))

(ert-deftest decknix-rr--a-dismissed-approval-is-updated-and-says-so ()
  (let ((info (decknix-review-board-rereview-info
               (decknix-rr-test--item '((my_review . "DISMISSED") (my_review_feedback . nil)))
               nil "me")))
    (should (plist-get info :dismissed))
    (should (string-match-p "approval dismissed" (decknix-review-board-rereview-summary info)))
    (should (string-match-p "re-approving" (decknix-review-board-rereview-prompt info)))))

(ert-deftest decknix-rr--my-own-push-is-not-news ()
  (let ((item (decknix-rr-test--item
               '((since_review . ((from . "aaaaaaaaaa") (to . "bbbbbbbbbb") (status . "ahead")
                                  (files . 1)
                                  (commits . (((sha . "bbbbbbbbbb") (headline . "x")
                                               (author . "Me"))))))))))
    (should-not (decknix-review-board-rereview-info item nil "me"))))

(ert-deftest decknix-rr--a-head-already-re-reviewed-is-not-updated-again ()
  (should-not (decknix-review-board-rereview-info
               (decknix-rr-test--item) nil "me" "bbbbbbbbbb"))
  (should (decknix-review-board-rereview-info
           (decknix-rr-test--item) nil "me" "c1c1c1c1c1")))

(ert-deftest decknix-rr--an-older-hub-falls-back-to-the-pushed-flag ()
  "No shas at all: `pushed_since_my_review' and the state stand in."
  (let ((old '((my_review . "CHANGES_REQUESTED") (pushed_since_my_review . t))))
    (let ((info (decknix-review-board-rereview-info old nil "me")))
      (should info)
      (should-not (plist-get info :count))
      (should (string-match-p "pushed since" (decknix-review-board-rereview-summary info))))
    (should-not (decknix-review-board-rereview-info
                 '((my_review . "CHANGES_REQUESTED") (pushed_since_my_review . nil)) nil "me"))))

(ert-deftest decknix-rr--prompt-names-the-range-the-worktree-and-the-gate ()
  (let ((p (decknix-review-board-rereview-prompt
            (decknix-review-board-rereview-info (decknix-rr-test--item) nil "me")
            "/src/widget-worktrees/pr-7")))
    (should (string-match-p "2 commits" p))
    (should (string-match-p "git diff aaaaaaaaaa\\.\\.bbbbbbbbbb" p))
    (should (string-match-p "/src/widget-worktrees/pr-7" p))
    (should (string-match-p "Address review" p))
    (should (string-match-p "confirmation gate" p))
    (should (string-match-p "do not post" p))))

;; --- lane placement -----------------------------------------------------

(defun decknix-rr-test--rereview-fn (items)
  (lambda (key settled)
    (decknix-review-board-rereview-info
     (seq-find (lambda (i) (equal key (alist-get 'key i))) items) settled "me")))

(defun decknix-rr-test--build (items sessions)
  (decknix-review-board-build
   items sessions
   (lambda (i) (alist-get 'key i))
   (lambda (_k) 'stale) (lambda (_k) 0) (lambda (_i) nil)
   (decknix-rr-test--rereview-fn items)))

(ert-deftest decknix-rr--a-finished-session-moves-to-the-rereview-lane ()
  (let* ((items (list (decknix-rr-test--item)))
         (model (decknix-rr-test--build
                 items (list (list :name "pr-widget-7" :conv-key "c" :prs '("widget#7")
                                   :state "finished" :posted t)))))
    (should (null (alist-get 'finished model)))
    (let ((row (car (alist-get 'rereview model))))
      (should row)
      (should (eq 'updated (plist-get row :phase)))
      (should (string-match-p "2 commits, 3 files" (plist-get row :phase-detail)))
      (should (decknix-review-board-verb-applicable-p 'rereview row)))
    (should (= 1 (decknix-review-board-attention-count model)))))

(ert-deftest decknix-rr--a-working-session-is-left-alone ()
  "Mid-turn, the session has the PR in hand; it is not re-reviewed."
  (let ((model (decknix-rr-test--build
                (list (decknix-rr-test--item))
                (list (list :name "pr-widget-7" :conv-key "c" :prs '("widget#7")
                            :state "working")))))
    (should (null (alist-get 'rereview model)))
    (should (alist-get 'doing model))))

(ert-deftest decknix-rr--a-sessionless-updated-pr-gets-its-own-row ()
  (let ((model (decknix-rr-test--build (list (decknix-rr-test--item)) nil)))
    (should (null (alist-get 'idle model)))
    (let ((row (car (alist-get 'rereview model))))
      (should row)
      (should-not (plist-get row :session)))))

(ert-deftest decknix-rr--blocked-outranks-updated ()
  (should (eq 'needs-you (decknix-review-board--lane t t 'stale nil 'awaiting t)))
  (should (eq 'rereview (decknix-review-board--lane t nil 'stale nil 'updated t)))
  (should (eq 'finished (decknix-review-board--lane t nil 'gone nil 'updated t))))

;; --- notify / auto, rate limit, worktree refresh -----------------------

(defmacro decknix-rr-test--with-clean-state (&rest body)
  `(let ((decknix-review-board-rereview--seen (make-hash-table :test 'equal))
         (decknix-review-board-rereview--notified (make-hash-table :test 'equal))
         (decknix-review-board-rereview-state-file nil)
         (decknix-review-board-rereview--loaded t)
         (notes nil))
     (let ((decknix-review-board-rereview-notify-function
            (lambda (fmt &rest args) (push (apply #'format fmt args) notes))))
       ,@body)))

(defun decknix-rr-test--row ()
  (let ((item (decknix-rr-test--item)))
    (list :prs '("widget#7")
          :rereview (decknix-review-board-rereview-info item nil "me"))))

(ert-deftest decknix-rr--notify-mode-tells-once-and-starts-nothing ()
  (decknix-rr-test--with-clean-state
   (let (started)
     (decknix-review-board-rereview-process
      (list (decknix-rr-test--row)) 'notify (lambda (r _i) (push r started)))
     (decknix-review-board-rereview-process
      (list (decknix-rr-test--row)) 'notify (lambda (r _i) (push r started)))
     (should (null started))
     (should (= 1 (length notes)))
     (should (string-match-p "widget#7 updated" (car notes))))))

(ert-deftest decknix-rr--auto-mode-starts-once-per-head ()
  (decknix-rr-test--with-clean-state
   (let ((starts 0))
     (cl-letf (((symbol-function 'decknix-rr-test--start)
                (lambda (row info)
                  (setq starts (1+ starts))
                  (decknix-review-board-rereview-mark-seen
                   (car (plist-get row :prs)) (plist-get info :head)))))
       (decknix-review-board-rereview-process
        (list (decknix-rr-test--row)) 'auto #'decknix-rr-test--start)
       (decknix-review-board-rereview-process
        (list (decknix-rr-test--row)) 'auto #'decknix-rr-test--start)
       (should (= 1 starts))
       (should (equal "bbbbbbbbbb" (decknix-review-board-rereview-seen-head "widget#7")))))))

(ert-deftest decknix-rr--nil-mode-does-nothing ()
  (decknix-rr-test--with-clean-state
   (let (started)
     (decknix-review-board-rereview-process
      (list (decknix-rr-test--row)) nil (lambda (r _i) (push r started)))
     (should (null started))
     (should (null notes)))))

(ert-deftest decknix-rr--start-refreshes-the-worktree-then-delivers ()
  (decknix-rr-test--with-clean-state
   (let* ((calls nil)
          (decknix-review-board-rereview-refresh-function
           (lambda (owner repo number head cb)
             (push (list 'refresh owner repo number head) calls)
             (funcall cb "/wt/pr-7")))
          (decknix-review-board-rereview-deliver-function
           (lambda (_row url prompt context)
             (push (list 'deliver url prompt context) calls)))
          (row (decknix-rr-test--row)))
     (decknix-review-board-rereview-start
      row (plist-get row :rereview) "https://github.com/org/widget/pull/7"
      "org" "widget" "7")
     (setq calls (nreverse calls))
     (should (equal '(refresh "org" "widget" "7" "bbbbbbbbbb") (car calls)))
     (let ((d (cadr calls)))
       (should (eq 'deliver (car d)))
       (should (string-match-p "/wt/pr-7" (nth 2 d)))
       (should-not (string-match-p "/wt/pr-7" (nth 3 d))))
     ;; Marked seen before the (async) refresh, so a second trigger is a no-op.
     (should (equal "bbbbbbbbbb" (decknix-review-board-rereview-seen-head "widget#7"))))))

(ert-deftest decknix-rr--seen-heads-persist-across-a-restart ()
  (let* ((file (make-temp-file "rr-state" nil ".eld"))
         (decknix-review-board-rereview-state-file file))
    (unwind-protect
        (progn
          (let ((decknix-review-board-rereview--seen (make-hash-table :test 'equal))
                (decknix-review-board-rereview--loaded t))
            (decknix-review-board-rereview-mark-seen "widget#7" "bbbbbbbbbb"))
          (let ((decknix-review-board-rereview--seen (make-hash-table :test 'equal))
                (decknix-review-board-rereview--loaded nil))
            (should (equal "bbbbbbbbbb"
                           (decknix-review-board-rereview-seen-head "widget#7")))))
      (delete-file file))))

(provide 'decknix-review-board-rereview-test)
;;; decknix-review-board-rereview-test.el ends here
