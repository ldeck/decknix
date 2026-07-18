;;; decknix-support-dashboard-test.el --- Tests for the support dashboard -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-support-dashboard "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests for the PURE layer of the support monitoring dashboard: parsing
;; atlassian-cli JSON, formatting a single issue row, and rendering the whole
;; buffer text.  No live Jira, no live buffer, no timers.

;;; Code:

(require 'ert)
(require 'decknix-support-dashboard)

;; A bare array in the exact shape `atlassian-cli --format json jira issue
;; search' returns (flat fields: key, status, assignee, issue_type, summary).
(defconst decknix-support-dashboard-test--bare-json
  "[{\"assignee\":\"Ye Wang\",\"issue_type\":\"DoS Operations\",\"key\":\"DOS-429\",\"status\":\"In Progress\",\"summary\":\"Flaky test\"},{\"assignee\":\"Sam Nazha\",\"issue_type\":\"Bug\",\"key\":\"DOS-430\",\"status\":\"To Do\",\"summary\":\"Cost spike\"}]")

;; -- parse --------------------------------------------------------------

(ert-deftest decknix-support-dashboard/parse-bare-array ()
  "A bare JSON array parses to a list of issue alists."
  (let ((issues (decknix--support-dashboard-parse
                 decknix-support-dashboard-test--bare-json)))
    (should (= 2 (length issues)))
    (should (equal "DOS-429" (alist-get 'key (car issues))))
    (should (equal "In Progress" (alist-get 'status (car issues))))
    (should (equal "Sam Nazha" (alist-get 'assignee (cadr issues))))))

(ert-deftest decknix-support-dashboard/parse-envelope ()
  "The --envelope {\"data\":[...],\"count\":N} form unwraps to the array."
  (let ((issues (decknix--support-dashboard-parse
                 "{\"data\":[{\"key\":\"DOS-1\",\"status\":\"To Do\"}],\"count\":1}")))
    (should (= 1 (length issues)))
    (should (equal "DOS-1" (alist-get 'key (car issues))))))

(ert-deftest decknix-support-dashboard/parse-blank-and-invalid-return-nil ()
  "Blank or invalid input degrades to nil, never signals."
  (should (null (decknix--support-dashboard-parse "")))
  (should (null (decknix--support-dashboard-parse "   ")))
  (should (null (decknix--support-dashboard-parse nil)))
  (should (null (decknix--support-dashboard-parse "not json {["))))

(ert-deftest decknix-support-dashboard/parse-empty-array ()
  "An empty array parses to nil (no issues)."
  (should (null (decknix--support-dashboard-parse "[]"))))

;; -- format-issue -------------------------------------------------------

(ert-deftest decknix-support-dashboard/format-issue-has-fields ()
  "A formatted row carries the key, bracketed status, assignee, and summary."
  (let ((row (decknix--support-dashboard-format-issue
              '((key . "DOS-429") (status . "In Progress")
                (assignee . "Ye Wang") (summary . "Flaky test")))))
    (should (string-match-p "DOS-429" row))
    (should (string-match-p "\\[In Progress\\]" row))
    (should (string-match-p "Ye Wang" row))
    (should (string-match-p "Flaky test" row))))

(ert-deftest decknix-support-dashboard/format-issue-defaults-unassigned ()
  "A missing assignee renders as `unassigned', missing fields don't error."
  (let ((row (decknix--support-dashboard-format-issue
              '((key . "DOS-9") (status . "To Do") (summary . "x")))))
    (should (string-match-p "unassigned" row))))

;; -- render -------------------------------------------------------------

(ert-deftest decknix-support-dashboard/render-empty ()
  "No issues renders the empty placeholder and a 0-open footer."
  (let ((text (decknix--support-dashboard-render nil)))
    (should (string-match-p "DoS Board" text))
    (should (string-match-p "(no open DoS issues)" text))
    (should (string-match-p "0 open" text))))

(ert-deftest decknix-support-dashboard/render-with-issues-and-timestamp ()
  "Issues render one row each; the count and timestamp appear in the footer."
  (let* ((issues (decknix--support-dashboard-parse
                  decknix-support-dashboard-test--bare-json))
         (text (decknix--support-dashboard-render issues "09:41:00")))
    (should (string-match-p "DOS-429" text))
    (should (string-match-p "DOS-430" text))
    (should (string-match-p "2 open" text))
    (should (string-match-p "updated 09:41:00" text))))

(ert-deftest decknix-support-dashboard/render-timestamp-omitted-when-nil ()
  "Omitting the timestamp keeps render pure (no `updated' clause)."
  (let ((text (decknix--support-dashboard-render
               (decknix--support-dashboard-parse
                decknix-support-dashboard-test--bare-json))))
    (should-not (string-match-p "updated" text))))

;; -- group-by-status ----------------------------------------------------

(ert-deftest decknix-support-dashboard/group-orders-in-progress-first ()
  "In Progress leads; To Do trails; issues keep input order within a group."
  (let* ((issues (decknix--support-dashboard-parse
                  decknix-support-dashboard-test--bare-json)) ; DOS-429 IP, DOS-430 ToDo
         (groups (decknix--support-dashboard-group-by-status issues)))
    (should (equal "In Progress" (car (nth 0 groups))))
    (should (equal "To Do" (car (nth 1 groups))))
    (should (equal "DOS-429" (alist-get 'key (car (cdr (nth 0 groups))))))))

(ert-deftest decknix-support-dashboard/group-unknown-status-sorts-after ()
  "A status not in the preferred order sorts after the listed ones."
  (let ((groups (decknix--support-dashboard-group-by-status
                 '(((key . "A") (status . "Xyzzy"))
                   ((key . "B") (status . "In Progress"))))))
    (should (equal "In Progress" (car (nth 0 groups))))
    (should (equal "Xyzzy" (car (nth 1 groups))))))

(ert-deftest decknix-support-dashboard/render-shows-group-headers ()
  "Render emits per-status group headers with counts."
  (let ((text (decknix--support-dashboard-render
               (decknix--support-dashboard-parse
                decknix-support-dashboard-test--bare-json))))
    (should (string-match-p "In Progress (1)" text))
    (should (string-match-p "To Do (1)" text))
    ;; In Progress header precedes the To Do header
    (should (< (string-match "In Progress (1)" text)
               (string-match "To Do (1)" text)))))

(provide 'decknix-support-dashboard-test)
;;; decknix-support-dashboard-test.el ends here
