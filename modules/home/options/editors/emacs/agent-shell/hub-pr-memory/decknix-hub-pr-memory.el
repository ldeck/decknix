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

(provide 'decknix-hub-pr-memory)
;;; decknix-hub-pr-memory.el ends here
