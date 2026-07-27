;;; decknix-dos-board-test.el --- Tests for the DoS priority board -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-dos-board "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests for the PURE layer of the live DoS priority board: parsing the
;; `nc-dos-sidebar --json' model, filtering lanes, formatting a row, report
;; freshness, header context lines, and truncation.  No CLI, no live buffer,
;; no timers.

;;; Code:

(require 'ert)
(require 'decknix-dos-board)

;; A trimmed but shape-faithful `nc-dos-sidebar --json' payload: three lanes in
;; the flattened `items' list plus the context the header renders from.
(defconst decknix-dos-board-test--json
  (concat
   "{"
   "\"generated\":\"2026-07-28 05:54:32\",\"dow\":1,\"weekday\":\"Tuesday\","
   "\"freeze\":false,\"deploy_day\":true,"
   "\"alr_triaged_todo_count\":4,\"dos_open_count\":52,"
   "\"alr_untriaged\":[{\"key\":\"ALR-1\"},{\"key\":\"ALR-2\"}],"
   "\"dos_mine_in_progress\":[{\"key\":\"DOS-9\"}],"
   "\"hot_other\":[{\"key\":\"HOT-1\"},{\"key\":\"HOT-2\"}],"
   "\"report\":{\"id\":\"1\",\"title\":\"2026-07-28: Weekly Techops Report\","
   "\"url\":\"https://x/wiki/1\"},"
   "\"items\":["
   "{\"kind\":\"incident\",\"key\":\"HOT-228\",\"summary\":\"Listing Perf out of date\","
   "\"status\":\"In Recovery\",\"assignee\":\"Lachlan Deck\",\"ai_able\":false,"
   "\"url\":\"https://x/browse/HOT-228\"},"
   "{\"kind\":\"alert\",\"key\":\"ALR-1\",\"summary\":\"500 rate spike\","
   "\"status\":\"To Do\",\"assignee\":\"\",\"ai_able\":true,"
   "\"url\":\"https://x/browse/ALR-1\"},"
   "{\"kind\":\"dos\",\"key\":\"DOS-9\",\"summary\":\"Flaky test\","
   "\"status\":\"In Progress\",\"assignee\":\"Lachlan Deck\",\"ai_able\":false,"
   "\"url\":\"https://x/browse/DOS-9\"}"
   "]}"))

(defun decknix-dos-board-test--model ()
  (decknix-dos-board--parse decknix-dos-board-test--json))

;; -- parse --------------------------------------------------------------

(ert-deftest decknix-dos-board/parse-ok ()
  "A well-formed payload parses to an alist with symbol keys + list arrays."
  (let ((m (decknix-dos-board-test--model)))
    (should (equal "Tuesday" (alist-get 'weekday m)))
    (should (eq t (alist-get 'deploy_day m)))
    (should (null (alist-get 'freeze m)))          ; JSON false -> nil
    (should (= 3 (length (alist-get 'items m))))
    (should (listp (alist-get 'items m)))))

(ert-deftest decknix-dos-board/parse-blank-and-invalid-return-nil ()
  "Blank or invalid input degrades to nil, never signals."
  (should (null (decknix-dos-board--parse "")))
  (should (null (decknix-dos-board--parse "   ")))
  (should (null (decknix-dos-board--parse "not json {")))
  (should (null (decknix-dos-board--parse nil))))

;; -- lane filtering -----------------------------------------------------

(ert-deftest decknix-dos-board/lane-items-filters-by-kind ()
  "Each lane returns only its kind, in order."
  (let ((m (decknix-dos-board-test--model)))
    (should (equal '("HOT-228")
                   (mapcar (lambda (i) (alist-get 'key i))
                           (decknix-dos-board--lane-items m "incident"))))
    (should (equal '("ALR-1")
                   (mapcar (lambda (i) (alist-get 'key i))
                           (decknix-dos-board--lane-items m "alert"))))
    (should (equal '("DOS-9")
                   (mapcar (lambda (i) (alist-get 'key i))
                           (decknix-dos-board--lane-items m "dos"))))
    (should (null (decknix-dos-board--lane-items m "nope")))))

;; -- item line ----------------------------------------------------------

(ert-deftest decknix-dos-board/item-line-shape ()
  "An item line carries key, status, summary, ai marker, and @assignee."
  (let* ((it (car (decknix-dos-board--lane-items
                   (decknix-dos-board-test--model) "alert")))
         (line (decknix-dos-board--item-line it)))
    (should (string-prefix-p "ALR-1" line))
    (should (string-match-p "To Do" line))
    (should (string-match-p "500 rate spike" line))
    (should (string-match-p "\\[ai\\]" line))))     ; ai_able -> [ai]

(ert-deftest decknix-dos-board/item-line-no-ai-no-marker ()
  "A non-ai item shows no [ai] marker, and a blank assignee no @."
  (let* ((it '((key . "DOS-7") (status . "To Do") (summary . "x")
               (assignee . "") (ai_able . nil)))
         (line (decknix-dos-board--item-line it)))
    (should-not (string-match-p "\\[ai\\]" line))
    (should-not (string-match-p "@" line))))

(ert-deftest decknix-dos-board/item-line-unassigned-suppressed ()
  "The CLI's literal \"unassigned\" assignee is not shown as `@unassigned'."
  (let* ((it '((key . "ALR-9") (status . "Triage") (summary . "x")
               (assignee . "unassigned") (ai_able . nil)))
         (line (decknix-dos-board--item-line it)))
    (should-not (string-match-p "@" line))))

;; -- report freshness ---------------------------------------------------

(ert-deftest decknix-dos-board/report-status ()
  "Report is current when its title starts with today, else stale/missing."
  (let ((report '((title . "2026-07-28: Weekly Techops Report"))))
    (should (eq 'current (car (decknix-dos-board--report-status report "2026-07-28"))))
    (should (eq 'stale   (car (decknix-dos-board--report-status report "2026-07-29"))))
    (should (eq 'missing (car (decknix-dos-board--report-status nil "2026-07-28"))))))

;; -- header context -----------------------------------------------------

(ert-deftest decknix-dos-board/header-deploy-day ()
  "Deploy day is announced and counts are summarised."
  (let* ((m (decknix-dos-board-test--model))
         (lines (decknix-dos-board--header-lines m "2026-07-28"))
         (all (string-join lines "\n")))
    (should (string-match-p "DEPLOY DAY" all))
    (should (string-match-p "✓ current" all))         ; report today
    (should (string-match-p "1 incident\\b" all))     ; singular
    (should (string-match-p "2 untriaged alerts" all))
    (should (string-match-p "52 DoS" all))))

(ert-deftest decknix-dos-board/header-freeze-overrides-deploy ()
  "On a freeze day the posture line says FREEZE, not deploy."
  (let* ((m (decknix-dos-board--parse
             "{\"weekday\":\"Saturday\",\"freeze\":true,\"deploy_day\":false,\"items\":[]}"))
         (lines (decknix-dos-board--header-lines m "2026-08-01"))
         (all (string-join lines "\n")))
    (should (string-match-p "FREEZE" all))
    (should-not (string-match-p "DEPLOY DAY" all))))

;; -- truncate -----------------------------------------------------------

(ert-deftest decknix-dos-board/truncate ()
  "Truncate collapses whitespace and clips with an ellipsis."
  (should (equal "abc" (decknix-dos-board--truncate "abc" 10)))
  (should (equal "a b c" (decknix-dos-board--truncate "a  b\n c" 10)))
  (should (equal "" (decknix-dos-board--truncate nil 10)))
  (should (equal "abcd…" (decknix-dos-board--truncate "abcdefgh" 5))))

(provide 'decknix-dos-board-test)
;;; decknix-dos-board-test.el ends here
