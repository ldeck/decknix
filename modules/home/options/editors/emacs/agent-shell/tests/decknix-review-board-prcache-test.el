;;; decknix-review-board-prcache-test.el --- Per-PR cache for gone PRs -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-review-board-prcache)

(defmacro decknix-rbp-test--with-cache (&rest body)
  "Run BODY with an empty cache in a temp file and stubbed processes."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "rb-prcache" t))
          (decknix-review-board-prcache-file (expand-file-name "prs.eld" dir))
          (decknix-review-board-prcache--table nil)
          (decknix-review-board-prcache--dirty nil)
          (decknix-review-board-prcache--save-timer nil)
          (decknix-review-board-prcache--inflight nil)
          (decknix-review-board-prcache--queue nil)
          (started nil)
          (decknix-review-board-prcache-process-function
           (lambda (&rest args) (push (plist-get args :command) started) 'proc)))
     (ignore started)
     (cl-letf (((symbol-function 'run-with-idle-timer) (lambda (&rest _) 'timer))
               ((symbol-function 'timerp) (lambda (x) (eq x 'timer)))
               ((symbol-function 'executable-find) (lambda (_) "/stub/gh")))
       (unwind-protect (progn ,@body)
         (delete-directory dir t)))))

(defun decknix-rbp-test--key (item) (alist-get 'key item))

(ert-deftest decknix-rbp--learns-title-and-author ()
  (decknix-rbp-test--with-cache
    (decknix-review-board-prcache-learn
     '(((key . "svc#1") (title . "Fix it") (author . "jo") (author_kind . "human")))
     #'decknix-rbp-test--key)
    (let ((e (decknix-review-board-prcache-get "svc#1")))
      (should (equal "Fix it" (plist-get e :title)))
      (should (equal "jo" (plist-get e :author)))
      (should decknix-review-board-prcache--dirty))))

(ert-deftest decknix-rbp--an-unchanged-feed-writes-nothing ()
  (decknix-rbp-test--with-cache
    (let ((items '(((key . "svc#1") (title . "Fix it")))))
      (decknix-review-board-prcache-learn items #'decknix-rbp-test--key)
      (decknix-review-board-prcache-save)
      (should-not decknix-review-board-prcache--dirty)
      (decknix-review-board-prcache-learn items #'decknix-rbp-test--key)
      (should-not decknix-review-board-prcache--dirty))))

(ert-deftest decknix-rbp--an-empty-field-keeps-the-old-value ()
  (let ((merged (decknix-review-board-prcache-merge
                 '(:title "Fix it") '((title . "") (author . "jo")))))
    (should (equal "Fix it" (plist-get (car merged) :title)))
    (should (cdr merged))))

(ert-deftest decknix-rbp--survives-a-restart ()
  "Written whole, read back: the title outlives the feed and Emacs."
  (decknix-rbp-test--with-cache
    (decknix-review-board-prcache-learn '(((key . "svc#1") (title . "Fix it")))
                                        #'decknix-rbp-test--key)
    (decknix-review-board-prcache-save)
    (setq decknix-review-board-prcache--table nil)
    (should (equal "Fix it" (plist-get (decknix-review-board-prcache-get "svc#1") :title)))))

(ert-deftest decknix-rbp--parse-state ()
  (should (equal '(:state "MERGED" :merged-at "2026-11-24T01:00:00Z" :closed-at "2026-11-24T01:00:00Z")
                 (decknix-review-board-prcache-parse-state
                  "{\"state\":\"MERGED\",\"mergedAt\":\"2026-11-24T01:00:00Z\",\"closedAt\":\"2026-11-24T01:00:00Z\"}")))
  (should-not (decknix-review-board-prcache-parse-state "not json"))
  (should-not (decknix-review-board-prcache-parse-state "{\"message\":\"Not Found\"}")))

(ert-deftest decknix-rbp--state-labels ()
  (should (equal "merged" (decknix-review-board-prcache-state-label '(:state "MERGED"))))
  (should (equal "closed" (decknix-review-board-prcache-state-label '(:state "CLOSED"))))
  (should-not (decknix-review-board-prcache-state-label nil)))

(ert-deftest decknix-rbp--merged-and-closed-are-asked-once ()
  (should-not (decknix-review-board-prcache-needs-state-p '(:state "MERGED")))
  (should-not (decknix-review-board-prcache-needs-state-p '(:state "CLOSED")))
  (should (decknix-review-board-prcache-needs-state-p nil 1000.0))
  (should (decknix-review-board-prcache-needs-state-p '(:state "OPEN" :checked 0) 10000.0))
  (should-not (decknix-review-board-prcache-needs-state-p '(:state "OPEN" :checked 9000) 10000.0))
  (should-not (decknix-review-board-prcache-needs-state-p '(:failed-at 9900) 10000.0)))

(ert-deftest decknix-rbp--one-lookup-per-pr-capped ()
  "Asked once per PR however often the board repaints, two at a time."
  (decknix-rbp-test--with-cache
    (should (decknix-review-board-prcache-request-state "a#1" "https://github.com/o/a/pull/1"))
    (should-not (decknix-review-board-prcache-request-state "a#1" "https://github.com/o/a/pull/1"))
    (decknix-review-board-prcache-request-state "a#2" "https://github.com/o/a/pull/2")
    (decknix-review-board-prcache-request-state "a#3" "https://github.com/o/a/pull/3")
    (should (= 2 (length started)))
    (should (equal '("gh" "pr" "view" "https://github.com/o/a/pull/1" "--json" "state,mergedAt,closedAt")
                   (car (last started))))
    (should (equal '("a#3") (mapcar #'car decknix-review-board-prcache--queue)))))

(ert-deftest decknix-rbp--a-finished-lookup-is-kept-and-starts-the-next ()
  (decknix-rbp-test--with-cache
    (let ((repainted 0)
          (out (generate-new-buffer " *t*")))
      (let ((decknix-review-board-prcache-changed-function (lambda () (cl-incf repainted))))
        (decknix-review-board-prcache-request-state "a#1" "u1")
        (decknix-review-board-prcache-request-state "a#2" "u2")
        (decknix-review-board-prcache-request-state "a#3" "u3")
        (with-current-buffer out (insert "{\"state\":\"CLOSED\",\"mergedAt\":null,\"closedAt\":\"2026-11-24T01:00:00Z\"}"))
        (decknix-review-board-prcache--finish "a#1" 0 out)
        (should (equal "closed" (decknix-review-board-prcache-state-label
                                 (decknix-review-board-prcache-get "a#1"))))
        (should (decknix-review-board-prcache-gone-time (decknix-review-board-prcache-get "a#1")))
        (should (= 1 repainted))
        (should (= 3 (length started)))
        (should-not (decknix-review-board-prcache-request-state "a#1" "u1"))))))

(ert-deftest decknix-rbp--a-failed-lookup-backs-off ()
  (decknix-rbp-test--with-cache
    (let ((out (generate-new-buffer " *t*")))
      (decknix-review-board-prcache-request-state "a#1" "u1")
      (decknix-review-board-prcache--finish "a#1" 1 out)
      (should-not (decknix-review-board-prcache-request-state "a#1" "u1")))))

(provide 'decknix-review-board-prcache-test)
;;; decknix-review-board-prcache-test.el ends here
