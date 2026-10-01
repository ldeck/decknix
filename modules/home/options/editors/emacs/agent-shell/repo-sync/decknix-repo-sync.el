;;; decknix-repo-sync.el --- Repo-sync problems for the sidebar -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, git, repo

;;; Commentary:
;;
;; `org.nixos.decknix-repo-sync' fetches and fast-forwards every clone in the
;; workspace every three hours.  When it fails on a repo, nothing said so: the
;; only evidence was a tally line in /tmp/decknix-repo-sync.out reading
;; "3 errors" run after run, with the SAME count every time, so a repo could
;; rot indefinitely without the number moving.
;;
;; It did.  `upside' failed on an abandoned `index.lock' for 61 consecutive
;; runs -- two weeks with no updates -- and was only noticed when a manual
;; `git pull' hit the same lock.  That is the defect this surfaces: not the
;; lock, but that a silent, unchanging failure count is indistinguishable from
;; health.
;;
;; `decknix repos sync' writes its report to ~/.config/decknix/repo-sync.json.
;; This reads it and classifies each row into what the user can DO about it,
;; which is the only distinction a sidebar row needs to make:
;;
;;   lock      an abandoned index.lock -> one keypress fixes it
;;   dirty     uncommitted work blocks the fast-forward -> go look
;;   diverged  local default has commits origin lacks -> go look
;;   failed    anything else (ssh config, network, ...) -> needs a human
;;   ok        nothing to do; never rendered
;;
;; Pure layers here per AGENTS.md Rule 2; the cache refresh, rendering and
;; actions live in the hub/sidebar side-effect layers.

;;; Code:

(require 'json)
(require 'seq)
(require 'subr-x)

(defcustom decknix-repo-sync-report
  (expand-file-name "~/.config/decknix/repo-sync.json")
  "Path to the report written by `decknix repos sync'."
  :type 'file
  :group 'decknix)

(defcustom decknix-repo-sync-show-behind t
  "When non-nil, show repos skipped while falling behind origin.

A dirty or diverged checkout is a deliberate state, not an error, so it is
reported separately from a failure.  It still matters: five primary
checkouts were sitting between 36 and 102 commits behind because the sweep
correctly refused to merge over uncommitted work, and nothing said so."
  :type 'boolean
  :group 'decknix)

(defconst decknix-repo-sync-kinds '(lock dirty diverged failed)
  "Problem kinds, most actionable first.
Ordering is the render order: a row you can fix with one keypress should not
sit below one that needs a decision.")


;; --- pure layers ------------------------------------------------------

(defun decknix--repo-sync-behind (detail)
  "Return the `behind +N' count parsed out of DETAIL, or nil.

The CLI reports how far a skipped repo has drifted inside its human phrase
\(\"main behind +102 but working tree dirty\").  Surfacing the number is the
difference between a row that reads as noise and one that reads as a
backlog."
  (when (and (stringp detail)
             (string-match "behind \\+\\([0-9]+\\)" detail))
    (string-to-number (match-string 1 detail))))

(defun decknix--repo-sync-classify (row)
  "Return the problem kind for ROW, or nil when there is nothing to do.

ROW is one entry of the report's `repos' array as an alist.  Classification
keys off `outcome' rather than the human `detail' string, except for
distinguishing dirty from diverged -- the CLI collapses both into `skipped'
and only the phrase tells them apart."
  (let ((outcome (alist-get 'outcome row))
        (detail (or (alist-get 'detail row) "")))
    (cond
     ((equal outcome "error-lock") 'lock)
     ((equal outcome "error") 'failed)
     ((equal outcome "skipped")
      ;; The CLI collapses two different situations into `skipped', and only
      ;; the phrase separates them.  Diverged is checked FIRST and without a
      ;; behind count: its detail reads "main diverged (+126/-6)" with no
      ;; "behind +N" at all, so requiring the count dropped every diverged
      ;; repo silently -- which is the failure mode this module exists to stop.
      (cond
       ((string-match-p "diverged" detail) 'diverged)
       ((decknix--repo-sync-behind detail) 'dirty)
       ;; A skip that is neither is up to date; rendering it would bury the
       ;; rows that need something.
       (t nil)))
     ;; `no-origin' is a local-only clone (a scratch or retro directory), not
     ;; a failure -- there is no upstream to fall behind.
     (t nil))))

(defun decknix--repo-sync-name (row)
  "Return the repo directory name for ROW."
  (let ((path (alist-get 'path row)))
    (if (and (stringp path) (not (string-empty-p path)))
        (file-name-nondirectory (directory-file-name path))
      (or (alist-get 'org row) "?"))))

(defun decknix--repo-sync-problem (row)
  "Return a problem plist for ROW, or nil when ROW is healthy."
  (when-let ((kind (decknix--repo-sync-classify row)))
    (list :kind kind
          :name (decknix--repo-sync-name row)
          :path (alist-get 'path row)
          :org (alist-get 'org row)
          :branch (alist-get 'defaultBranch row)
          :behind (decknix--repo-sync-behind (or (alist-get 'detail row) ""))
          :detail (alist-get 'detail row))))

(defun decknix--repo-sync-parse (json-string)
  "Return (:updated TS :problems LIST) parsed from JSON-STRING.

Nil when the payload cannot be parsed, which is treated as \"no report yet\"
rather than \"no problems\" -- the same reason the worktree audit parser
returns nil on garbage.  Reporting health from an unreadable file would
recreate the bug this module exists for."
  (let ((report (ignore-errors
                  (json-parse-string json-string
                                     :object-type 'alist
                                     :array-type 'list
                                     :null-object nil
                                     :false-object nil))))
    (when (and (listp report) (alist-get 'repos report))
      (list :updated (alist-get 'updated report)
            :problems
            (decknix--repo-sync-sort
             (delq nil (mapcar #'decknix--repo-sync-problem
                               (alist-get 'repos report))))))))

(defun decknix--repo-sync-sort (problems)
  "Return PROBLEMS ordered by kind, then by how far behind, then by name."
  (sort (copy-sequence problems)
        (lambda (a b)
          (let ((ka (seq-position decknix-repo-sync-kinds (plist-get a :kind)))
                (kb (seq-position decknix-repo-sync-kinds (plist-get b :kind))))
            (cond
             ((/= ka kb) (< ka kb))
             ;; Furthest behind first: it is the one closest to a painful merge.
             ((/= (or (plist-get a :behind) 0) (or (plist-get b :behind) 0))
              (> (or (plist-get a :behind) 0) (or (plist-get b :behind) 0)))
             (t (string< (or (plist-get a :name) "")
                         (or (plist-get b :name) ""))))))))

(defun decknix--repo-sync-visible-p (problem)
  "Return non-nil when PROBLEM should be rendered."
  (or decknix-repo-sync-show-behind
      (memq (plist-get problem :kind) '(lock failed))))

(defconst decknix-repo-sync-glyphs
  '((lock . "🔒") (dirty . "✎") (diverged . "⑃") (failed . "⚠"))
  "Glyph per problem kind.
`lock' gets the one that reads as \"mechanically fixable\"; `failed' the one
that reads as \"a human has to look\".")

(defun decknix--repo-sync-row-label (problem)
  "Return the sidebar label for PROBLEM."
  (let* ((kind (plist-get problem :kind))
         (behind (plist-get problem :behind))
         (glyph (or (alist-get kind decknix-repo-sync-glyphs) "?")))
    (concat glyph " " (plist-get problem :name)
            (pcase kind
              ('lock " · stale lock")
              ('dirty (format " · dirty, %s behind" (or behind "?")))
              ('diverged (if behind
                             (format " · diverged, %s behind" behind)
                           " · diverged from origin"))
              ('failed " · sync failed")))))

(defcustom decknix-repo-sync-collapse-failed 3
  "Collapse `failed\=' rows into one summary line past this many.

A sweep that cannot reach the network fails every repo at once -- measured
11 identical \"sync failed\" rows in red -- which crowds out the kinds that
name a specific, fixable problem.  The rows say the same thing, so one
line saying it once with a count carries the same information."
  :type 'integer
  :group 'decknix)

(defun decknix--repo-sync-collapse (problems threshold expanded)
  "Partition PROBLEMS into (KEPT . COLLAPSED) for rendering.

COLLAPSED is the list of `failed\=' problems folded into a summary line, or
nil when there is nothing to fold.  Folding applies only when EXPANDED is
nil and the failed count exceeds THRESHOLD: below it the rows are worth
reading individually, and a count of one is not a summary.

Only `failed\=' folds.  Every other kind names a distinct remedy -- a stale
lock, a dirty tree, a diverged branch -- so collapsing those would hide
the actionable rows behind a number."
  (let* ((failed (seq-filter (lambda (p) (eq 'failed (plist-get p :kind)))
                             problems)))
    (if (or expanded (not (integerp threshold))
            (<= (length failed) threshold))
        (cons problems nil)
      (cons (seq-remove (lambda (p) (eq 'failed (plist-get p :kind)))
                        problems)
            failed))))

(defun decknix--repo-sync-collapsed-label (collapsed)
  "Return the summary line for COLLAPSED failed problems."
  (format "⚠ %d repos · sync failed" (length collapsed)))

(defun decknix--repo-sync-summary (problems)
  "Return a one-line count of PROBLEMS by kind, or nil when there are none."
  (let ((counts (mapcar (lambda (kind)
                          (cons kind
                                (seq-count (lambda (p) (eq kind (plist-get p :kind)))
                                           problems)))
                        decknix-repo-sync-kinds)))
    (when (seq-some (lambda (cell) (> (cdr cell) 0)) counts)
      (string-join
       (delq nil (mapcar (lambda (cell)
                           (when (> (cdr cell) 0)
                             (format "%d %s" (cdr cell) (car cell))))
                         counts))
       ", "))))

(defun decknix--repo-sync-stale-report-p (updated now &optional interval)
  "Return non-nil when a report stamped UPDATED is overdue at NOW.

INTERVAL defaults to twice the launchd `StartInterval' (3h), so one missed
run is tolerated and two are not.  A report that stopped being written is
its own failure: the sidebar would otherwise keep rendering week-old
problems as though they were current."
  (let ((interval (or interval (* 2 10800))))
    (or (null updated)
        (not (numberp updated))
        (> (- now updated) interval))))

(provide 'decknix-repo-sync)
;;; decknix-repo-sync.el ends here
