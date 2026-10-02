;;; decknix-repo-sync-actions.el --- Repo-sync cache and remedies -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-repo-sync "0.1"))
;; Keywords: agent, hub, git, repo

;;; Commentary:
;;
;; Side-effecting half of `decknix-repo-sync': an async cache of the report
;; and the remedies offered per problem row.
;;
;; Every remedy runs ASYNCHRONOUSLY.  `decknix repos sync' takes tens of
;; seconds across 60 clones with the network in the loop, and blocking the
;; sidebar on it would be the same mistake the synchronous `wt audit' made.
;;
;; Clearing a lock goes through `decknix repos fix-lock', which refuses unless
;; the lock is both older than its threshold AND held by no process.  The
;; refusal is reported verbatim rather than retried harder: deleting a live
;; lock corrupts the index of whatever holds it, and a sibling agent working
;; in the same repo is the normal case here, not the exotic one.

;;; Code:

(require 'decknix-repo-sync)

(defvar decknix--repo-sync-cache nil
  "Parsed report plist (:updated :problems), or nil before the first read.")

(defvar decknix--repo-sync-read-pending nil
  "Non-nil while a report read is in flight.")

(defun decknix-repo-sync-problems ()
  "Return the cached, visible repo-sync problems."
  (seq-filter #'decknix--repo-sync-visible-p
              (plist-get decknix--repo-sync-cache :problems)))

(defun decknix-repo-sync-summary ()
  "Return a one-line summary of cached problems, or nil."
  (decknix--repo-sync-summary (decknix-repo-sync-problems)))

(defun decknix-repo-sync-report-stale-p ()
  "Return non-nil when the cached report is overdue."
  (decknix--repo-sync-stale-report-p
   (plist-get decknix--repo-sync-cache :updated) (float-time)))

(defun decknix-repo-sync-refresh (&optional on-done)
  "Re-read the report file into the cache, then call ON-DONE.

Reading is cheap (a small JSON file) but still done off the render path via
`run-at-time' so a paint never touches the filesystem."
  (unless decknix--repo-sync-read-pending
    (setq decknix--repo-sync-read-pending t)
    (run-at-time
     0 nil
     (lambda ()
       (unwind-protect
           (when (file-readable-p decknix-repo-sync-report)
             (let ((parsed (decknix--repo-sync-parse
                            (with-temp-buffer
                              (insert-file-contents decknix-repo-sync-report)
                              (buffer-string)))))
               ;; Keep the previous cache when the read fails: replacing it
               ;; with nil would render as "no problems".
               (when parsed (setq decknix--repo-sync-cache parsed))))
         (setq decknix--repo-sync-read-pending nil)
         (when on-done (funcall on-done)))))))

(defun decknix-repo-sync-toggle-show-behind ()
  "Toggle whether repos merely falling behind are listed.

Off leaves only the failures -- a stale lock or a broken fetch.  On adds
the dirty and diverged checkouts, which are a backlog rather than a fault
but were drifting 36 to 102 commits behind unreported."
  (interactive)
  (setq decknix-repo-sync-show-behind (not decknix-repo-sync-show-behind))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Repos: behind/dirty rows %s"
           (if decknix-repo-sync-show-behind "shown" "hidden")))

(defun decknix--repo-sync-run (args name on-done)
  "Run `decknix ARGS' asynchronously under NAME, calling ON-DONE with output."
  (let ((buffer (generate-new-buffer (format " *%s*" name))))
    (make-process
     :name name
     :buffer buffer
     :noquery t
     :command (cons "decknix" args)
     :sentinel
     (lambda (_proc event)
       (when (string-match-p "\\`\\(finished\\|exited\\|deleted\\|failed\\)" event)
         (let ((output (when (buffer-live-p buffer)
                         (with-current-buffer buffer (buffer-string)))))
           (when (buffer-live-p buffer) (kill-buffer buffer))
           (funcall on-done (or output ""))))))))

(defun decknix-repo-sync-clear-lock (problem &optional on-done)
  "Ask `decknix repos fix-lock' to clear PROBLEM's abandoned index.lock.

Reports the CLI's own refusal reason when it declines, rather than
paraphrasing it: the whole value of the guard is that the user can see WHY
a lock was left alone."
  (let ((path (plist-get problem :path))
        (name (plist-get problem :name)))
    (unless path (user-error "No path recorded for this repo"))
    (message "Clearing lock in %s..." name)
    (decknix--repo-sync-run
     (list "repos" "fix-lock" path "--json")
     "decknix-fix-lock"
     (lambda (output)
       (let* ((res (ignore-errors
                     (json-parse-string output :object-type 'alist
                                        :false-object nil :null-object nil)))
              (removed (and res (alist-get 'removed res)))
              (reason (or (and res (alist-get 'reason res)) (string-trim output))))
         (if removed
             (progn
               (message "%s: lock cleared (%s) -- re-syncing" name reason)
               (decknix-repo-sync-retry problem on-done))
           (message "%s: lock left alone -- %s" name reason)
           (when on-done (funcall on-done))))))))

(defun decknix--repo-sync-run-git (path args name on-done)
  "Run git ARGS in PATH asynchronously under NAME, calling ON-DONE with output."
  (let ((buffer (generate-new-buffer (format " *%s*" name))))
    (make-process
     :name name
     :buffer buffer
     :noquery t
     :command (append (list "git" "-C" (expand-file-name path)) args)
     :sentinel
     (lambda (proc event)
       (when (string-match-p "\\`\\(finished\\|exited\\|deleted\\|failed\\)" event)
         (let ((output (when (buffer-live-p buffer)
                         (with-current-buffer buffer (buffer-string))))
               (ok (and (eq (process-status proc) 'exit)
                        (= 0 (process-exit-status proc)))))
           (when (buffer-live-p buffer) (kill-buffer buffer))
           (funcall on-done ok (or output ""))))))))

(defun decknix-repo-sync-stash (problem &optional on-done)
  "Stash PROBLEM\='s uncommitted work, then re-sync the repo.

`stash push\=' rather than `reset --hard\=': this is the only remedy for a
dirty repo that is RECOVERABLE.  The work lands on the stash list and
`git stash pop\=' brings it back, so a wrong keystroke here costs a lookup
rather than the work itself.  `-u\=' includes untracked files, since those
are what most often block a checkout and the most painful to lose.

Nothing else offers to clear a dirty tree, which is why this exists: the
sweep refuses to fast-forward a dirty repo, so without a way to clear it
the repo stays behind indefinitely."
  (let ((path (plist-get problem :path))
        (name (plist-get problem :name)))
    (unless path (user-error "No path recorded for this repo"))
    (message "Stashing %s..." name)
    (decknix--repo-sync-run-git
     path (list "stash" "push" "-u" "-m" "decknix: stashed before sync")
     "decknix-repo-stash"
     (lambda (ok output)
       (if (not ok)
           (progn
             (message "%s: stash failed -- %s" name
                      (string-trim (or output "")))
             (when on-done (funcall on-done)))
         (message "%s: stashed (git stash pop to restore) -- re-syncing" name)
         (decknix-repo-sync-retry problem on-done))))))

(defun decknix-repo-sync-reset-hard (problem &optional on-done)
  "Discard PROBLEM\='s uncommitted work, hard-resetting to its origin branch.

DESTRUCTIVE and not recoverable: unlike `decknix-repo-sync-stash\=', the
work is gone.  Offered because a primary checkout is not a workspace --
work belongs in a worktree -- so uncommitted changes there are usually
debris rather than anything wanted, and stashing them just moves the
debris onto the stash list.

Resets to `origin/BRANCH\=' rather than HEAD, because the point is to make
the checkout match origin: a reset to HEAD would leave it still behind.
`clean -fd\=' follows, since reset alone leaves untracked files, which is
exactly what blocks the next checkout."
  (let* ((path (plist-get problem :path))
         (name (plist-get problem :name))
         (branch (plist-get problem :branch)))
    (unless path (user-error "No path recorded for this repo"))
    (unless (and branch (not (string-empty-p branch)))
      (user-error "No default branch recorded for %s -- refusing to reset" name))
    (message "Resetting %s to origin/%s..." name branch)
    (decknix--repo-sync-run-git
     path (list "reset" "--hard" (concat "origin/" branch))
     "decknix-repo-reset"
     (lambda (ok output)
       (if (not ok)
           (progn
             (message "%s: reset failed -- %s" name (string-trim (or output "")))
             (when on-done (funcall on-done)))
         (decknix--repo-sync-run-git
          path (list "clean" "-fd")
          "decknix-repo-clean"
          (lambda (_ok2 _out2)
            (message "%s: reset to origin/%s -- re-syncing" name branch)
            (decknix-repo-sync-retry problem on-done))))))))

(defun decknix-repo-sync-retry (problem &optional on-done)
  "Re-run the sweep for PROBLEM's repo only.

Scoped with `--only' so a fix is verified in seconds instead of waiting up
to the launchd interval, and so a single-repo retry cannot overwrite the
full report with one row."
  (let ((name (plist-get problem :name)))
    (message "Syncing %s..." name)
    (decknix--repo-sync-run
     (list "repos" "sync" "--only" name)
     "decknix-repo-sync-retry"
     (lambda (output)
       (message "%s: %s" name
                (or (car (last (seq-filter
                                (lambda (l) (string-match-p "[A-Za-z]" l))
                                (split-string (string-trim output) "\n" t))))
                    "done"))
       ;; The scoped retry deliberately does not write the report, so refresh
       ;; the full sweep's view rather than leaving a fixed row on screen.
       (decknix-repo-sync-refresh on-done)))))

(defun decknix-repo-sync-resweep (&optional on-done)
  "Run the whole sweep now, rather than waiting for the launchd interval."
  (interactive)
  (message "decknix repos sync: running...")
  (decknix--repo-sync-run
   (list "repos" "sync")
   "decknix-repo-sync-all"
   (lambda (output)
     (message "repo sync: %s"
              (or (car (last (seq-filter
                              (lambda (l) (string-match-p "repos:" l))
                              (split-string output "\n" t))))
                  "done"))
     (decknix-repo-sync-refresh on-done))))

(defun decknix-repo-sync-visit (problem)
  "Open PROBLEM's repo: magit when available, dired otherwise."
  (let ((path (plist-get problem :path)))
    (unless (and path (file-directory-p path))
      (user-error "Repo path is not available: %s" (or path "nil")))
    (if (fboundp 'magit-status)
        (magit-status path)
      (dired path))))


;; --- sidebar rendering and the row action -----------------------------

(declare-function decknix--sidebar-render-section-header
                  "decknix-sidebar-format" (title &optional section-id))

(defface decknix-repo-sync-lock-face
  '((t :inherit warning))
  "Face for a repo blocked by an abandoned lock."
  :group 'decknix)

(defface decknix-repo-sync-failed-face
  '((t :inherit error))
  "Face for a repo whose sync failed for a reason needing a human."
  :group 'decknix)

(defun decknix--repo-sync-face (kind)
  "Return the face for problem KIND."
  (pcase kind
    ('lock 'decknix-repo-sync-lock-face)
    ('failed 'decknix-repo-sync-failed-face)
    (_ 'font-lock-comment-face)))

(defvar decknix--repo-sync-failed-expanded)

(defun decknix--repo-sync-render (line-num)
  "Render the repo-sync problem section.  Returns the updated LINE-NUM.

Kicks off a cache refresh when the report has aged out, so the section is
never rendered from the filesystem on the paint path."
  (when (decknix-repo-sync-report-stale-p)
    (decknix-repo-sync-refresh))
  (let* ((all (decknix-repo-sync-problems))
         (split (decknix--repo-sync-collapse
                 all decknix-repo-sync-collapse-failed
                 decknix--repo-sync-failed-expanded))
         (problems (car split))
         (collapsed (cdr split)))
    (when all
      (insert "\n")
      (setq line-num (1+ line-num))
      (decknix--sidebar-render-section-header
       (format "Repos (%s)" (decknix-repo-sync-summary))
       'repos)
      (setq line-num (1+ line-num))
      (dolist (problem problems)
        (let ((line (concat "  " (decknix--repo-sync-row-label problem))))
          (insert (propertize line
                              'face (decknix--repo-sync-face
                                     (plist-get problem :kind))
                              'decknix-repo-sync-problem problem
                              'help-echo (or (plist-get problem :detail) ""))
                  "\n")
          (setq line-num (1+ line-num))))
      (when collapsed
        (insert (propertize
                 (concat "  " (decknix--repo-sync-collapsed-label collapsed))
                 'face (decknix--repo-sync-face 'failed)
                 'decknix-repo-sync-collapsed collapsed
                 'help-echo "RET to expand these repos")
                "\n")
        (setq line-num (1+ line-num)))))
  line-num)

(defvar decknix--repo-sync-failed-expanded nil
  "Non-nil when the collapsed `failed' rows are shown individually.")

(defun decknix-repo-sync-toggle-failed-expanded ()
  "Show or re-collapse the individual `failed' repo rows."
  (interactive)
  (setq decknix--repo-sync-failed-expanded
        (not decknix--repo-sync-failed-expanded))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (ignore-errors (agent-shell-workspace-sidebar-refresh)))
  (message "Sync failures: %s"
           (if decknix--repo-sync-failed-expanded "expanded" "collapsed")))

(defun decknix-repo-sync-problem-at-point ()
  "Return the repo-sync problem on the current row, or nil."
  (get-text-property (line-beginning-position) 'decknix-repo-sync-problem))

(defconst decknix--repo-sync-action-prompts
  '((lock . "%s: [c]lear stale lock  [r]etry sync  [v]isit repo  [q]uit ")
    (dirty . "%s: [s]tash  [H]ard-reset (DESTROYS work)  [v]isit  [r]etry  [q]uit ")
    (diverged . "%s: [v]isit repo (push or rebase)  [r]etry sync  [q]uit ")
    (failed . "%s: [v]isit repo  [r]etry sync  [q]uit "))
  "Per-kind action prompt.

Only `lock' offers clearing, because it is the only kind with a mechanical
remedy.  Offering it on a dirty or diverged repo would suggest deleting a
lock fixes uncommitted work, and on a `failed' row there is usually no lock
at all.")

(defun decknix-repo-sync-row-action ()
  "Offer the remedies for the repo-sync problem on this row."
  (interactive)
  (let ((problem (decknix-repo-sync-problem-at-point)))
    (unless problem
      (user-error "No repo-sync problem on this row"))
    (let* ((kind (plist-get problem :kind))
           (name (plist-get problem :name))
           (prompt (format (or (alist-get kind decknix--repo-sync-action-prompts)
                               "%s: [v]isit  [r]etry  [q]uit ")
                           name))
           (choices (pcase kind
                      ('lock '(?c ?r ?v ?q))
                      ('dirty '(?s ?H ?r ?v ?q))
                      (_ '(?r ?v ?q))))
           (refresh (lambda ()
                      (when (fboundp 'agent-shell-workspace-sidebar-refresh)
                        (ignore-errors (agent-shell-workspace-sidebar-refresh))))))
      (pcase (read-char-choice prompt choices)
        (?c (decknix-repo-sync-clear-lock problem refresh))
        (?s (decknix-repo-sync-stash problem refresh))
        (?H (if (yes-or-no-p
                 (format "DISCARD all uncommitted work in %s? Not recoverable. "
                         (plist-get problem :name)))
                (decknix-repo-sync-reset-hard problem refresh)
              (message "No action")))
        (?r (decknix-repo-sync-retry problem refresh))
        (?v (decknix-repo-sync-visit problem))
        (?q (message "No action"))))))

(provide 'decknix-repo-sync-actions)
;;; decknix-repo-sync-actions.el ends here
