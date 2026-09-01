;;; decknix-agent-review-worktree.el --- Worktree-backed PR review sessions -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, git, worktree, review

;;; Commentary:
;;
;; ldeck/decknix#165 step 1: run a PR review session in a real git
;; worktree checked out at the PR head.
;;
;; What was actually there before (measured, because the issue body was
;; wrong): review sessions did NOT run in `/tmp'.  They ran in the
;; WORKSPACE ROOT -- `/Users/ldeck/Code/nurturecloud/' -- with no PR
;; checkout anywhere on disk, and the agent read the diff through the
;; `gh' API.  The `/tmp' the issue refers to is scratch space the PROMPT
;; tells the agent to `mktemp -d' (decknix-config
;; `commands/review-service-pr.md' 1.1.0), for per-run PR-context JSON so
;; parallel executors do not collide.  It was never a checkout.
;;
;; So this is not "swap /tmp for a worktree".  It is the first time a PR
;; head is checked out locally at all, which is what unblocks reviewing
;; the diff inside Emacs (#165 step 3) -- there was previously no working
;; tree to diff against.
;;
;; Design notes:
;;
;;   Sibling layout   `<primary>-worktrees/pr-<number>', the same
;;                    convention the worktree picker, registry and
;;                    cleanup transient already use, so none of them
;;                    need to special-case a review worktree.
;;
;;   pull/N/head      The head is fetched from the pull ref rather than
;;                    a branch name.  A fork's branch does not exist on
;;                    our origin, so `fetch origin <branch>' would fail
;;                    for exactly the PRs most worth reviewing.
;;
;;   --detach         A review reads someone else's commit.  Detaching
;;                    avoids minting a local branch that would then need
;;                    its own cleanup, and avoids colliding with the
;;                    author's branch if we already have it.
;;
;; Pure layer only -- path/args/decision.  The async `git' calls and the
;; session launch live in workspace-bulk per AGENTS.md Rule 2.

;;; Code:

(require 'subr-x)

;; ---------------------------------------------------------------------------
;; Path derivation
;; ---------------------------------------------------------------------------

(defun decknix--review-worktree-path (primary number)
  "Return the review worktree path for PRIMARY checkout and PR NUMBER.

Layout `<primary-parent>/<primary-basename>-worktrees/pr-<number>',
matching `decknix--sb-act-wt-sibling-path'.  NUMBER may be an integer or
a string (the URL parser yields strings).  Nil when either input is
missing, so a caller with no local clone gets nil rather than a
malformed path."
  (when (and primary number)
    (let* ((primary (directory-file-name (expand-file-name primary)))
           (parent (file-name-directory primary))
           (base (file-name-nondirectory primary)))
      (expand-file-name
       (concat base "-worktrees/pr-" (format "%s" number))
       parent))))

(defun decknix--review-worktree-own-path-p (path)
  "Return non-nil when PATH is a review worktree this module may prune.

Requires both the `-worktrees' parent and a `pr-<number>' basename.  The
prune runs automatically when a review is submitted, so it must be
incapable of removing a feature worktree the user is working in."
  (when (and path (stringp path))
    (let* ((clean (directory-file-name (expand-file-name path)))
           (base (file-name-nondirectory clean))
           (parent (directory-file-name
                    (or (file-name-directory clean) ""))))
      (and (string-match-p "\\`pr-[0-9]+\\'" base)
           (string-match-p "-worktrees\\'" parent)
           t))))

;; ---------------------------------------------------------------------------
;; Git argument vectors
;; ---------------------------------------------------------------------------

(defun decknix--review-worktree-fetch-args (number)
  "Return `git' args fetching PR NUMBER's head into FETCH_HEAD."
  (list "fetch" "origin" (format "pull/%s/head" number)))

(defun decknix--review-worktree-add-args (path)
  "Return `git' args adding a detached worktree at PATH on FETCH_HEAD."
  (list "worktree" "add" "--detach" (expand-file-name path) "FETCH_HEAD"))

(defun decknix--review-worktree-remove-args (path &optional force)
  "Return `git' args removing the worktree at PATH; FORCE overrides guards."
  (append (list "worktree" "remove")
          (when force (list "--force"))
          (list (expand-file-name path))))

;; ---------------------------------------------------------------------------
;; Decisions
;; ---------------------------------------------------------------------------

(defun decknix--review-worktree-plan (primary number &optional exists-fn)
  "Return (ACTION . PATH) for reviewing PR NUMBER against PRIMARY.

ACTION is one of:
  `no-clone'  PRIMARY is nil -- there is no local checkout to hang a
              worktree off, so the caller keeps the old workspace-root
              behaviour rather than failing the review outright.
  `reuse'     the worktree already exists (a re-review of the same PR).
              `git worktree add' errors on an existing path, so without
              this the re-request-review flow would break.
  `create'    it does not exist yet.

EXISTS-FN is a one-argument predicate on the candidate path, injected so
the decision is testable without touching the filesystem; defaults to
`file-directory-p'."
  (let ((path (decknix--review-worktree-path primary number))
        (exists-fn (or exists-fn #'file-directory-p)))
    (cond
     ((null path) (cons 'no-clone nil))
     ((funcall exists-fn path) (cons 'reuse path))
     (t (cons 'create path)))))

(defun decknix--review-worktree-prunable-p (path dirty-p sessions)
  "Return non-nil when the review worktree at PATH is safe to remove.

DIRTY-P is whether the worktree has uncommitted changes; SESSIONS is the
list of sessions still rooted there (see
`decknix--sb-act-wt-sessions-using').  Either one blocks removal: dirty
means the reviewer left edits worth keeping, in-use means a live or
saved session would be stranded pointing at a vanished directory.

Restates the interlock the manual worktree cleanup already enforces, so
the automatic post-submit prune cannot bypass it."
  (and path
       (not dirty-p)
       (null sessions)
       t))

(provide 'decknix-agent-review-worktree)
;;; decknix-agent-review-worktree.el ends here
