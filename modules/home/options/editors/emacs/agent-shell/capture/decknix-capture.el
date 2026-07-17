;;; decknix-capture.el --- Quick capture of issues / tasks -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: decknix, capture, github, jira, taskwarrior, workflow

;;; Commentary:
;;
;; Quick-capture: jot a feature / bug / investigation / discussion into a
;; GitHub issue (or a comment on an existing one) or taskwarrior, without
;; leaving Emacs or waiting on a busy agent -- so work can be queued the
;; instant you think of it and picked up by an agent later.
;;
;; Tool-agnostic: plain Emacs + the `gh' and `task' CLIs, tied to no AI
;; agent.  Hexagonal: destinations are a pluggable alist of adapters
;; (`decknix-capture-destinations'); GitHub + taskwarrior are the core
;; adapters shipped here, and an org config (e.g. nurturecloud) can add
;; more -- Jira CONN task/subtask -- without touching this core (v1
;; ships GitHub issue + comment + taskwarrior; Jira is a later adapter).
;;
;; Submission is asynchronous (`make-process'): the picker returns
;; immediately and a message reports success/URL when the CLI finishes,
;; so capturing never blocks the editor even mid-agent-run.
;;
;; The command construction and hub-repo extraction are pure functions,
;; carved for ERT; the interactive prompts + process orchestration stay
;; in the command per AGENTS.md Rule 2.

;;; Code:

(defgroup decknix-capture nil
  "Quick capture of issues and tasks."
  :group 'decknix)

(defcustom decknix-capture-default-repo nil
  "Default owner/repo for GitHub captures, or nil to always prompt.
An org / workspace config may set this (e.g. per `default-directory')."
  :type '(choice (const :tag "Always prompt" nil) (string :tag "owner/repo"))
  :group 'decknix-capture)

(defconst decknix-capture-types
  '(("feature"       . "enhancement")
    ("bug"           . "bug")
    ("investigation" . "investigation")
    ("discussion"    . "discussion"))
  "Capture type -> GitHub issue label.")

;; Provided by the hub layer (parsed github-reviews.json / github-wip.json);
;; forward-declared so this module needs no hard dependency on the hub.
(defvar decknix--hub-reviews)
(defvar decknix--hub-wip)

;; -- Pure helpers (ERT-tested) --------------------------------------

(defun decknix--capture-type-label (type)
  "Return the GitHub issue label for capture TYPE, or nil when unknown."
  (cdr (assoc type decknix-capture-types)))

(defun decknix--capture-repos-from-hub (reviews wip)
  "Return sorted, de-duplicated owner/repo strings from hub data.
REVIEWS and WIP are the parsed `github-reviews.json' / `github-wip.json'
alists; missing/!alist inputs yield an empty list rather than erroring."
  (let ((repos nil))
    (when (listp reviews)
      (dolist (item (alist-get 'items reviews))
        (let ((r (and (listp item) (alist-get 'repo item))))
          (when (and (stringp r) (not (string-empty-p r))) (push r repos)))))
    (when (listp wip)
      (dolist (repo-entry (alist-get 'repos wip))
        (let ((r (and (listp repo-entry) (alist-get 'repo repo-entry))))
          (when (and (stringp r) (not (string-empty-p r))) (push r repos)))))
    (sort (delete-dups repos) #'string<)))

(defun decknix--capture-gh-issue-args (repo title body label)
  "Build the `gh issue create' argument list.
LABEL is added only when non-empty; BODY defaults to an empty string."
  (append (list "issue" "create" "-R" repo "-t" title "-b" (or body ""))
          (when (and label (stringp label) (not (string-empty-p label)))
            (list "-l" label))))

(defun decknix--capture-gh-comment-args (repo number body)
  "Build the `gh issue comment' argument list for issue/PR NUMBER."
  (list "issue" "comment" (number-to-string number) "-R" repo "-b" (or body "")))

(defun decknix--capture-task-args (title project tags)
  "Build the `task add' argument list.
PROJECT (when non-empty) becomes `project:PROJECT'; each of TAGS becomes
`+TAG'."
  (append (list "add" title)
          (when (and (stringp project) (not (string-empty-p project)))
            (list (concat "project:" project)))
          (mapcar (lambda (tg) (concat "+" tg))
                  (seq-filter (lambda (tg) (not (string-empty-p tg))) tags))))

;; -- Orchestration --------------------------------------------------

(defun decknix--capture-known-repos ()
  "Return known owner/repo candidates (hub data plus the default)."
  (delete-dups
   (append (when (and decknix-capture-default-repo
                      (not (string-empty-p decknix-capture-default-repo)))
             (list decknix-capture-default-repo))
           (ignore-errors
             (decknix--capture-repos-from-hub
              (bound-and-true-p decknix--hub-reviews)
              (bound-and-true-p decknix--hub-wip))))))

(defun decknix--capture-run-async (program args label)
  "Run PROGRAM with ARGS asynchronously; report via a message tagged LABEL.
Never blocks: the picker has already returned by the time this fires."
  (let ((buf (generate-new-buffer " *decknix-capture*")))
    (make-process
     :name "decknix-capture"
     :buffer buf
     :command (cons program args)
     :connection-type 'pipe
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((out (with-current-buffer buf (string-trim (buffer-string))))
               (ok (= 0 (process-exit-status proc))))
           (kill-buffer buf)
           (if ok
               (message "decknix capture (%s): %s" label
                        (if (string-empty-p out) "done" out))
             (message "decknix capture (%s) FAILED: %s" label out))))))))

;;;###autoload
(defun decknix-capture (&optional with-body)
  "Quick-capture an item to GitHub or taskwarrior.
Prompts for a destination, target and one-line title, then submits
asynchronously.  With prefix arg WITH-BODY, also prompt for a body.
Works while an agent is busy -- nothing here blocks on the agent."
  (interactive "P")
  (pcase (completing-read
          "Capture to: "
          '("GitHub issue" "GitHub comment" "Task (taskwarrior)")
          nil t nil nil "GitHub issue")
    ("GitHub issue"
     (let* ((repo (completing-read "Repo (owner/repo): " (decknix--capture-known-repos)
                                   nil nil decknix-capture-default-repo))
            (type (completing-read "Type: " (mapcar #'car decknix-capture-types)
                                   nil t nil nil "feature"))
            (title (read-string (format "%s: " (capitalize type))))
            (body (when with-body (read-string "Body (optional): "))))
       (when (string-empty-p (string-trim title)) (user-error "Empty title"))
       (decknix--capture-run-async
        "gh" (decknix--capture-gh-issue-args
              repo (string-trim title) body (decknix--capture-type-label type))
        (format "%s issue" repo))))
    ("GitHub comment"
     (let* ((repo (completing-read "Repo (owner/repo): " (decknix--capture-known-repos)
                                   nil nil decknix-capture-default-repo))
            (number (read-number "Issue/PR number: "))
            (body (read-string "Comment: ")))
       (when (string-empty-p (string-trim body)) (user-error "Empty comment"))
       (decknix--capture-run-async
        "gh" (decknix--capture-gh-comment-args repo number (string-trim body))
        (format "%s#%d comment" repo number))))
    ("Task (taskwarrior)"
     (let* ((title (read-string "Task: "))
            (project (read-string "Project (blank = none): "))
            (tags (split-string (read-string "Tags (space-separated, blank = none): ")
                                "[ \t]+" t)))
       (when (string-empty-p (string-trim title)) (user-error "Empty task"))
       (decknix--capture-run-async
        "task" (decknix--capture-task-args (string-trim title) project tags)
        "taskwarrior")))))

(provide 'decknix-capture)
;;; decknix-capture.el ends here
