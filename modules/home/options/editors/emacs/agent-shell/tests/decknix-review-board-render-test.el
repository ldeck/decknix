;;; decknix-review-board-render-test.el --- Review board rendering and keys -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The board's screen, from a model built in the test: the header is two
;; lines, the column labels sit over the cells they name, a row's hover
;; text is its priority breakdown, and `y' nudges a stalled session or
;; resumes a crashed one rather than sending "yes" into nothing.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-test-helpers)
(require 'decknix-review-board)

(defvar decknix-rbr-test--item
  '((repo . "o/svc") (number . 7) (title . "Fix the widget") (author . "dependabot[bot]")
    (author_kind . "bot") (created . "2026-11-20T00:00:00Z") (updated . "2026-11-24T00:00:00Z")
    (ci (status . "fail")) (my_review . "APPROVED") (human_unresolved . 1) (bot_unresolved . 2)
    (url . "https://github.com/o/svc/pull/7")))

(defmacro decknix-rbr-test--with-board (model &rest body)
  "Render MODEL into a temp board buffer, then run BODY there."
  (declare (indent 1))
  `(let ((decknix--hub-reviews (list (cons 'items (list decknix-rbr-test--item))
                                     (cons 'viewer "me")))
         (decknix-review-board-prcache--table (make-hash-table :test 'equal)))
     (cl-letf (((symbol-function 'decknix--hub-review-pr-key)
                (lambda (repo number) (format "%s#%s" (car (last (split-string repo "/"))) number)))
               ((symbol-function 'decknix--hub-review-find-item)
                (lambda (items repo number)
                  (seq-find (lambda (i) (and (string-suffix-p repo (alist-get 'repo i))
                                             (equal number (alist-get 'number i))))
                            items))))
       (with-temp-buffer
         (setq decknix-review-board--model ,model)
         (decknix-review-board--render)
         ,@body))))

(defun decknix-rbr-test--model (&rest lanes)
  "A full lane alist with LANES (an alist of lane -> rows) filled in."
  (mapcar (lambda (lane) (cons (car lane) (alist-get (car lane) lanes)))
          decknix-review-board-lanes))

(defun decknix-rbr-test--row (&rest props)
  (append props (list :kind 'single :priority 5 :statuses nil)))

(ert-deftest decknix-rbr--header-is-two-lines ()
  "State and the daily keys; then straight into the lanes."
  (decknix-rbr-test--with-board (decknix-rbr-test--model)
    (goto-char (point-min))
    (should (looking-at "Review Board"))
    (forward-line 2)
    (should (looking-at "\n"))
    (forward-line 1)
    (should (looking-at "Needs you"))))

(ert-deftest decknix-rbr--labels-sit-over-their-cells ()
  "The `pr' label starts where the PR key does, `author' where the author does."
  (let* ((width (decknix-review-board-columns-title-width 160))
         (labels (decknix-review-board--column-labels width)))
    (decknix-rbr-test--with-board
        (decknix-rbr-test--model
         (cons 'doing (list (decknix-rbr-test--row :lane 'doing :session t :phase 'assessing
                                                   :prs '("svc#7") :state "working"))))
      (cl-letf (((symbol-function 'decknix-review-board--window-width) (lambda () 160)))
        (decknix-review-board--render))
      (goto-char (point-min))
      (search-forward "svc#7")
      (let ((row (buffer-substring (line-beginning-position) (line-end-position))))
        (should (= (string-match "pr " labels) (string-match "svc#7" row)))
        (should (= (string-match "author" labels) (string-match "dependabot⚙" row)))))))

(ert-deftest decknix-rbr--row-shows-ci-review-threads ()
  (decknix-rbr-test--with-board
      (decknix-rbr-test--model
       (cons 'doing (list (decknix-rbr-test--row :lane 'doing :session t :phase 'assessing
                                                 :prs '("svc#7") :state "working"))))
    (goto-char (point-min))
    (search-forward "svc#7")
    (let ((row (buffer-substring (line-beginning-position) (line-end-position))))
      (should (string-match-p "Fix the widget" row))
      (should (string-match-p "✗ A " row))
      (should (string-match-p "h1 b2" row))
      (should (string-match-p "assessing" row)))))

(ert-deftest decknix-rbr--hover-is-the-priority-breakdown ()
  (decknix-rbr-test--with-board
      (decknix-rbr-test--model
       (cons 'doing (list (decknix-rbr-test--row :lane 'doing :session t :phase 'assessing
                                                 :prs '("svc#7") :state "working"))))
    (cl-letf (((symbol-function 'decknix--hub-review-priority-explain)
               (lambda (&rest _) "priority 5 = engagement +10, bot -35")))
      (goto-char (point-min))
      (search-forward "svc#7")
      (let ((help (get-text-property (point) 'help-echo)))
        (should (functionp help))
        (should (string-match-p "engagement \\+10"
                                (funcall help nil (current-buffer) (point))))))))

(ert-deftest decknix-rbr--obsolete-row-says-merged-or-closed ()
  "The cached final state names the outcome; a cached title survives the feed."
  (decknix-rbr-test--with-board (decknix-rbr-test--model)
    (puthash "gone#3" '(:title "Old work" :state "MERGED") decknix-review-board-prcache--table)
    (setq decknix-review-board--model
          (decknix-rbr-test--model
           (cons 'obsolete (list (decknix-rbr-test--row :lane 'obsolete :session t :phase 'asking
                                                        :phase-detail "moot" :prs '("gone#3")
                                                        :state "asking")))))
    (decknix-review-board--render)
    (goto-char (point-min))
    (search-forward "gone#3")
    (let ((row (buffer-substring (line-beginning-position) (line-end-position))))
      (should (string-match-p "Old work" row))
      (should (string-match-p "merged" row))
      (should (string-match-p "moot" row))
      (should-not (string-match-p "reply" row)))))

(ert-deftest decknix-rbr--y-nudges-a-stalled-session ()
  (let ((buf (generate-new-buffer " *stalled*")) sent)
    (unwind-protect
        (cl-letf (((symbol-function 'decknix-review-board--row-at-point)
                   (lambda () (list :buffer buf :phase 'stalled)))
                  ((symbol-function 'yes-or-no-p) (lambda (_) t))
                  ((symbol-function 'decknix--session-bulk-dispatch)
                   (lambda (bufs input) (push (cons bufs input) sent)))
                  ((symbol-function 'decknix-agent-turn-reply-key) (lambda (_) "y"))
                  ((symbol-function 'decknix-agent-turn-quick-reply)
                   (lambda (&rest _) (error "quick reply must not run")))
                  ((symbol-function 'decknix-review-board-schedule-refresh) #'ignore))
          (let ((last-command-event ?y))
            (decknix-review-board-reply))
          (should (equal (list (cons (list buf) decknix-review-board-nudge-prompt)) sent)))
      (kill-buffer buf))))

(ert-deftest decknix-rbr--y-resets-and-resumes-a-crashed-session ()
  (let ((buf (generate-new-buffer " *crashed*")) sent reset)
    (unwind-protect
        (cl-letf (((symbol-function 'decknix-review-board--row-at-point)
                   (lambda () (list :buffer buf :phase 'netfail :netfail "API Error (ENOTFOUND)")))
                  ((symbol-function 'yes-or-no-p) (lambda (_) t))
                  ((symbol-function 'decknix--agent-net-error-reset-buffer)
                   (lambda (b) (push b reset)))
                  ((symbol-function 'decknix--session-bulk-dispatch)
                   (lambda (bufs input) (push (cons bufs input) sent)))
                  ((symbol-function 'decknix-agent-turn-reply-key) (lambda (_) "y"))
                  ((symbol-function 'decknix-review-board-schedule-refresh) #'ignore))
          (let ((last-command-event ?y))
            (decknix-review-board-reply))
          (should (equal (list buf) reset))
          (should (equal (list buf) (caar sent))))
      (kill-buffer buf))))

(ert-deftest decknix-rbr--a-digit-still-answers-the-question ()
  "Only `y' nudges or resumes; a number answers the gate as before."
  (let ((buf (generate-new-buffer " *asking*")) answered)
    (unwind-protect
        (cl-letf (((symbol-function 'decknix-review-board--row-at-point)
                   (lambda () (list :buffer buf :phase 'stalled)))
                  ((symbol-function 'decknix-agent-turn-reply-key) (lambda (_) "1"))
                  ((symbol-function 'decknix-agent-turn-quick-reply)
                   (lambda (b key) (push (cons b key) answered) t))
                  ((symbol-function 'decknix-review-board-schedule-refresh) #'ignore))
          (let ((last-command-event ?1))
            (decknix-review-board-reply))
          (should (equal (list (cons buf "1")) answered)))
      (kill-buffer buf))))

(provide 'decknix-review-board-render-test)
;;; decknix-review-board-render-test.el ends here
