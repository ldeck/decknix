;;; decknix-pr-review-view-test.el --- PR review view -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-pr-review-view)

(defun decknix-prv-test--thread (id)
  "One thread node with a single comment, ID its line and comment id / 100."
  (list (cons 'id (format "T%s" id)) (cons 'isResolved :false) (cons 'isOutdated :false)
        (cons 'path "src/a.kt") (cons 'line id) (cons 'originalLine id)
        (cons 'diffSide "RIGHT")
        (cons 'comments
              (list (cons 'nodes
                          (vector (list (cons 'databaseId (* 100 id))
                                        (cons 'author (list (cons 'login "jo")))
                                        (cons 'body (format "comment %s" id))
                                        (cons 'createdAt "2026-11-24T00:00:00Z"))))))))

(defun decknix-prv-test--page (ids has-next cursor)
  "A GraphQL threads page with one thread per ID, as `gh api' prints it."
  (json-serialize
   (list (cons 'data
               (list (cons 'repository
                           (list (cons 'pullRequest
                                       (list (cons 'reviewThreads
                                                   (list (cons 'pageInfo
                                                               (list (cons 'hasNextPage (if has-next t :false))
                                                                     (cons 'endCursor (or cursor :null))))
                                                         (cons 'nodes (vconcat (mapcar #'decknix-prv-test--thread ids))))))))))))))

(ert-deftest decknix-prv--threads-follow-every-page ()
  "Two pages are read whole, the second asked for with the first's cursor."
  (let* ((calls nil)
         (decknix-pr-review-view-gh-function
          (lambda (args callback)
            (push args calls)
            (if (member "after=C1" args)
                (funcall callback t (decknix-prv-test--page '(3) nil nil))
              (funcall callback t (decknix-prv-test--page '(1 2) t "C1")))))
         (result :none))
    (decknix-pr-review-view-fetch-threads "o" "r" 7 (lambda (threads &optional _err)
                                                     (setq result threads)))
    (should (= 2 (length calls)))
    (should (member "pr=7" (car (last calls))))
    (should (equal '(1 2 3) (mapcar (lambda (th) (plist-get th :line)) result)))))

(ert-deftest decknix-prv--a-failed-page-is-an-error-not-no-threads ()
  (let ((decknix-pr-review-view-gh-function
         (lambda (_args callback) (funcall callback nil "HTTP 401: Bad credentials\n")))
        (err nil) (threads :none))
    (decknix-pr-review-view-fetch-threads "o" "r" 7 (lambda (th &optional e)
                                                     (setq threads th err e)))
    (should-not threads)
    (should (equal "HTTP 401: Bad credentials" err))))

(ert-deftest decknix-prv--state-dir-is-per-pr ()
  (let ((decknix-pr-review-view-state-root "/state/reviews/"))
    (should (equal "/state/reviews/my-org/svc/12/"
                   (decknix-pr-review-view-state-dir "my-org" "svc" 12)))))

(ert-deftest decknix-prv--plan-is-read-from-the-state-dir ()
  (let ((dir (make-temp-file "prv" t)))
    (unwind-protect
        (progn
          (should-not (decknix-pr-review-view-read-plan dir))
          (with-temp-file (expand-file-name "plan.json" dir)
            (insert "{\"verdict\":\"APPROVE\",\"body\":\"LGTM\",\"inline_comments\":[{\"path\":\"a.kt\",\"line\":3,\"body\":\"nit: name\"}]}"))
          (let* ((plan (decknix-pr-review-view-read-plan dir))
                 (text (decknix-pr-review-view-render-plan plan "P")))
            (should (equal "APPROVE" (alist-get 'verdict plan)))
            (should (string-match-p "verdict  APPROVE" text))
            (should (string-match-p "a.kt:3  nit: name" text))))
      (delete-directory dir t))))

(ert-deftest decknix-prv--render-shows-every-section ()
  (let* ((threads (car (decknix-review-threads-parse-page
                        (decknix-pr-review-view--parse (decknix-prv-test--page '(4) nil nil)))))
         (text (decknix-pr-review-view-render
                (list :pr '((title . "Fix it") (state . "OPEN") (author (login . "jo"))
                            (body . "Because.") (reviewDecision . "REVIEW_REQUIRED")
                            (statusCheckRollup ((name . "build") (conclusion . "FAILURE"))
                                               ((name . "lint") (conclusion . "SUCCESS")))
                            (reviews ((author (login . "sam")) (state . "COMMENTED") (body . "hm"))))
                      :threads threads))))
    (dolist (want '("Fix it" "Description" "Because." "CI" "FAILURE   build"
                    "Reviews" "sam" "Threads  1 open" "src/a.kt" "comment 4"
                    "Agent's plan"))
      (should (string-match-p (regexp-quote want) text)))
    (should (< (string-match "build" text) (string-match "lint" text)))))

(ert-deftest decknix-prv--loading-and-errors-say-so ()
  (let ((text (decknix-pr-review-view-render '(:threads-loading t))))
    (should (string-match-p "Loading the PR" text))
    (should (string-match-p "Threads\n  Loading" text)))
  (should (string-match-p "Could not read the threads: nope"
                          (decknix-pr-review-view-render '(:threads-error "nope")))))

(ert-deftest decknix-prv--thread-url-anchors-its-first-comment ()
  (should (equal "https://github.com/o/r/pull/7#discussion_r400"
                 (decknix-pr-review-view-thread-url "o" "r" 7 '(:comments ((:id 400)))))))

(ert-deftest decknix-prv--ret-opens-the-thread-at-point ()
  (let ((decknix-pr-review-view-gh-function
         (lambda (args callback)
           (if (equal (car args) "api")
               (funcall callback t (decknix-prv-test--page '(9) nil nil))
             (funcall callback t "{\"title\":\"T\"}"))))
        (decknix-pr-review-view-state-root (make-temp-file "prv" t))
        (opened nil))
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)
              ((symbol-function 'browse-url) (lambda (u &rest _) (setq opened u))))
      (let ((buf (decknix-pr-review-view-open "o" "r" 7)))
        (unwind-protect
            (with-current-buffer buf
              (goto-char (point-min))
              (search-forward "L9")
              (decknix-pr-review-view-open-thread)
              (should (equal "https://github.com/o/r/pull/7#discussion_r900" opened)))
          (kill-buffer buf))))))

(ert-deftest decknix-prv--a-stale-reply-is-ignored ()
  "A fetch from before a refresh must not paint over the newer one."
  (let* ((pending nil)
         (decknix-pr-review-view-gh-function (lambda (_args cb) (push cb pending)))
        (decknix-pr-review-view-state-root (make-temp-file "prv" t)))
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (let ((buf (decknix-pr-review-view-open "o" "r" 7)))
        (unwind-protect
            (with-current-buffer buf
              (let ((old (car (last pending))))
                (decknix-pr-review-view-refresh)
                (funcall old t "{\"title\":\"STALE\"}")
                (should-not (string-match-p "STALE" (buffer-string)))))
          (kill-buffer buf))))))

(ert-deftest decknix-prv--cycle-verdict-and-edit-inline-comments ()
  "Inline comments and verdict can be edited in place and written back to plan.json."
  (let ((decknix-pr-review-view-gh-function #'ignore)
        (decknix-pr-review-view-state-root (make-temp-file "prv" t)))
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (let ((buf (decknix-pr-review-view-open "o" "r" 7)))
        (unwind-protect
            (with-current-buffer buf
              (decknix-pr-review-view-add-inline-comment "src/Foo.kt" 42 "nit: rename x")
              (should (string-match-p "src/Foo.kt:42  nit: rename x" (buffer-string)))
              (should (string-match-p "LGTM \\+ 1 inline comment" (buffer-string)))
              (decknix-pr-review-view-cycle-verdict)
              (should (string-match-p "verdict  COMMENT" (buffer-string)))
              (goto-char (point-min))
              (search-forward "src/Foo.kt:42")
              (decknix-pr-review-view-delete-inline-comment)
              (should-not (string-match-p "src/Foo.kt:42" (buffer-string)))
              (should (string-match-p "Before (What)"
                                      (decknix-pr-review-view-canvas-html
                                       '((title . "T"))
                                       (plist-get decknix-pr-review-view--data :plan)
                                       nil)))
              (should (eq #'decknix-pr-review-view-cancel
                          (lookup-key decknix-pr-review-view-mode-map (kbd "C-c C-k")))))
          (kill-buffer buf))))))

(provide 'decknix-pr-review-view-test)
;;; decknix-pr-review-view-test.el ends here
