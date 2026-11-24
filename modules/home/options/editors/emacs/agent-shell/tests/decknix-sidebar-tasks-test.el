;;; decknix-sidebar-tasks-test.el --- Tests for the sidebar Tasks section -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-sidebar-tasks)

(defvar decknix--hub-jira-tasks nil)
(defvar decknix--hub-github-issues nil)
(defvar decknix--hub-task-chores nil)
(defvar decknix--hub-reviews nil)
(defvar decknix--hub-wip nil)

(defconst tasks-test--jira
  '((items . (((key . "HX-1") (summary . "first") (status . "In Progress")
               (status_category . "indeterminate") (url . "https://j/HX-1"))
              ((key . "HX-2") (summary . "second") (status . "Blocked")
               (status_category . "indeterminate") (url . "https://j/HX-2"))
              ((key . "HX-3") (summary . "gone") (status . "Done") (status_category . "done"))
              ((key . "HX-4") (summary . "not started") (status . "To Do")
               (status_category . "new") (url . "https://j/HX-4"))))
    (pick_up . (((key . "DOS-9") (summary . "take me") (status . "To Do")
                 (status_category . "new") (url . "https://j/DOS-9"))))))

(defconst tasks-test--chores
  '((items . (((uuid . "u1") (id . 4) (description . "renew cert") (project . "home"))))))

(defconst tasks-test--issues
  '((items . (((repo . "o/widget") (number . 12) (title . "fix it") (url . "https://gh/12"))))))

(defmacro tasks-test--with (sessions &rest body)
  "Run BODY with the fixture feeds, SESSIONS as the snapshot, and fresh state."
  (declare (indent 1))
  `(let ((decknix--hub-jira-tasks tasks-test--jira)
         (decknix--hub-task-chores tasks-test--chores)
         (decknix--hub-github-issues tasks-test--issues)
         (decknix--layout-wip-memo nil)
         (decknix--layout-expanded (make-hash-table :test 'equal))
         (decknix-sidebar-tasks-per-group 5))
     (decknix-layout-invalidate-tasks)
     (cl-letf (((symbol-function 'decknix--layout-sessions) (lambda () ,sessions))
               ((symbol-function 'decknix--sidebar-render-section-header)
                (lambda (title &optional _id) (insert " " title "\n"))))
       ,@body)))

(defun tasks-test--render ()
  (with-temp-buffer
    (decknix--layout-render-tasks 0 60)
    (buffer-string)))

(ert-deftest decknix-tasks--keys-are-found-in-any-case ()
  (should (equal '("HX-1610" "CONN-2") (decknix--tasks-keys-in '("work/hx-1610" "CONN-2 x" "HX-1610")))))

(ert-deftest decknix-tasks--a-session-works-a-key-by-name-tag-or-pr ()
  (let ((table (decknix--tasks-session-keys
                '(("*Claude: hx-1/fix*" ("work") nil "working" nil nil)
                  ("*Claude: lane*" ("dos-9") nil "ready" nil nil)
                  ("*Claude: other*" nil nil "ready" nil nil))
                (list (list :session '("*Claude: other*")
                            :prs (list (list :pr '((title . "CONN-7 thing")) :branch "x")))))))
    (should (equal '("*Claude: hx-1/fix*") (gethash "HX-1" table)))
    (should (equal '("*Claude: lane*") (gethash "DOS-9" table)))
    (should (equal '("*Claude: other*") (gethash "CONN-7" table)))))

(ert-deftest decknix-tasks--groups-in-order-and-done-dropped ()
  (tasks-test--with nil
    (let ((groups (decknix--tasks-current-groups)))
      (should (equal '("In progress" "To pick up" "Chores" "Issues")
                     (mapcar (lambda (g) (plist-get g :label)) groups)))
      (should (equal '("HX-1" "HX-2")
                     (mapcar (lambda (r) (plist-get r :key)) (plist-get (car groups) :rows)))))))

(ert-deftest decknix-tasks--a-worked-issue-is-marked-and-listed-first ()
  (tasks-test--with '(("*Claude: hx-2*" nil nil "working" nil nil))
    (let ((out (tasks-test--render)))
      (should (string-match-p "● HX-2 second" out))
      (should (< (string-match "HX-2" out) (string-match "HX-1" out))))))

(ert-deftest decknix-tasks--rows-carry-what-ret-needs ()
  (tasks-test--with nil
    (let ((out (tasks-test--render)))
      (let ((pos (string-match "HX-2" out)))
        (should (eq 'task (get-text-property pos 'decknix-hub-type out)))
        (should (equal "https://j/HX-2" (get-text-property pos 'decknix-hub-url out)))
        (should (equal '(:foreground "#ff5f5f") (get-text-property pos 'face out))))
      (should (eq 'issue (get-text-property (string-match "widget#12" out) 'decknix-hub-type out)))
      (let ((pos (string-match "renew cert" out)))
        (should (eq 'chore (get-text-property pos 'decknix-hub-type out)))
        (should (equal "u1" (get-text-property pos 'decknix-layout-chore out)))))))

(ert-deftest decknix-tasks--each-group-is-capped-and-the-rest-named ()
  (tasks-test--with nil
    (let ((decknix-sidebar-tasks-per-group 1))
      (decknix-layout-invalidate-tasks)
      (let ((out (tasks-test--render)))
        (should (string-match-p "HX-1" out))
        (should-not (string-match-p "HX-2" out))
        (should (string-match-p "… 1 more" out)))
      (puthash "tasks-all:in-progress" t decknix--layout-expanded)
      (should (string-match-p "HX-2" (tasks-test--render))))))

(ert-deftest decknix-tasks--a-collapsed-group-shows-only-its-header ()
  (tasks-test--with nil
    (puthash "wip-collapsed:tasks:chores" t decknix--layout-expanded)
    (let ((out (tasks-test--render)))
      (should (string-match-p "▸ Chores (1)" out))
      (should-not (string-match-p "renew cert" out)))))

(ert-deftest decknix-tasks--nothing-to-show-renders-nothing ()
  (let ((decknix--hub-jira-tasks nil) (decknix--hub-task-chores nil)
        (decknix--hub-github-issues nil) (decknix--layout-wip-memo nil))
    (decknix-layout-invalidate-tasks)
    (cl-letf (((symbol-function 'decknix--layout-sessions) (lambda () nil)))
      (with-temp-buffer
        (should (= 3 (decknix--layout-render-tasks 3 60)))
        (should (= 0 (buffer-size)))))))

(ert-deftest decknix-tasks--jira-errors-are-named ()
  (tasks-test--with nil
    (let ((decknix--hub-jira-tasks (append '((errors . ("pick-up: 400"))) tasks-test--jira)))
      (decknix-layout-invalidate-tasks)
      (should (string-match-p "Jira partial: pick-up: 400" (tasks-test--render))))))

(ert-deftest decknix-tasks--chore-info-runs-task-in-a-child ()
  (let (cmd)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args) (setq cmd (plist-get args :command)) nil)))
      (decknix-layout-chore-info "u1"))
    (should (equal '("task" "rc.gc=off" "rc.hooks=off" "rc.verbose=nothing" "u1" "info") cmd))))

(ert-deftest decknix-tasks--in-progress-is-the-in-progress-category-only ()
  "An assigned To Do issue is not in progress: HX-4 sat in that group."
  (tasks-test--with nil
    (should-not (string-match-p "HX-4" (tasks-test--render)))))

(ert-deftest decknix-tasks--groups-count-the-true-totals ()
  "The groups read `(50)', the fetch cap, however many there were."
  (tasks-test--with nil
    (let ((decknix--hub-jira-tasks (append '((in_progress_total . 137) (pick_up_total . 64))
                                           tasks-test--jira)))
      (decknix-layout-invalidate-tasks)
      (let ((out (tasks-test--render)))
        (should (string-match-p "In progress (137)" out))
        (should (string-match-p "To pick up (64)" out))
        (should (string-match-p "… 135 more" out))
        (should (string-match-p "… 63 more" out))
        (should (string-match-p "Tasks (203)" out)))
      (puthash "tasks-all:in-progress" t decknix--layout-expanded)
      (should (string-match-p "… 135 more in Jira" (tasks-test--render))))))

;;; decknix-sidebar-tasks-test.el ends here
