;;; decknix-review-board-rereview.el --- Has a reviewed PR moved since the review? -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, pr, review, board

;;; Commentary:
;;
;; A review with feedback (nits, questions, suggestions) is often answered
;; by the author pushing to the same PR rather than raising a follow-up.
;; The review session that gave the feedback then sits in Finished, and
;; nothing says the PR it reviewed has moved on.  The same is true when
;; somebody else's feedback was what the session was waiting on.
;;
;; This decides, from the cached reviews feed alone (no fetch on the render
;; path), whether a PR has been updated since the review that matters, and
;; describes what moved: the commits since, the files, what happened to my
;; threads, whether my approval was dismissed.  It filters the pushes that
;; change nothing a reviewer cares about: a merge of the base branch, and a
;; rebase that leaves the PR's own diff identical.
;;
;; The hub writes the facts (see `ReviewProgress' in
;; pkgs/decknix-hub/src/main.rs): `head_sha', `my_review_sha',
;; `my_review_feedback', `feedback_review', `since_review' and the
;; `my_threads*' counts.  An older hub writes none of them; then the
;; `pushed_since_my_review' flag stands in, with no detail.
;;
;; The IO half (starting the re-review, refreshing the worktree,
;; delivering the prompt) is injected through the `-function' variables
;; below, so the decision of WHAT to do is testable without a session.

;;; Code:

(require 'map)
(require 'parse-time)
(require 'seq)
(require 'subr-x)

(defgroup decknix-review-board-rereview nil
  "Re-reviewing PRs the author updated after a review."
  :group 'decknix)

(defcustom decknix-review-board-auto-rereview 'notify
  "What to do when a PR is updated after a review with feedback.

nil      only show it on the board, in the Re-review lane.
`notify' also say so once per new head, and flag its session as needing
         you in the sidebar and the attention jump.  The default.
`auto'   also start the re-review: resume the review session (or start a
         new one) and ask it to review the changes since the review.  It
         still stops at the review confirmation gate; nothing is posted
         without you."
  :type '(choice (const :tag "Board only" nil)
                 (const :tag "Notify" notify)
                 (const :tag "Start the re-review" auto))
  :group 'decknix-review-board-rereview)

(defcustom decknix-review-board-rereview-ignore-base-merges t
  "When non-nil, a push that only merged the base branch is not an update."
  :type 'boolean :group 'decknix-review-board-rereview)

(defcustom decknix-review-board-rereview-ignore-rebases t
  "When non-nil, a rebase that leaves the PR's own diff identical is not an update."
  :type 'boolean :group 'decknix-review-board-rereview)

(defcustom decknix-review-board-rereview-bare-approvals nil
  "When non-nil, a push after my bare approval also counts as an update.
Off by default: an approval with nothing to address leaves nothing to
check, and GitHub's own dismissal (shown either way) covers a push that
voids it."
  :type 'boolean :group 'decknix-review-board-rereview)

(defconst decknix-review-board-rereview-feedback-states
  '("CHANGES_REQUESTED" "COMMENTED")
  "My review states that always carry feedback, for hubs without
`my_review_feedback'.")

;; ── detection ───────────────────────────────────────────────────────

(defun decknix-review-board-rereview--commits (since)
  "Return SINCE's commits as plists (:sha :headline :author :merge)."
  (mapcar (lambda (c)
            (list :sha (map-elt c 'sha)
                  :headline (or (map-elt c 'headline) "")
                  :author (map-elt c 'author)
                  :merge (eq (map-elt c 'merge_from_base) t)))
          (map-elt since 'commits)))

(defun decknix-review-board-rereview--self-push-p (commits viewer)
  "Non-nil when every one of COMMITS was authored by VIEWER.
A push of my own is not news to me, and re-reviewing it would loop a
session that pushed on the very re-review it was asked for."
  (and viewer commits
       (seq-every-p (lambda (c)
                      (let ((a (plist-get c :author)))
                        (and (stringp a) (string-equal-ignore-case a viewer))))
                    commits)))

(defun decknix-review-board-rereview--mine-p (item)
  "Non-nil when ITEM carries a submitted review of mine with feedback.
A dismissed review counts: the push that dismissed it is exactly what a
re-review is for."
  (let ((my (map-elt item 'my_review)))
    (and (stringp my)
         (not (equal my "PENDING"))
         (or (equal my "DISMISSED")
             (eq (map-elt item 'my_review_feedback) t)
             ;; An older hub has no `my_review_feedback': the state alone.
             (and (not (assq 'my_review_feedback item))
                  (member my decknix-review-board-rereview-feedback-states))
             decknix-review-board-rereview-bare-approvals))))

(defun decknix-review-board-rereview--noise (since commits)
  "Return why a push described by SINCE and COMMITS changes nothing, or nil.
`base-merge' when it only merged the base branch, `rebase' when it was
rebased with the PR's own diff unchanged."
  (let ((rebased (member (map-elt since 'status) '("diverged" "behind")))
        (unchanged (eq (map-elt since 'diff_unchanged) t))
        (merges-only (and commits (seq-every-p (lambda (c) (plist-get c :merge))
                                               commits))))
    (cond
     ((and unchanged rebased) 'rebase)
     ((or merges-only (and unchanged (not rebased))) 'base-merge)
     (t nil))))

(defun decknix-review-board-rereview--ignored-p (noise)
  "Non-nil when NOISE is a kind the user asked to ignore."
  (pcase noise
    ('base-merge decknix-review-board-rereview-ignore-base-merges)
    ('rebase decknix-review-board-rereview-ignore-rebases)
    (_ nil)))

(defun decknix-review-board-rereview-info (item settled &optional viewer seen-head)
  "Return how ITEM moved since its review, as a plist, or nil.  Pure.

ITEM is the PR's reviews-feed entry.  SETTLED is non-nil when a review
session on it is finished or idle -- neither working nor blocked on you
-- which is what lets SOMEBODY ELSE's feedback count: the user's session
was waiting on it.  VIEWER is my login, SEEN-HEAD the head a re-review
was already started for (so each head is re-reviewed at most once).

Updated means: open and not a draft; a reference review exists (mine
with feedback, else, when SETTLED, the latest other human's feedback);
the head is no longer the commit it reviewed; and the push was not only
noise (`decknix-review-board-rereview--noise') nor only my own commits.

Returns nil, or (:reason mine|others :from SHA :head SHA :commits LIST
:count N :files N :status STR :rebased BOOL :noise SYM :dismissed BOOL
:threads (:mine N :resolved N :answered N) :by LOGIN :by-state STR
:updated TIME)."
  (when (and item (not (eq (map-elt item 'draft) t)))
    (let* ((mine (decknix-review-board-rereview--mine-p item))
           (feedback (map-elt item 'feedback_review))
           (reason (cond (mine 'mine)
                         ((and settled feedback) 'others)))
           (head (map-elt item 'head_sha))
           (since (map-elt item 'since_review))
           (from (or (map-elt since 'from)
                     (if (eq reason 'mine)
                         (map-elt item 'my_review_sha)
                       (or (map-elt item 'my_review_sha) (map-elt feedback 'sha)))))
           (commits (decknix-review-board-rereview--commits since))
           (moved (cond
                   ((null reason) nil)
                   (head (and from (not (equal from head))))
                   ;; An older hub: no shas, only the flags.
                   ((eq reason 'mine) (eq (map-elt item 'pushed_since_my_review) t))
                   (t (eq (map-elt item 'review_stale) t))))
           (noise (and since (decknix-review-board-rereview--noise since commits))))
      (when (and moved
                 (not (decknix-review-board-rereview--ignored-p noise))
                 (not (decknix-review-board-rereview--self-push-p commits viewer))
                 (not (and seen-head head (equal seen-head head))))
        (list :reason reason
              :from from
              :head head
              :commits commits
              :count (and since (length commits))
              :files (map-elt since 'files)
              :status (map-elt since 'status)
              :rebased (and (member (map-elt since 'status) '("diverged" "behind")) t)
              :noise noise
              :dismissed (equal (map-elt item 'my_review) "DISMISSED")
              :threads (when (map-elt item 'my_threads)
                         (list :mine (map-elt item 'my_threads)
                               :resolved (or (map-elt item 'my_threads_resolved) 0)
                               :answered (or (map-elt item 'my_threads_answered) 0)))
              :by (and (eq reason 'others) (map-elt feedback 'author))
              :by-state (and (eq reason 'others) (map-elt feedback 'state))
              :updated (map-elt item 'updated))))))

;; ── presentation ────────────────────────────────────────────────────

(defun decknix-review-board-rereview-short-sha (sha)
  "Return the first seven characters of SHA, or \"?\"."
  (if (and (stringp sha) (> (length sha) 7)) (substring sha 0 7) (or sha "?")))

(defun decknix-review-board-rereview-age (iso &optional now)
  "Return how long ago ISO (an ISO-8601 string) was: `5m', `3h', `2d', or nil."
  (when-let* (((stringp iso))
              (time (ignore-errors (parse-iso8601-time-string iso))))
    (let ((secs (max 0 (floor (- (or now (float-time)) (float-time time))))))
      (cond ((< secs 3600) (format "%dm" (max 1 (/ secs 60))))
            ((< secs 86400) (format "%dh" (/ secs 3600)))
            (t (format "%dd" (/ secs 86400)))))))

(defun decknix-review-board-rereview-summary (info &optional now)
  "Return the one-line summary of INFO for a board row.  Pure.
\"2 commits, 3 files · 1/2 threads resolved, 2 replied · rebased ·
approval dismissed · 3h ago\"."
  (let* ((count (plist-get info :count))
         (files (plist-get info :files))
         (threads (plist-get info :threads))
         (age (decknix-review-board-rereview-age (plist-get info :updated) now)))
    (string-join
     (delq nil
           (list
            (if count
                (concat (format "%d commit%s" count (if (= count 1) "" "s"))
                        (when files (format ", %d file%s" files (if (= files 1) "" "s"))))
              "pushed since")
            (when (and threads (> (plist-get threads :mine) 0))
              (format "%d/%d threads resolved%s"
                      (plist-get threads :resolved) (plist-get threads :mine)
                      (if (> (plist-get threads :answered) 0)
                          (format ", %d replied" (plist-get threads :answered))
                        "")))
            (when (eq (plist-get info :reason) 'others)
              (format "after @%s's %s" (or (plist-get info :by) "?")
                      (downcase (replace-regexp-in-string
                                 "_" " " (or (plist-get info :by-state) "review")))))
            (when (plist-get info :rebased) "rebased")
            (when (plist-get info :dismissed) "approval dismissed")
            (when age (concat age " ago"))))
     " · ")))

(defun decknix-review-board-rereview-detail (info)
  "Return a multi-line description of INFO for the inspect window.  Pure."
  (concat
   (format "Updated since the review at %s (now %s)\n"
           (decknix-review-board-rereview-short-sha (plist-get info :from))
           (decknix-review-board-rereview-short-sha (plist-get info :head)))
   (format "  %s\n" (decknix-review-board-rereview-summary info))
   (mapconcat (lambda (c)
                (format "    %s %s%s\n"
                        (decknix-review-board-rereview-short-sha (plist-get c :sha))
                        (plist-get c :headline)
                        (if (plist-get c :merge) "  (base merge)" "")))
              (plist-get info :commits) "")
   "\n"))

(defun decknix-review-board-rereview-prompt (info &optional worktree)
  "Return the prompt asking a review session to re-review INFO.  Pure.

WORKTREE is the PR checkout, already moved to the new head, or nil.  The
prompt keeps the normal confirmation gate explicitly: a re-review is
started without the user, so it must never post on its own."
  (let* ((from (plist-get info :from))
         (head (plist-get info :head))
         (count (plist-get info :count))
         (range (if (and from head) (format "%s..%s" from head) "the previous review..HEAD"))
         (commits (plist-get info :commits)))
    (concat
     (if (eq (plist-get info :reason) 'others)
         (format "@%s left a %s review at %s and the author has since pushed"
                 (or (plist-get info :by) "another reviewer")
                 (downcase (replace-regexp-in-string
                            "_" " " (or (plist-get info :by-state) "feedback")))
                 (decknix-review-board-rereview-short-sha from))
       (format "The author pushed since your review at %s"
               (decknix-review-board-rereview-short-sha from)))
     (if count (format " (%d commit%s, now at %s)." count (if (= count 1) "" "s")
                       (decknix-review-board-rereview-short-sha head))
       (format " (now at %s)." (decknix-review-board-rereview-short-sha head)))
     (when commits
       (concat "\n"
               (mapconcat (lambda (c)
                            (format "- %s %s" (decknix-review-board-rereview-short-sha
                                               (plist-get c :sha))
                                    (plist-get c :headline)))
                          commits "\n")))
     "\n\nRe-review only the changes since that review: fetch first, then `git diff "
     range "`"
     (if worktree (format " in the PR worktree %s" worktree) " in the PR worktree")
     "."
     (when (plist-get info :rebased)
       (concat " The PR was force-pushed (rebased), so the plain diff includes base"
               " changes; compare the PR's own changes, e.g. `git range-diff`."))
     " Check whether your earlier feedback and the other reviewers' threads were"
     " addressed (replied to, resolved, or fixed in code)."
     (when (plist-get info :dismissed)
       " The push dismissed your earlier approval, so it needs re-approving if it still stands.")
     " Then present an updated verdict at the confirmation gate as before;"
     " do not post anything until I confirm.")))

;; ── what to do about it ─────────────────────────────────────────────

(defvar decknix-review-board-rereview--seen (make-hash-table :test 'equal)
  "PR key -> the head a re-review was started (or acknowledged) for.")

(defvar decknix-review-board-rereview--notified (make-hash-table :test 'equal)
  "PR key -> the head the user was last told about.")

(defvar decknix-review-board-rereview-state-file
  (expand-file-name "decknix/review-rereview.eld"
                    (or (getenv "XDG_STATE_HOME") "~/.local/state"))
  "Where the re-reviewed heads persist, so a restart does not re-run them.
Nil disables persistence.")

(defvar decknix-review-board-rereview--loaded nil
  "Non-nil once the state file has been read.")

(defun decknix-review-board-rereview--load ()
  "Read the persisted heads once."
  (unless decknix-review-board-rereview--loaded
    (setq decknix-review-board-rereview--loaded t)
    (when (and decknix-review-board-rereview-state-file
               (file-readable-p decknix-review-board-rereview-state-file))
      (ignore-errors
        (dolist (cell (with-temp-buffer
                        (insert-file-contents decknix-review-board-rereview-state-file)
                        (read (current-buffer))))
          (puthash (car cell) (cdr cell) decknix-review-board-rereview--seen))))))

(defun decknix-review-board-rereview--save ()
  "Persist the re-reviewed heads.  Runs only when one is added."
  (when decknix-review-board-rereview-state-file
    (ignore-errors
      (make-directory (file-name-directory decknix-review-board-rereview-state-file) t)
      (let (cells)
        (maphash (lambda (k v) (push (cons k v) cells))
                 decknix-review-board-rereview--seen)
        (with-temp-file decknix-review-board-rereview-state-file
          (let ((print-length nil) (print-level nil))
            (prin1 cells (current-buffer))))))))

(defun decknix-review-board-rereview-seen-head (pr-key)
  "Return the head a re-review was already started for on PR-KEY, or nil."
  (decknix-review-board-rereview--load)
  (gethash pr-key decknix-review-board-rereview--seen))

(defun decknix-review-board-rereview-mark-seen (pr-key head)
  "Record that PR-KEY was re-reviewed (or acknowledged) at HEAD."
  (decknix-review-board-rereview--load)
  (unless (equal (gethash pr-key decknix-review-board-rereview--seen) head)
    (puthash pr-key head decknix-review-board-rereview--seen)
    (decknix-review-board-rereview--save)))

(defvar decknix-review-board-rereview-refresh-function nil
  "Function (OWNER REPO NUMBER HEAD CALLBACK) moving the PR worktree to HEAD.
CALLBACK receives the worktree path, or nil when there is none.  Nil
means no worktree support: the callback runs straight away with nil.")

(defvar decknix-review-board-rereview-deliver-function nil
  "Function (ROW URL PROMPT CONTEXT) handing PROMPT to ROW's review session.
Reuses the live session, else resumes the saved one, else starts a new
review whose command carries CONTEXT.  Must not display a window.")

(defvar decknix-review-board-rereview-notify-function #'message
  "Function (FORMAT &rest ARGS) telling the user about an updated PR.")

(defun decknix-review-board-rereview-start (row info url owner repo number)
  "Start the re-review INFO describes for ROW.

Marks the head seen first, so a second trigger while the worktree is
still fetching cannot start it twice.  Then moves the worktree to the new
head and hands the session the prompt."
  (let ((key (car (plist-get row :prs)))
        (head (plist-get info :head)))
    (when (and key head)
      (decknix-review-board-rereview-mark-seen key head))
    (let ((deliver
           (lambda (worktree)
             (when decknix-review-board-rereview-deliver-function
               (funcall decknix-review-board-rereview-deliver-function
                        row url
                        (decknix-review-board-rereview-prompt info worktree)
                        (decknix-review-board-rereview-prompt info nil))))))
      (if (and decknix-review-board-rereview-refresh-function owner repo number head)
          (funcall decknix-review-board-rereview-refresh-function
                   owner repo number head deliver)
        (funcall deliver nil)))))

(defun decknix-review-board-rereview-process (rows mode start-fn)
  "Notify about, and in `auto' MODE start, the updated ROWS.  Return those started.

ROWS are board rows carrying `:rereview' info.  The user is told once per
PR per new head; in `auto' a re-review is started at most once per head
\(see `decknix-review-board-rereview-seen-head', which also keeps the
row out of the Re-review lane afterwards).  START-FN is called with
\(ROW INFO) for each one to start."
  (let (started)
    (dolist (row rows)
      (let* ((info (plist-get row :rereview))
             (key (car (plist-get row :prs)))
             (head (plist-get info :head)))
        (when (and info key mode)
          (unless (equal (gethash key decknix-review-board-rereview--notified) head)
            (puthash key head decknix-review-board-rereview--notified)
            (funcall decknix-review-board-rereview-notify-function
                     "Review Board: %s updated since the review (%s)%s"
                     key (decknix-review-board-rereview-summary info)
                     (if (eq mode 'auto) "; re-reviewing" "; R to re-review")))
          (when (and (eq mode 'auto)
                     (not (equal (decknix-review-board-rereview-seen-head key) head)))
            (funcall start-fn row info)
            (push row started)))))
    (nreverse started)))

(provide 'decknix-review-board-rereview)
;;; decknix-review-board-rereview.el ends here
