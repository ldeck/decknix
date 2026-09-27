;;; decknix-hub-pr-memory.el --- Remember which PR a branch had -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, pr, worktree

;;; Commentary:
;;
;; `wip' is meant to mean "branch not yet promoted to a PR".  It also
;; means "PR merged", which is how a merged worktree renders as a dim
;; `wip' row with no `#N' and no actionable URL.
;;
;; `decknix--hub-wip-placeholder-rows' selects worktrees "lacking a
;; matching OPEN PR", and two very different things satisfy that: a branch
;; that never had a PR, and a branch whose PR merged or closed and so left
;; the open feed.  Nothing remembered the second case, so the association
;; was lost -- a labelling symptom with a data cause.
;;
;; This module owns that association and nothing else:
;;
;;     (repo, branch)  ->  (:number N :url U :repo R :branch B :seen TS)
;;
;; IDENTITY ONLY, deliberately.  The WIP feed carries open PRs, so at
;; harvest time every remembered PR is open and the feed can never tell us
;; a PR merged -- it just stops appearing.  Storing a state here would
;; therefore bake in "OPEN" forever and be wrong the moment it mattered.
;;
;; State comes from the existing URL-keyed machinery instead, which was
;; already built for this exact case.  `decknix--hub-pr-cache-orphan-ttl'
;; says so in as many words: "When `decknix--hub-pr-status' finds no entry
;; in the hub WIP/Reviews data but has a non-terminal cached state, the PR
;; has most likely merged or closed since the last hub poll."  That
;; machinery only ever needed a URL, and the URL is precisely what the
;; placeholder row had thrown away.
;;
;; So the split is: this module answers "which PR was that?", the status
;; cache answers "what state is it in now?", `decknix--hub-format-row-label'
;; turns that into a word, and `decknix--hub-wip-terminal-visible-p'
;; decides whether the row shows at all.  No new vocabulary and no second
;; visibility rule.
;;
;; There is NO TTL here.  A status cache should expire; a memory of which
;; PR a branch had must not, or the row silently regresses to `wip' after
;; three minutes and the bug comes back on a timer.
;;
;; Known limit, inherited from `wip-worktree-status.md' open question 3: a
;; branch deleted and recreated with no PR yet still reads as its old PR.
;; Harvest overwrites on each poll so an actual new PR corrects it, and the
;; remembered state is resolved live rather than stored, which bounds how
;; wrong it can be.  Strictly better than today, where EVERY merged PR
;; loses its number.

;;; Code:

(require 'cl-lib)
(require 'json)

(declare-function decknix-hub-worktree-clones "decknix-agent-shell-hub" ())
(declare-function decknix-hub-worktree-list "decknix-agent-shell-hub" (repo))

(defvar decknix--hub-pr-memory (make-hash-table :test 'equal)
  "Last-known PR per branch: KEY -> plist (:number :url :repo :branch :seen).
KEY is from `decknix--hub-pr-memory-key'.  Never expires; see the
commentary on why a TTL would reintroduce the bug on a timer.")

(defvar decknix--hub-pr-memory-file
  (expand-file-name "~/.config/decknix/hub/pr-memory.el")
  "Persistence file for `decknix--hub-pr-memory'.")


;; --- pure layers ------------------------------------------------------

(defun decknix--hub-pr-memory-key (repo branch)
  "Return the memory key for BRANCH in REPO, or nil if either is missing.
REPO is lowercased to match the worktree registry, which stores
lowercase while `gh search prs' may return mixed casing for
`owner/repo' -- the same canonicalisation
`decknix--hub-wip-placeholder-rows' already does for its dedup."
  (when (and (stringp repo) (stringp branch)
             (not (string-empty-p repo)) (not (string-empty-p branch)))
    (concat (downcase repo) "\0" branch)))

(defun decknix--hub-pr-memory-harvest (wip-data &optional now)
  "Return ((KEY . PLIST) ...) for every branch-carrying PR in WIP-DATA.
NOW is supplied by the caller so this layer stays free of the clock.
PRs without both a branch and a URL are skipped: a row we cannot act on
is exactly what this module exists to stop producing."
  (let (out)
    (dolist (repo-entry (alist-get 'repos wip-data))
      (let ((repo (alist-get 'repo repo-entry)))
        (dolist (pr (alist-get 'prs repo-entry))
          (let* ((branch (alist-get 'branch pr))
                 (url (alist-get 'url pr))
                 (key (decknix--hub-pr-memory-key repo branch)))
            (when (and key url)
              (push (cons key
                          (list :number (alist-get 'number pr)
                                :url url
                                :repo (downcase repo)
                                :branch branch
                                :seen (or now 0)))
                    out))))))
    (nreverse out)))

(defun decknix--hub-pr-memory-row-label (entry status)
  "Return the state word for a placeholder row, given ENTRY and STATUS.

ENTRY is a memory plist or nil; STATUS is the resolved PR alist from the
URL-keyed cache, or nil when nothing is known yet.

With no memory the branch genuinely never had a PR, which is the one case
`wip' is the correct word for.  With memory but no resolved status the PR
is known to exist and its state is merely not loaded, so the row says so
rather than lying in either direction.  Otherwise the existing vocabulary
decides, so `merged', `closed', `drafting', `awaiting review' and the
rest arrive here without being redefined."
  (cond
   ((null entry) "wip")
   ((null status) "pr ?")
   (t (decknix--hub-format-row-label status))))

(defun decknix--hub-pr-memory-row-visible-p (entry status)
  "Return non-nil when a placeholder row for ENTRY/STATUS should show.

A branch with no remembered PR is always visible: it is local work in
progress and no terminal filter applies.  Otherwise defer to
`decknix--hub-wip-terminal-visible-p' so a remembered merged PR obeys the
SAME deploy-gated rule as a real merged WIP row, rather than a second
rule that would drift from it (open question 2 of the spec)."
  (cond
   ((null entry) t)
   ((null status) t)
   (t (decknix--hub-wip-terminal-visible-p status))))


;; --- table operations -------------------------------------------------

(defun decknix--hub-pr-memory-lookup (repo branch)
  "Return the remembered PR plist for BRANCH in REPO, or nil."
  (let ((key (decknix--hub-pr-memory-key repo branch)))
    (and key (gethash key decknix--hub-pr-memory))))

(defun decknix--hub-pr-memory-remember (wip-data &optional now)
  "Record every PR in WIP-DATA against its branch.
Returns the number of entries written.  Overwrites, so a new PR on a
reused branch replaces the old association on the next poll."
  (let ((entries (decknix--hub-pr-memory-harvest
                  wip-data (or now (float-time))))
        (written 0))
    (dolist (entry entries)
      (puthash (car entry) (cdr entry) decknix--hub-pr-memory)
      (setq written (1+ written)))
    written))


;; --- persistence ------------------------------------------------------

(defun decknix--hub-pr-memory-save ()
  "Persist the PR memory to disk."
  (when (> (hash-table-count decknix--hub-pr-memory) 0)
    (condition-case err
        (let (entries)
          (maphash (lambda (k v) (push (cons k v) entries))
                   decknix--hub-pr-memory)
          (make-directory (file-name-directory decknix--hub-pr-memory-file) t)
          (with-temp-file decknix--hub-pr-memory-file
            (insert ";; Auto-generated hub PR memory — do not edit\n")
            (prin1 entries (current-buffer))
            (insert "\n")))
      (error
       (message "hub-pr-memory: save failed: %s" (error-message-string err))))))

(defun decknix--hub-pr-memory-restore ()
  "Restore the PR memory from disk."
  (when (file-exists-p decknix--hub-pr-memory-file)
    (condition-case err
        (let ((entries (with-temp-buffer
                         (insert-file-contents decknix--hub-pr-memory-file)
                         (read (current-buffer)))))
          (when (listp entries)
            (dolist (entry entries)
              (when (and (consp entry) (stringp (car entry)))
                (puthash (car entry) (cdr entry) decknix--hub-pr-memory)))))
      (error
       (message "hub-pr-memory: restore failed: %s"
                (error-message-string err))))))

;; --- backfill for branches whose PR already left the feed -------------
;;
;; `remember' only learns while a PR is OPEN, so anything merged or closed
;; before this ran has no entry and its row falls back to `wip'. That is not an
;; edge case: the house default is REBASE merge, which replays commits onto the
;; base as new SHAs, so a merged branch's tip is never an ancestor of the base
;; and no git-side check can see it either.
;;
;; So ask GitHub once per unknown branch. Identity only, as ever: the state is
;; resolved afterwards through the URL-keyed cache.

(defcustom decknix-hub-pr-memory-backfill-parallel 4
  "How many `gh' queries the backfill runs at once."
  :type 'integer
  :group 'decknix)

(defun decknix--hub-pr-memory-parse-gh-pr (json-string)
  "Return (NUMBER . URL) from a `gh pr list --json number,url' payload, or nil.

Nil for an empty list, which is how \"this branch never had a PR\" arrives and
must stay distinct from a failed query -- recording nothing on failure is
right, recording a wrong association is not."
  (let ((parsed (ignore-errors
                  (json-parse-string json-string
                                     :object-type 'alist
                                     :array-type 'list
                                     :null-object nil
                                     :false-object nil))))
    (when (and (listp parsed) parsed)
      (let* ((first (car parsed))
             (number (alist-get 'number first))
             (url (alist-get 'url first)))
        (when (and number url) (cons number url))))))

(defun decknix--hub-pr-memory-record (repo branch number url)
  "Record NUMBER and URL against BRANCH in REPO."
  (let ((key (decknix--hub-pr-memory-key repo branch)))
    (when (and key number url)
      (puthash key (list :number number :url url
                         :repo (downcase repo) :branch branch
                         :seen (float-time))
               decknix--hub-pr-memory)
      t)))

(defun decknix--hub-pr-memory-unknown-branches ()
  "Return ((REPO . BRANCH) ...) for worktree branches with no remembered PR."
  (let (out)
    (dolist (clone (decknix-hub-worktree-clones))
      (let ((repo (car clone))
            (primary (cdr clone)))
        (dolist (wt (decknix-hub-worktree-list repo))
          (let ((branch (car wt))
                (path (cdr wt)))
            (when (and branch path
                       (not (and primary
                                 (string=
                                  (file-name-as-directory (expand-file-name path))
                                  (file-name-as-directory (expand-file-name primary)))))
                       (not (decknix--hub-pr-memory-lookup repo branch)))
              (push (cons repo branch) out))))))
    (nreverse out)))

(defvar decknix--hub-pr-memory-backfill-queue nil)
(defvar decknix--hub-pr-memory-backfill-inflight 0)
(defvar decknix--hub-pr-memory-backfill-total 0)
(defvar decknix--hub-pr-memory-backfill-found 0)

(defun decknix--hub-pr-memory-backfill-finish ()
  "Persist and report once the queue has drained."
  (decknix--hub-pr-memory-save)
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (ignore-errors (agent-shell-workspace-sidebar-refresh)))
  (message "PR memory: recorded %d of %d branch(es)"
           decknix--hub-pr-memory-backfill-found
           decknix--hub-pr-memory-backfill-total))

(defun decknix--hub-pr-memory-backfill-sentinel (repo branch buffer event)
  "Record REPO/BRANCH from BUFFER when the query finished, then pump."
  (when (string-match-p "\\`\\(finished\\|exited\\|deleted\\|failed\\)" event)
    (setq decknix--hub-pr-memory-backfill-inflight
          (1- decknix--hub-pr-memory-backfill-inflight))
    (when (buffer-live-p buffer)
      (let ((hit (decknix--hub-pr-memory-parse-gh-pr
                  (with-current-buffer buffer (buffer-string)))))
        (when (and hit (decknix--hub-pr-memory-record
                        repo branch (car hit) (cdr hit)))
          (setq decknix--hub-pr-memory-backfill-found
                (1+ decknix--hub-pr-memory-backfill-found))))
      (kill-buffer buffer))
    (decknix--hub-pr-memory-backfill-pump)))

(defun decknix--hub-pr-memory-backfill-pump ()
  "Launch queries up to the parallel limit, or finish when drained."
  (while (and decknix--hub-pr-memory-backfill-queue
              (< decknix--hub-pr-memory-backfill-inflight
                 decknix-hub-pr-memory-backfill-parallel))
    (let* ((entry (pop decknix--hub-pr-memory-backfill-queue))
           (repo (car entry))
           (branch (cdr entry))
           (buffer (generate-new-buffer " *decknix-pr-backfill*")))
      (setq decknix--hub-pr-memory-backfill-inflight
            (1+ decknix--hub-pr-memory-backfill-inflight))
      (make-process
       :name "decknix-pr-backfill"
       :buffer buffer
       :noquery t
       :command (list "gh" "pr" "list" "--repo" repo "--head" branch
                      "--state" "all" "--limit" "1" "--json" "number,url")
       :sentinel (lambda (_proc event)
                   (decknix--hub-pr-memory-backfill-sentinel
                    repo branch buffer event)))))
  (when (and (null decknix--hub-pr-memory-backfill-queue)
             (zerop decknix--hub-pr-memory-backfill-inflight)
             (> decknix--hub-pr-memory-backfill-total 0))
    (setq decknix--hub-pr-memory-backfill-total 0)
    (decknix--hub-pr-memory-backfill-finish)))

(defun decknix-hub-pr-memory-backfill ()
  "Learn the PR for every worktree branch that has no remembered one.

Queries `gh pr list --state all' per branch, so a merged or closed PR is
found even though it left the open feed."
  (interactive)
  (let ((pending (decknix--hub-pr-memory-unknown-branches)))
    (if (null pending)
        (message "PR memory: nothing to backfill")
      (setq decknix--hub-pr-memory-backfill-queue pending
            decknix--hub-pr-memory-backfill-inflight 0
            decknix--hub-pr-memory-backfill-found 0
            decknix--hub-pr-memory-backfill-total (length pending))
      (message "PR memory: backfilling %d branch(es)..." (length pending))
      (decknix--hub-pr-memory-backfill-pump))))

(provide 'decknix-hub-pr-memory)
;;; decknix-hub-pr-memory.el ends here
