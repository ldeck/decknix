;;; decknix-review-clone.el --- Clone a PR's repository on demand -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, decknix, review, git, clone

;;; Commentary:
;;
;; A review request for a repository with no local checkout used to be
;; dropped silently: the auto-review dispatcher found no workspace, did
;; nothing, and the PR sat in the board's Idle lane looking like work
;; nobody had noticed.  When the PR's org maps to a workspace (see
;; `decknix-workspace-orgs'), this clones the repository there first and
;; hands the review on once the clone is on disk.
;;
;; Every clone runs in a child process (`make-process' plus a sentinel),
;; never on the main thread: a clone is network-bound and can take
;; minutes.  Clones for one repository are coalesced (later callers wait
;; on the first), concurrent clones are capped, and a clone that turns
;; up meanwhile is reused rather than cloned over.
;;
;; The per-repository state (queued, cloning, failed, unmapped) is what
;; the board shows on the row instead of a bare "no session", so a clone
;; in flight or one that failed (no access, offline) is visible.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'decknix-workspace-orgs)

(declare-function decknix--agent-pr-detect-workspace
                  "decknix-agent-workspace-detect" (owner repo))
(declare-function decknix-hub-worktree-clones "decknix-agent-shell-hub")
(declare-function decknix-hub-worktree-clones-cache-invalidate "decknix-agent-shell-hub")

(defcustom decknix-review-clone-max-concurrent 2
  "How many on-demand clones may run at once; the rest queue."
  :type 'integer
  :group 'decknix-workspaces)

(defcustom decknix-review-clone-program "gh"
  "Program that clones: `gh' (uses its auth and protocol) or `git'."
  :type '(choice (const "gh") (const "git") string)
  :group 'decknix-workspaces)

(defvar decknix-review-clone-start-function #'decknix-review-clone--start-process
  "Function (KEY COMMAND) that starts a clone child process.
It must arrange for `decknix-review-clone--finish' to be called with KEY,
success and output when the child exits.  Replaced in tests.")

(defvar decknix-review-clone-state-change-hook nil
  "Run with no arguments whenever a repository's clone state changes.")

(defvar decknix-review-clone--states (make-hash-table :test 'equal)
  "KEY -> plist (:state STATE :target PATH :error TEXT :org OWNER).
KEY is the lowercased `owner/repo'.  STATE is `queued', `cloning',
`failed' or `unmapped'; a finished clone drops its entry.")

(defvar decknix-review-clone--waiters (make-hash-table :test 'equal)
  "KEY -> callbacks waiting on that repository's clone.")

(defvar decknix-review-clone--queue nil
  "Pending (KEY TARGET COMMAND) clones, oldest first.")

(defvar decknix-review-clone--running 0
  "Number of clone children currently running.")

(defvar decknix-review-clone--primaries (make-hash-table :test 'equal)
  "KEY -> path of a repository cloned this session.
Consulted before the hub's clone discovery, which only notices a new
clone on its next asynchronous scan.")

(defun decknix-review-clone-key (owner repo)
  "Return the state key for OWNER/REPO."
  (downcase (format "%s/%s" owner repo)))

(defun decknix-review-clone-state (owner repo)
  "Return the clone state plist for OWNER/REPO, or nil."
  (gethash (decknix-review-clone-key owner repo) decknix-review-clone--states))

(defun decknix-review-clone--set-state (key plist)
  "Set KEY's state to PLIST (nil clears it) and announce the change."
  (if plist
      (puthash key plist decknix-review-clone--states)
    (remhash key decknix-review-clone--states))
  (with-demoted-errors "[review-clone] state hook: %S"
    (run-hooks 'decknix-review-clone-state-change-hook)))

(defun decknix-review-clone-mark-unmapped (owner repo)
  "Record that OWNER/REPO has no checkout and no workspace.
Returns non-nil the first time, so a caller can announce it once."
  (let ((key (decknix-review-clone-key owner repo)))
    (unless (eq (plist-get (gethash key decknix-review-clone--states) :state)
                'unmapped)
      (decknix-review-clone--set-state key (list :state 'unmapped :org owner))
      t)))

(defun decknix-review-clone-clear (owner repo)
  "Forget OWNER/REPO's failed or unmapped state, e.g. before a retry."
  (let ((key (decknix-review-clone-key owner repo)))
    (when (memq (plist-get (gethash key decknix-review-clone--states) :state)
                '(failed unmapped))
      (decknix-review-clone--set-state key nil))))

(defun decknix-review-clone-known-primary (owner repo)
  "Return a checkout of OWNER/REPO cloned this session, or nil."
  (gethash (decknix-review-clone-key owner repo) decknix-review-clone--primaries))

(defun decknix-review-clone-command (owner repo target &optional args)
  "Return the argv cloning OWNER/REPO into TARGET with extra git ARGS."
  (let ((target (expand-file-name target)))
    (if (equal (file-name-nondirectory decknix-review-clone-program) "git")
        (append (list decknix-review-clone-program "clone")
                args
                (list (format "https://github.com/%s/%s.git" owner repo) target))
      (append (list decknix-review-clone-program "repo" "clone"
                    (format "%s/%s" owner repo) target)
              (when args (cons "--" args))))))

(defun decknix-review-clone--error-text (output)
  "Return the last non-empty line of OUTPUT, the part worth showing."
  (or (car (last (split-string (or output "") "\n" t "[ \t\r]+")))
      "clone failed"))

(defun decknix-review-clone--start-process (key command)
  "Start COMMAND for KEY as a child process; finish from its sentinel."
  (let ((buf (generate-new-buffer (format " *review-clone %s*" key))))
    (condition-case err
        (make-process
         :name (format "review-clone-%s" key)
         :buffer buf
         :command command
         :connection-type 'pipe
         :noquery t
         :sentinel
         (lambda (proc _event)
           (when (memq (process-status proc) '(exit signal))
             (let ((out (when (buffer-live-p buf)
                          (with-current-buffer buf (buffer-string)))))
               (when (buffer-live-p buf) (kill-buffer buf))
               (decknix-review-clone--finish
                key (and (eq (process-status proc) 'exit)
                         (zerop (process-exit-status proc)))
                out)))))
      (error
       (when (buffer-live-p buf) (kill-buffer buf))
       (decknix-review-clone--finish key nil (error-message-string err))))))

(defun decknix-review-clone--pump ()
  "Start queued clones up to `decknix-review-clone-max-concurrent'."
  (while (and decknix-review-clone--queue
              (< decknix-review-clone--running
                 (max 1 decknix-review-clone-max-concurrent)))
    (cl-destructuring-bind (key target command) (pop decknix-review-clone--queue)
      (if (file-directory-p target)
          (decknix-review-clone--deliver key t target)
        (cl-incf decknix-review-clone--running)
        (decknix-review-clone--set-state
         key (list :state 'cloning :target target))
        (ignore-errors (make-directory (file-name-directory
                                        (directory-file-name target))
                                       t))
        (funcall decknix-review-clone-start-function key command)))))

(defun decknix-review-clone--deliver (key ok value)
  "Record KEY's outcome and call its waiters with OK and VALUE.
VALUE is the checkout path on success and the error text on failure."
  (let ((waiters (nreverse (gethash key decknix-review-clone--waiters))))
    (remhash key decknix-review-clone--waiters)
    (if ok
        (progn
          (puthash key value decknix-review-clone--primaries)
          (when (fboundp 'decknix-hub-worktree-clones-cache-invalidate)
            (ignore-errors (decknix-hub-worktree-clones-cache-invalidate)))
          (decknix-review-clone--set-state key nil))
      (decknix-review-clone--set-state
       key (list :state 'failed :error value
                 :target (plist-get (gethash key decknix-review-clone--states)
                                    :target))))
    (dolist (cb waiters)
      (condition-case err
          (funcall cb ok value)
        (error (message "[review-clone] %s: callback failed: %s"
                        key (error-message-string err)))))))

(defun decknix-review-clone--finish (key ok output)
  "Handle the exit of KEY's clone child: OK, with its OUTPUT."
  (setq decknix-review-clone--running (max 0 (1- decknix-review-clone--running)))
  (let ((target (plist-get (gethash key decknix-review-clone--states) :target)))
    (if ok
        (progn
          (message "[review-clone] cloned %s into %s" key target)
          (decknix-review-clone--deliver key t target))
      (let ((text (decknix-review-clone--error-text output)))
        (message "[review-clone] clone of %s failed: %s" key text)
        (decknix-review-clone--deliver key nil text))))
  (decknix-review-clone--pump))

(defun decknix-review-clone-ensure (owner repo target callback &optional args)
  "Make sure OWNER/REPO is cloned at TARGET, then call CALLBACK.

CALLBACK receives (OK VALUE): VALUE is the checkout on success, the error
text on failure.  An existing TARGET is reused at once.  A clone of the
same repository already queued or running gains CALLBACK as a waiter, so
two dispatches for one repository clone it once.  ARGS are extra `git
clone' arguments (see `decknix-workspace-clone-args').

Returns immediately; the clone runs in a child process."
  (let ((key (decknix-review-clone-key owner repo))
        (target (directory-file-name (expand-file-name target))))
    (cond
     ((file-directory-p target)
      (puthash key target decknix-review-clone--primaries)
      (funcall callback t target))
     ((memq (plist-get (gethash key decknix-review-clone--states) :state)
            '(queued cloning))
      (push callback (gethash key decknix-review-clone--waiters)))
     (t
      (push callback (gethash key decknix-review-clone--waiters))
      (decknix-review-clone--set-state key (list :state 'queued :target target))
      (setq decknix-review-clone--queue
            (append decknix-review-clone--queue
                    (list (list key target
                                (decknix-review-clone-command
                                 owner repo target args)))))
      (decknix-review-clone--pump)))
    nil))

;; -- Resolution for live callers ------------------------------------

(defun decknix-review-clone--primary-from-hub (owner repo)
  "Return a known primary clone of OWNER/REPO, without spawning a probe.
Reads this session's clones first, then the hub's memoised discovery."
  (or (decknix-review-clone-known-primary owner repo)
      (when (fboundp 'decknix-hub-worktree-clones)
        (cdr (assoc (decknix-review-clone-key owner repo)
                    (ignore-errors (decknix-hub-worktree-clones)))))))

(defun decknix-review-clone-resolve (owner repo)
  "Resolve where a review of OWNER/REPO runs, from live state.
See `decknix-workspace-resolve'.  No subprocess is started."
  (decknix-workspace-resolve
   owner repo
   (when (fboundp 'decknix--agent-pr-detect-workspace)
     (lambda (o r) (ignore-errors (decknix--agent-pr-detect-workspace o r))))
   #'decknix-review-clone--primary-from-hub))

(defvar decknix-review-clone--resolve-memo (make-hash-table :test 'equal)
  "KEY -> (TIME . RESOLUTION), for the board's per-row note.")

(defconst decknix-review-clone-resolve-ttl 30
  "Seconds a memoised resolution answers a row note.")

(defun decknix-review-clone-resolve-cached (owner repo)
  "Like `decknix-review-clone-resolve', memoised for the board's rows.
Rendering a row must not walk the session store per repository on every
repaint; a resolution half a minute old is good enough to label a row."
  (let* ((key (decknix-review-clone-key owner repo))
         (hit (gethash key decknix-review-clone--resolve-memo)))
    (if (and hit (< (- (float-time) (car hit)) decknix-review-clone-resolve-ttl))
        (cdr hit)
      (let ((res (decknix-review-clone-resolve owner repo)))
        (puthash key (cons (float-time) res) decknix-review-clone--resolve-memo)
        res))))

(defun decknix-review-clone-row-note (state &optional resolution)
  "Return the row text for a clone STATE plist, or RESOLUTION, or nil.  Pure.
STATE wins: a clone in flight or failed says so.  Otherwise RESOLUTION
names an unmapped org, or a mapped repository not cloned yet."
  (pcase (plist-get state :state)
    ('queued "clone queued...")
    ('cloning "cloning...")
    ('failed (format "clone failed: %s" (or (plist-get state :error) "?")))
    ('unmapped (decknix-workspace-unmapped-message (plist-get state :org)))
    (_ (pcase (plist-get resolution :kind)
         ('unmapped (decknix-workspace-unmapped-message
                     (plist-get resolution :org)))
         ('clone (format "not cloned: d clones into %s"
                         (abbreviate-file-name
                          (directory-file-name (plist-get resolution :workspace)))))))))

(provide 'decknix-review-clone)
;;; decknix-review-clone.el ends here
