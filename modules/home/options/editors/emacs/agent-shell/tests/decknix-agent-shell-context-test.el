;;; decknix-agent-shell-context-test.el --- Tests for context fetch cores -*- lexical-binding: t -*-

;;; Commentary:
;; Pins the pure parse/shape cores shared by the synchronous and
;; asynchronous `gh' helpers, plus the non-blocking `-gh-async' runner
;; contract.  The async fetchers exist so the on-create refresh and the
;; 60s CI poll never block the Emacs main thread on `gh' network latency;
;; these cores are what let the sync and async paths agree.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'decknix-agent-shell-context)

;; -- Pure: JSON parsing --------------------------------------------------

(ert-deftest decknix-context/parse-json-object ()
  (should (equal 1 (alist-get 'a (decknix--context-parse-json "{\"a\":1}"))))
  ;; Leading/trailing whitespace is tolerated.
  (should (equal 1 (alist-get 'a (decknix--context-parse-json "  {\"a\":1}\n")))))

(ert-deftest decknix-context/parse-json-array ()
  (let ((v (decknix--context-parse-json "[{\"x\":2}]")))
    (should (= 1 (length v)))
    (should (equal 2 (alist-get 'x (elt v 0))))))

(ert-deftest decknix-context/parse-json-nil-on-junk ()
  ;; Empty, whitespace-only, non-JSON, and error-text stdout all yield nil
  ;; so a failed `gh' call can never poison the header data.
  (should (null (decknix--context-parse-json "")))
  (should (null (decknix--context-parse-json "   ")))
  (should (null (decknix--context-parse-json nil)))
  (should (null (decknix--context-parse-json "gh: command failed")))
  (should (null (decknix--context-parse-json "{not valid"))))

;; -- Pure: issue/PR plist ------------------------------------------------

(ert-deftest decknix-context/issue-plist-shape ()
  (let ((p (decknix--context-issue-plist-from-data
            '((state . "OPEN") (title . "Fix it") (url . "http://x")
              (isPullRequest . t)))))
    (should (equal "open" (plist-get p :state)))   ; downcased
    (should (equal "Fix it" (plist-get p :title)))
    (should (equal "http://x" (plist-get p :url)))
    (should (eq 'pr (plist-get p :type))))
  ;; Non-PR resolves to `issue'; missing state defaults to "unknown".
  (let ((p (decknix--context-issue-plist-from-data
            '((title . "T") (url . "u")))))
    (should (eq 'issue (plist-get p :type)))
    (should (equal "unknown" (plist-get p :state))))
  (should (null (decknix--context-issue-plist-from-data nil))))

;; -- Pure: CI plist ------------------------------------------------------

(ert-deftest decknix-context/ci-plist-normalises-status ()
  (should (equal "pass"
                 (plist-get (decknix--context-ci-plist-from-runs
                             [((status . "completed") (conclusion . "success")
                               (name . "CI") (url . "u"))])
                            :status)))
  (should (equal "fail"
                 (plist-get (decknix--context-ci-plist-from-runs
                             [((status . "completed") (conclusion . "failure"))])
                            :status)))
  (should (equal "running"
                 (plist-get (decknix--context-ci-plist-from-runs
                             [((status . "in_progress"))])
                            :status)))
  ;; Empty array / nil → nil (never clobber existing CI with "no data").
  (should (null (decknix--context-ci-plist-from-runs [])))
  (should (null (decknix--context-ci-plist-from-runs nil))))

;; -- Pure: review thread counting ---------------------------------------

(ert-deftest decknix-context/count-review-threads ()
  (should (equal '(0 . 0) (decknix--context-count-review-threads nil)))
  (should (equal '(0 . 0) (decknix--context-count-review-threads [])))
  ;; Two threads, one resolved → total 2, unresolved 1.
  (should (equal '(2 . 1)
                 (decknix--context-count-review-threads
                  [((isResolved . t)) ((isResolved . :json-false))])))
  ;; Accepts a list as well as a vector.
  (should (equal '(1 . 1)
                 (decknix--context-count-review-threads
                  '(((isResolved . :json-false)))))))

;; -- open-prs filter -----------------------------------------------------

(ert-deftest decknix-context/open-prs-filter ()
  (with-temp-buffer
    (setq decknix--context-items
          '(("#1" . (:type pr :state "open"))
            ("#2" . (:type pr :state "closed"))
            ("#3" . (:type issue :state "open"))
            ("#4" . (:type pr :state "open"))))
    (let ((open (decknix--context-open-prs)))
      (should (equal '("#1" "#4") (mapcar #'car open))))))

;; -- Async runner contract ----------------------------------------------

(ert-deftest decknix-context/gh-async-nil-when-process-fails ()
  "When the subprocess cannot start, ON-DONE is called with nil, no hang."
  (cl-letf (((symbol-function 'start-process-shell-command)
             (lambda (&rest _) (error "cannot spawn"))))
    (let ((called 'unset))
      (decknix--context-gh-async "issue view 1" (lambda (d) (setq called d)))
      (should (null called)))))

(ert-deftest decknix-context/gh-async-parses-subprocess-output ()
  "The async path exercises spawn → collect → parse → callback off-thread.
A real (offline) `sh -c printf' stands in for `gh' so the sentinel and
JSON parse are covered without network or the `gh' binary."
  (cl-letf (((symbol-function 'start-process-shell-command)
             (lambda (name buffer _command)
               (start-process name buffer "sh" "-c" "printf '%s' '{\"n\":7}'"))))
    (let ((result 'pending))
      (decknix--context-gh-async "whatever" (lambda (d) (setq result d)))
      (with-timeout (5 (setq result 'timeout))
        (while (eq result 'pending)
          (accept-process-output nil 0.05)))
      (should (listp result))
      (should (equal 7 (alist-get 'n result))))))

(provide 'decknix-agent-shell-context-test)
;;; decknix-agent-shell-context-test.el ends here
