;;; decknix-sidebar-tasks.el --- Tasks section of the session-first sidebar -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-sidebar-layout-render "0.1"))
;; Keywords: agent, hub, jira, sidebar

;;; Commentary:
;;
;; What there is to do, beside what is being done.  Four groups, each
;; capped at `decknix-sidebar-tasks-per-group' rows and collapsible:
;;
;;   In progress   Jira issues assigned to me in the In Progress status
;;                 category (not To Do, not Done); `●' when a live
;;                 session works one (its key is in the session's name or
;;                 tags, or in the title or branch of a PR the session owns)
;;   To pick up    unassigned To Do issues in an open sprint of the
;;                 pick-up projects
;;
;; A Jira group's count is the hub's true total (`in_progress_total',
;; `pick_up_total'), not the number of rows fetched, which stops at the
;; fetch cap; `… N more' says how many are not listed.
;;   Chores        pending Taskwarrior chores
;;   Issues        open GitHub issues assigned to me
;;
;; Everything comes from the hub daemon's JSON (jira-tasks.json,
;; task-chores.json, github-issues.json), already parsed by the hub watcher,
;; so the render does no I/O.  The grouping is memoised on the identity of
;; those feeds and of the session snapshot.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'decknix-sidebar-layout)
(require 'decknix-sidebar-layout-render)

(defvar decknix--hub-jira-tasks)
(defvar decknix--hub-github-issues)
(defvar decknix--hub-task-chores)

(declare-function decknix--sidebar-render-section-header
                  "decknix-sidebar-format" (title &optional section-id))

(defcustom decknix-sidebar-tasks-per-group 5
  "Most rows listed per Tasks group before `… N more'; nil lists all."
  :type '(choice (const :tag "All" nil) integer)
  :group 'decknix-ship)

(defconst decknix-sidebar-tasks-key-regexp
  "\\b\\([A-Za-z][A-Za-z0-9]+-[0-9]+\\)\\b"
  "A Jira key, in any case: session tags are lower case.")

(defconst decknix-sidebar-tasks-faces
  '((doing   . (:foreground "#d7af5f"))
    (review  . (:foreground "#c678dd"))
    (blocked . (:foreground "#ff5f5f"))
    (todo    . (:foreground "#5f87af"))
    (done    . (:foreground "#87af87"))
    (quiet   . font-lock-comment-face))
  "Face per task state.")

(defun decknix--tasks-keys-in (strings)
  "Return the Jira keys in STRINGS, upper-cased, without duplicates."
  (let (keys)
    (dolist (s strings)
      (when (stringp s)
        (let ((start 0))
          (while (string-match decknix-sidebar-tasks-key-regexp s start)
            (cl-pushnew (upcase (match-string 1 s)) keys :test #'equal)
            (setq start (match-end 0))))))
    (nreverse keys)))

(defun decknix--tasks-session-keys (sessions rows)
  "Return a hash of Jira KEY -> list of session buffer names working it.
SESSIONS is the live snapshot; ROWS the WIP tree rows, whose claimed PRs
add their titles and branches."
  (let ((table (make-hash-table :test 'equal))
        (prs-of (make-hash-table :test 'equal)))
    (dolist (row rows)
      (puthash (nth 0 (plist-get row :session)) (plist-get row :prs) prs-of))
    (dolist (s sessions)
      (let ((name (nth 0 s)))
        (dolist (key (decknix--tasks-keys-in
                      (append (list name) (nth 1 s)
                              (mapcan (lambda (p)
                                        (list (alist-get 'title (plist-get p :pr))
                                              (plist-get p :branch)))
                                      (copy-sequence (gethash name prs-of))))))
          (cl-pushnew name (gethash key table) :test #'equal))))
    table))

(defun decknix--tasks-jira-state (item)
  "Return ITEM's task state symbol from its Jira status."
  (let ((status (downcase (or (alist-get 'status item) "")))
        (cat (alist-get 'status_category item)))
    (cond ((string-match-p "block" status) 'blocked)
          ((string-match-p "review" status) 'review)
          ((equal cat "done") 'done)
          ((equal cat "indeterminate") 'doing)
          (t 'todo))))

(defun decknix--tasks-jira-row (item group sessions-by-key)
  "Return the row plist for Jira ITEM in GROUP."
  (let ((key (alist-get 'key item)))
    (list :kind 'jira :group group :key key
          :text (alist-get 'summary item)
          :status (alist-get 'status item)
          :state (decknix--tasks-jira-state item)
          :url (alist-get 'url item)
          :sessions (and key (gethash key sessions-by-key)))))

(defun decknix--tasks-chore-row (chore)
  "Return the row plist for Taskwarrior CHORE."
  (list :kind 'chore :group 'chores
        :key (let ((id (alist-get 'id chore))) (and id (format "%s" id)))
        :text (alist-get 'description chore)
        :status (or (alist-get 'project chore) "")
        :state (if (alist-get 'start chore) 'doing 'todo)
        :uuid (alist-get 'uuid chore)))

(defun decknix--tasks-issue-row (issue)
  "Return the row plist for GitHub ISSUE."
  (list :kind 'issue :group 'issues
        :key (format "%s#%s" (car (last (split-string (or (alist-get 'repo issue) "") "/")))
                     (alist-get 'number issue))
        :text (alist-get 'title issue)
        :status ""
        :state 'todo
        :url (alist-get 'url issue)))

(defun decknix--tasks-groups (jira chores issues sessions-by-key)
  "Return the Tasks groups as plists (:id :label :rows), empty ones dropped.
JIRA is the parsed jira-tasks.json, CHORES task-chores.json and ISSUES
github-issues.json.  In progress lists issues a session works first."
  (let* ((mine (mapcar (lambda (i) (decknix--tasks-jira-row i 'in-progress sessions-by-key))
                       (seq-filter (lambda (i) (equal (alist-get 'status_category i) "indeterminate"))
                                   (alist-get 'items jira))))
         (mine (append (seq-filter (lambda (r) (plist-get r :sessions)) mine)
                       (seq-remove (lambda (r) (plist-get r :sessions)) mine))))
    (seq-filter
     (lambda (g) (plist-get g :rows))
     (list (list :id "in-progress" :label "In progress" :rows mine
                 :total (alist-get 'in_progress_total jira))
           (list :id "pick-up" :label "To pick up"
                 :rows (mapcar (lambda (i) (decknix--tasks-jira-row i 'pick-up sessions-by-key))
                               (alist-get 'pick_up jira))
                 :total (alist-get 'pick_up_total jira))
           (list :id "chores" :label "Chores"
                 :rows (mapcar #'decknix--tasks-chore-row (alist-get 'items chores)))
           (list :id "issues" :label "Issues"
                 :rows (mapcar #'decknix--tasks-issue-row (alist-get 'items issues)))))))

(defvar decknix--tasks-memo nil
  "Cons of (INPUTS . GROUPS) from the last `decknix--tasks-current-groups'.")

(defun decknix-layout-invalidate-tasks ()
  "Drop the memoised Tasks groups."
  (setq decknix--tasks-memo nil))

(defun decknix--tasks-current-groups ()
  "Return the Tasks groups for the hub feeds and live sessions, memoised."
  (let* ((jira (bound-and-true-p decknix--hub-jira-tasks))
         (chores (bound-and-true-p decknix--hub-task-chores))
         (issues (bound-and-true-p decknix--hub-github-issues))
         (sessions (decknix--layout-sessions))
         (tree (cdr decknix--layout-wip-memo))
         (inputs (list jira chores issues sessions tree)))
    (if (and decknix--tasks-memo
             (cl-every #'eq inputs (car decknix--tasks-memo)))
        (cdr decknix--tasks-memo)
      (let ((groups (decknix--tasks-groups
                     jira chores issues
                     (decknix--tasks-session-keys sessions (plist-get tree :sessions)))))
        (setq decknix--tasks-memo (cons inputs groups))
        groups))))

(defun decknix--tasks-row-text (row width)
  "Return ROW as one line fitted to WIDTH, with its properties."
  (let* ((working (plist-get row :sessions))
         (glyph (cond (working "●")
                      ((eq (plist-get row :kind) 'chore) "◦")
                      (t "·")))
         (face (alist-get (plist-get row :state) decknix-sidebar-tasks-faces))
         (key (or (plist-get row :key) ""))
         (lead (format "   %s %s " glyph key))
         (room (max 1 (- width (string-width lead))))
         (text (or (plist-get row :text) ""))
         (text (if (> (string-width text) room)
                   (concat (truncate-string-to-width text (max 1 (1- room))) "…")
                 text))
         (line (concat (propertize lead 'face face) (propertize text 'face 'shadow)))
         (props (pcase (plist-get row :kind)
                  ('jira (list 'decknix-hub-type 'task
                               'decknix-hub-url (plist-get row :url)
                               'decknix-hub-jira-key key
                               'decknix-hub-jira-status (plist-get row :status)))
                  ('issue (list 'decknix-hub-type 'issue
                                'decknix-hub-url (plist-get row :url)))
                  ('chore (list 'decknix-hub-type 'chore
                                'decknix-layout-chore (plist-get row :uuid))))))
    (apply #'propertize line
           'decknix-layout-task row
           'help-echo (if working
                          (format "%s: worked by %s" key (string-join working ", "))
                        "RET for actions")
           props)))

(defun decknix--tasks-group-total (group)
  "Return how many items GROUP has: the hub's total, else its rows."
  (max (length (plist-get group :rows)) (or (plist-get group :total) 0)))

(defun decknix--tasks-render-group (line-num width group)
  "Insert GROUP's header and rows.  Returns LINE-NUM."
  (let* ((id (plist-get group :id))
         (rows (plist-get group :rows))
         (total (decknix--tasks-group-total group))
         (key (concat "tasks:" id))
         (all (decknix--layout-expanded-p (concat "tasks-all:" id)))
         (limit (and (not all) decknix-sidebar-tasks-per-group))
         (shown (if limit (seq-take rows limit) rows))
         (held (- total (length shown))))
    (insert (decknix--layout-wip-group-header (plist-get group :label) total key " ")
            "\n")
    (setq line-num (1+ line-num))
    (unless (decknix--layout-collapsed-p key)
      (dolist (row shown)
        (insert (decknix--tasks-row-text row width) "\n")
        (setq line-num (1+ line-num)))
      (when (> held 0)
        ;; Listing all shows what was fetched; the rest are only in Jira.
        (insert (if all
                    (propertize (format "     … %d more in Jira" held)
                                'face 'font-lock-comment-face)
                  (propertize (format "     … %d more" held)
                              'face 'font-lock-comment-face
                              'decknix-layout-expand-key (concat "tasks-all:" id)
                              'help-echo "RET to list them all"))
                "\n")
        (setq line-num (1+ line-num))))
    line-num))

(defun decknix--layout-render-tasks (line-num width)
  "Render the Tasks section from the hub feeds.  Returns LINE-NUM."
  (let ((groups (decknix--tasks-current-groups))
        (errs (alist-get 'errors (bound-and-true-p decknix--hub-jira-tasks))))
    (when (or groups errs)
      (insert "\n")
      (setq line-num (1+ line-num))
      (decknix--sidebar-render-section-header
       (format "Tasks (%d)" (apply #'+ (mapcar #'decknix--tasks-group-total groups)))
       'tasks)
      (setq line-num (1+ line-num))
      (when errs
        (insert (propertize (truncate-string-to-width
                             (format "  ⚠ Jira partial: %s" (car errs)) width nil nil "…")
                            'face 'warning 'help-echo (string-join errs "\n"))
                "\n")
        (setq line-num (1+ line-num)))
      (dolist (g groups)
        (setq line-num (decknix--tasks-render-group line-num width g)))))
  line-num)

(defun decknix-layout-chore-info (uuid)
  "Show `task info' for the chore UUID, fetched in a child process."
  (interactive (list (get-text-property (line-beginning-position) 'decknix-layout-chore)))
  (unless uuid (user-error "No chore on this row"))
  (let ((buf (get-buffer-create "*task info*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t)) (erase-buffer)))
    (make-process
     :name "decknix-task-info" :buffer buf :noquery t
     :command (list "task" "rc.gc=off" "rc.hooks=off" "rc.verbose=nothing" uuid "info")
     :sentinel (lambda (proc _event)
                 (when (memq (process-status proc) '(exit signal))
                   (with-current-buffer (process-buffer proc)
                     (special-mode)
                     (goto-char (point-min)))
                   (display-buffer (process-buffer proc)))))))

(provide 'decknix-sidebar-tasks)
;;; decknix-sidebar-tasks.el ends here
