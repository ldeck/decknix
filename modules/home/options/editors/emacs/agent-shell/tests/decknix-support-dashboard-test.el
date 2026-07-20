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

;; -- alert feed (CSV) ---------------------------------------------------

;; Real Slack MCP conversations_history shape: a leading "OK ...: header" line,
;; then CSV rows (Text at index 6, Time at 7, BotName at 9), some rows quoted
;; because the message contains a comma.
(defconst decknix-support-dashboard-test--alert-csv
  (concat
   "OK  conversations_history: MsgID,UserID,UserName,RealName,Channel,ThreadTs,Text,Time,Reactions,BotName,FileCount,AttachmentIDs,HasMedia,Cursor\n"
   "1784290965.371799,U012,U012,U012,C08A5P8PN2G,1784290965.371799,A A119.94 cost anomaly on AlloyDB,2026-07-17T12:22:45Z,,Doitsy,0,,false,\n"
   "1783755099.501249,U012,U012,U012,C08A5P8PN2G,1783755099.501249,\"REMINDER A A1,312.69 cost anomaly on App Engine\",2026-07-11T07:31:39Z,,Doitsy,0,,false,\n"))

(ert-deftest decknix-support-dashboard/csv-line-plain-and-quoted ()
  "The CSV line parser splits plain fields and keeps commas inside quotes."
  (should (equal '("a" "b" "c")
                 (decknix--support-dashboard-parse-csv-line "a,b,c")))
  (should (equal '("a" "b,c" "d")
                 (decknix--support-dashboard-parse-csv-line "a,\"b,c\",d")))
  (should (equal '("x\"y")
                 (decknix--support-dashboard-parse-csv-line "\"x\"\"y\""))))

(ert-deftest decknix-support-dashboard/parse-alerts-from-csv ()
  "Alerts parse from the CSV, header dropped, text/time/bot extracted, commas
inside a quoted message preserved."
  (let ((alerts (decknix--support-dashboard-parse-alerts
                 decknix-support-dashboard-test--alert-csv)))
    (should (= 2 (length alerts)))
    (should (equal "A A119.94 cost anomaly on AlloyDB"
                   (alist-get 'text (car alerts))))
    (should (equal "2026-07-17T12:22:45Z" (alist-get 'time (car alerts))))
    (should (equal "Doitsy" (alist-get 'bot (car alerts))))
    (should (equal "REMINDER A A1,312.69 cost anomaly on App Engine"
                   (alist-get 'text (cadr alerts))))))

(ert-deftest decknix-support-dashboard/parse-alerts-blank-nil ()
  "Blank alert output degrades to nil."
  (should (null (decknix--support-dashboard-parse-alerts "")))
  (should (null (decknix--support-dashboard-parse-alerts nil))))

(ert-deftest decknix-support-dashboard/format-alert-extracts-hhmm ()
  "An alert row shows HH:MM from the ISO time and the message text."
  (let ((row (decknix--support-dashboard-format-alert
              '((time . "2026-07-17T12:22:45Z") (text . "cost anomaly")))))
    (should (string-match-p "12:22" row))
    (should (string-match-p "cost anomaly" row))))

(ert-deftest decknix-support-dashboard/render-alerts-empty-and-populated ()
  "The alert section renders a placeholder when empty and rows when populated."
  (should (string-match-p "(no recent alerts)"
                          (decknix--support-dashboard-render-alerts nil)))
  (let ((text (decknix--support-dashboard-render-alerts
               (decknix--support-dashboard-parse-alerts
                decknix-support-dashboard-test--alert-csv))))
    (should (string-match-p "doit-collab" text))
    (should (string-match-p "12:22" text))))

(ert-deftest decknix-support-dashboard/render-full-composes-sections ()
  "The composite render carries both the DoS board and the alert feed + footer."
  (let* ((issues (decknix--support-dashboard-parse
                  decknix-support-dashboard-test--bare-json))
         (alerts (decknix--support-dashboard-parse-alerts
                  decknix-support-dashboard-test--alert-csv))
         (text (decknix--support-dashboard-render-full
                issues nil alerts nil "09:41:00")))
    (should (string-match-p "DoS Board" text))
    (should (string-match-p "DOS-429" text))
    (should (string-match-p "Alerts — #nurturecloud-doit-collab" text))
    (should (string-match-p "AlloyDB" text))
    (should (string-match-p "2 open · 2 alerts" text))
    (should (string-match-p "updated 09:41:00" text))
    ;; DoS section precedes the Alerts section
    (should (< (string-match "DoS Board" text)
               (string-match "Alerts —" text)))))

(ert-deftest decknix-support-dashboard/render-full-errors-and-unconfigured ()
  "Section errors and an unconfigured alert feed render inline, not as a crash."
  (let ((text (decknix--support-dashboard-render-full
               nil "jira down" nil 'unconfigured "09:41:00")))
    (should (string-match-p "Error: jira down" text))
    (should (string-match-p "(alert feed not configured)" text))))

;; -- row actions --------------------------------------------------------

(ert-deftest decknix-support-dashboard/format-issue-carries-key-property ()
  "Each formatted row carries its issue key as the `decknix-issue-key' property
so row-action commands can target the row at point."
  (let ((row (decknix--support-dashboard-format-issue
              '((key . "DOS-429") (status . "In Progress") (summary . "x")))))
    (should (equal "DOS-429" (get-text-property 0 'decknix-issue-key row)))))

(ert-deftest decknix-support-dashboard/issue-key-at-point ()
  "`issue-key-at-point' reads the key property at point in the buffer."
  (with-temp-buffer
    (insert (decknix--support-dashboard-format-issue
             '((key . "DOS-9") (status . "To Do") (summary . "y"))))
    (goto-char (point-min))
    (should (equal "DOS-9" (decknix-support-dashboard-issue-key-at-point)))
    (goto-char (point-max))
    ;; End-of-line still on the propertized row.
    (should (equal "DOS-9" (get-text-property (1- (point)) 'decknix-issue-key)))))

;; -- weekly report resolution (pure) ------------------------------------

;; The exact shape `atlassian-cli --format json confluence search cql' returns:
;; a bare array of {content_type, id, title}, newest-first by `created desc'.
(defconst decknix-support-dashboard-test--report-json
  "[{\"content_type\":\"page\",\"id\":\"4929126621\",\"title\":\"2026-07-28: Weekly Techops Report\"},{\"content_type\":\"page\",\"id\":\"4914315412\",\"title\":\"2026-07-21: Weekly Techops Report\"},{\"content_type\":\"page\",\"id\":\"4900487263\",\"title\":\"2026-07-14: Weekly Techops Report\"}]")

(ert-deftest decknix-support-dashboard/pick-report-newest-by-date ()
  "The newest dated matching page is picked regardless of input order."
  (let* ((pages (decknix--support-dashboard-parse
                 decknix-support-dashboard-test--report-json))
         ;; Reverse so date-sorting, not input order, must do the work.
         (page (decknix--support-dashboard-pick-report-page (reverse pages))))
    (should (equal "4929126621" (alist-get 'id page)))
    (should (equal "2026-07-28: Weekly Techops Report" (alist-get 'title page)))))

(ert-deftest decknix-support-dashboard/pick-report-filters-non-matching ()
  "Pages whose title lacks the match string are ignored; nil when none match."
  (let ((page (decknix--support-dashboard-pick-report-page
               '(((id . "1") (title . "Runbook: Incident Response"))
                 ((id . "2") (title . "2026-07-28: Weekly Techops Report"))))))
    (should (equal "2" (alist-get 'id page))))
  (should (null (decknix--support-dashboard-pick-report-page
                 '(((id . "1") (title . "Unrelated page"))))))
  (should (null (decknix--support-dashboard-pick-report-page nil))))

(ert-deftest decknix-support-dashboard/pick-report-undated-falls-back-to-order ()
  "Undated matching titles keep CQL's newest-first input order."
  (let ((page (decknix--support-dashboard-pick-report-page
               '(((id . "new") (title . "Weekly Techops Report"))
                 ((id . "old") (title . "Weekly Techops Report"))))))
    (should (equal "new" (alist-get 'id page)))))

(ert-deftest decknix-support-dashboard/report-url-built-from-space-and-id ()
  "The report URL joins base, space, and page id under /wiki/spaces."
  (let ((decknix-support-dashboard-jira-base-url "https://x.atlassian.net")
        (decknix-support-dashboard-confluence-space "TechOps"))
    (should (equal "https://x.atlassian.net/wiki/spaces/TechOps/pages/4929126621"
                   (decknix--support-dashboard-report-url "4929126621")))))

(ert-deftest decknix-support-dashboard/title-date-extracts-or-nil ()
  "A leading YYYY-MM-DD is extracted; an undated title yields nil."
  (should (equal "2026-07-28"
                 (decknix--support-dashboard-title-date
                  "2026-07-28: Weekly Techops Report")))
  (should (null (decknix--support-dashboard-title-date "Weekly Techops Report"))))

;; -- daily-log draft (pure) ---------------------------------------------

(ert-deftest decknix-support-dashboard/daily-log-draft-summarises-state ()
  "The draft carries the date, per-status DoS keys, alert lines, and prompts."
  (let* ((issues (decknix--support-dashboard-parse
                  decknix-support-dashboard-test--bare-json))
         (alerts (decknix--support-dashboard-parse-alerts
                  decknix-support-dashboard-test--alert-csv))
         (draft (decknix--support-dashboard-daily-log-draft
                 issues alerts "2026-07-20")))
    (should (string-match-p "2026-07-20 — Daily update" draft))
    (should (string-match-p "DoS board:\\* 2 open" draft))
    (should (string-match-p "In Progress (1): DOS-429" draft))
    (should (string-match-p "To Do (1): DOS-430" draft))
    (should (string-match-p "Alerts:\\* 2 recent" draft))
    (should (string-match-p "AlloyDB" draft))
    (should (string-match-p "Actions taken:" draft))
    (should (string-match-p "Follow-ups / next:" draft))))

(ert-deftest decknix-support-dashboard/daily-log-draft-empty-state ()
  "With no issues or alerts the draft still renders placeholders, never errors."
  (let ((draft (decknix--support-dashboard-daily-log-draft nil nil "2026-07-20")))
    (should (string-match-p "DoS board:\\* 0 open" draft))
    (should (string-match-p "Alerts:\\* 0 recent" draft))
    (should (string-match-p "(none)" draft))))

(provide 'decknix-support-dashboard-test)
;;; decknix-support-dashboard-test.el ends here
