;;; decknix-test-helpers.el --- Shared helpers for decknix ERT suites -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; Test helpers shared across the decknix ERT characterisation suites.
;; Provides macros for binding hub state, isolating the progress
;; persistence directory to a tmp path, and building fixture data.
;;
;; Loaded at the top of every `decknix-*-test.el' file.

;;; Code:

(require 'cl-lib)
(require 'json)

;; Test-side declarations for the hub data layer's free variables.
;; In `decknix-progress.el' these appear as `(defvar X)' without an
;; initializer — that is purely a byte-compiler hint and does NOT
;; mark the symbol globally special, so a plain `let' over the same
;; name in a `lexical-binding: t' test file would bind lexically and
;; the byte-compiled `varref' inside the function under test would
;; raise `void-variable'.  Giving the helpers' defvar a nil initializer
;; sets `declared-special = t' globally, so test-side `let' bindings
;; reach the function dynamically the way they would in a running
;; daemon.  The progress dir / cache vars are always set inside the
;; tmp-dir macro, so a no-init declaration is sufficient there.
(defvar decknix--hub-wip nil)
(defvar decknix--hub-jira-tasks nil)
(defvar decknix-progress--dir)
(defvar decknix-progress--index-cache)
(defvar decknix-progress--todo-cache)

(defmacro decknix-test-with-tmp-progress-dir (&rest body)
  "Run BODY with `decknix-progress--dir' bound to a fresh tmp directory.
The tmp directory is created before BODY runs and removed afterwards.
Also clears any cached index parse so each test starts cold."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "decknix-progress-" t))
          (decknix-progress--dir (file-name-as-directory tmp))
          (decknix-progress--index-cache nil))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p tmp)
         (delete-directory tmp t)))))

(defmacro decknix-test-with-hub-data (wip jira &rest body)
  "Bind `decknix--hub-wip' to WIP and `decknix--hub-jira-tasks' to JIRA in BODY."
  (declare (indent 2))
  `(let ((decknix--hub-wip ,wip)
         (decknix--hub-jira-tasks ,jira))
     ,@body))

(defun decknix-test-make-pr (&rest props)
  "Build a hub WipPr-shaped alist from PROPS (a plist).
Defaults: state=open, draft=nil, ci=pass, mergeable=mergeable.
Pass :ci-status to override the inner ci alist."
  (let* ((number (or (plist-get props :number) 1))
         (title (or (plist-get props :title) "Example PR"))
         (state (or (plist-get props :state) "open"))
         (draft (plist-get props :draft))
         (merged-at (plist-get props :merged-at))
         (mergeable (or (plist-get props :mergeable) "mergeable"))
         (review-decision (plist-get props :review-decision))
         (needs-reply (plist-get props :needs-reply))
         (bot-pending (plist-get props :bot-pending))
         (replies-to-me (plist-get props :replies-to-me))
         (ci-status (or (plist-get props :ci-status) "pass"))
         (url (or (plist-get props :url)
                  (format "https://github.com/o/r/pull/%s" number))))
    `((number . ,number)
      (title . ,title)
      (url . ,url)
      (state . ,state)
      (draft . ,draft)
      (merged_at . ,merged-at)
      (mergeable . ,mergeable)
      (review_decision . ,review-decision)
      (needs_reply . ,needs-reply)
      (bot_pending . ,bot-pending)
      (replies_to_me . ,replies-to-me)
      (ci . ((status . ,ci-status))))))

(defun decknix-test-make-hub-wip (repo-prs)
  "Build a `decknix--hub-wip'-shaped alist from REPO-PRS.
REPO-PRS is a list of (REPO . PR-LIST) cons cells."
  `((repos . ,(mapcar (lambda (rp)
                        `((repo . ,(car rp))
                          (prs . ,(cdr rp))))
                      repo-prs))))

(defun decknix-test-make-jira-task (&rest props)
  "Build a hub JiraTask-shaped alist from PROPS (plist)."
  (let ((status (or (plist-get props :status) "To Do"))
        (cat (or (plist-get props :status-category) "new"))
        (links (plist-get props :links))
        (key (or (plist-get props :key) "TEST-1"))
        (summary (or (plist-get props :summary) "Example task")))
    `((key . ,key)
      (summary . ,summary)
      (status . ,status)
      (status_category . ,cat)
      (links . ,links))))

(defun decknix-test-read-json-file (path)
  "Read PATH as JSON and return the parsed hash table."
  (with-temp-buffer
    (insert-file-contents path)
    (json-parse-buffer
     :object-type 'hash-table
     :array-type 'list
     :null-object nil
     :false-object nil)))

(provide 'decknix-test-helpers)
;;; decknix-test-helpers.el ends here
