;;; decknix-agent-review-worktree-test.el --- Tests for review worktrees -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification tests for ldeck/decknix#165 step 1: a PR review session
;; runs in a real git worktree checked out at the PR head, instead of the
;; workspace root.
;;
;; Grounding note, measured before this was written: reviews did NOT run
;; in `/tmp' as the issue body claimed.  They ran in the WORKSPACE ROOT
;; (`/Users/ldeck/Code/nurturecloud/'), with no PR checkout anywhere --
;; the agent read the diff through the `gh' API.  The `/tmp' in the issue
;; is agent scratch space created by the prompt in `decknix-config', not
;; by decknix.  So this is not "swap /tmp for a worktree"; it is the
;; first checkout of a PR head that has ever existed here.
;;
;; Only the pure layer is tested: path derivation, the git argument
;; vectors, and the reuse-vs-create decision.  The async process wiring
;; lives in workspace-bulk per AGENTS.md Rule 2.

;;; Code:

(require 'ert)
(require 'decknix-agent-review-worktree)

;; ---------------------------------------------------------------------
;; Path derivation
;; ---------------------------------------------------------------------

(ert-deftest decknix-review-wt--path-follows-the-sibling-convention ()
  "The review worktree is a sibling of the primary checkout.

Same `<primary>-worktrees/<name>' layout the rest of decknix uses (and
that AGENTS.md mandates), so the worktree picker, the registry and the
cleanup transient all see it without special-casing."
  (should (equal (decknix--review-worktree-path "/Users/x/Code/org/myrepo" 453)
                 "/Users/x/Code/org/myrepo-worktrees/pr-453")))

(ert-deftest decknix-review-wt--path-tolerates-a-trailing-slash ()
  "A primary path with a trailing slash must not produce an empty basename."
  (should (equal (decknix--review-worktree-path "/Users/x/Code/org/myrepo/" 12)
                 "/Users/x/Code/org/myrepo-worktrees/pr-12")))

(ert-deftest decknix-review-wt--path-accepts-a-string-number ()
  "PR numbers arrive from the URL parser as strings."
  (should (equal (decknix--review-worktree-path "/r/repo" "7")
                 "/r/repo-worktrees/pr-7")))

(ert-deftest decknix-review-wt--path-needs-both-arguments ()
  "Missing inputs yield nil rather than a malformed path."
  (should-not (decknix--review-worktree-path nil 1))
  (should-not (decknix--review-worktree-path "/r/repo" nil)))

;; ---------------------------------------------------------------------
;; Git argument vectors
;; ---------------------------------------------------------------------

(ert-deftest decknix-review-wt--fetch-args ()
  "The PR head is fetched from the pull ref, which needs no local branch.

`pull/N/head' is readable by anyone who can read the repo, including for
forks -- so this works where `git fetch origin <branch>' would not,
because a fork's branch does not exist on our origin."
  (should (equal (decknix--review-worktree-fetch-args 453)
                 '("fetch" "origin" "pull/453/head"))))

(ert-deftest decknix-review-wt--add-args-are-detached ()
  "The worktree is checked out DETACHED at the fetched head.

A review is a read of someone else's commit, not a branch we own.
Detaching avoids creating a local branch that would then need pruning,
and avoids colliding with the author's branch name if we already have
it."
  (should (equal (decknix--review-worktree-add-args "/w/repo-worktrees/pr-9")
                 '("worktree" "add" "--detach" "/w/repo-worktrees/pr-9" "FETCH_HEAD"))))

(ert-deftest decknix-review-wt--remove-args ()
  "Removal is plain `worktree remove'; FORCE only when asked."
  (should (equal (decknix--review-worktree-remove-args "/w/repo-worktrees/pr-9" nil)
                 '("worktree" "remove" "/w/repo-worktrees/pr-9")))
  (should (equal (decknix--review-worktree-remove-args "/w/repo-worktrees/pr-9" t)
                 '("worktree" "remove" "--force" "/w/repo-worktrees/pr-9"))))

;; ---------------------------------------------------------------------
;; Reuse-vs-create decision
;; ---------------------------------------------------------------------

(ert-deftest decknix-review-wt--plan-no-clone ()
  "Without a local primary checkout there is nothing to add a worktree to.
The caller falls back to the old workspace-root behaviour rather than
failing the review."
  (should (eq (car (decknix--review-worktree-plan nil 5 nil)) 'no-clone)))

(ert-deftest decknix-review-wt--plan-create-when-absent ()
  "A PR with no worktree yet is created, and the plan carries the path."
  (let ((plan (decknix--review-worktree-plan "/r/repo" 5 nil)))
    (should (eq (car plan) 'create))
    (should (equal (cdr plan) "/r/repo-worktrees/pr-5"))))

(ert-deftest decknix-review-wt--plan-reuses-an-existing-worktree ()
  "Re-reviewing the same PR reuses its worktree instead of erroring.

`git worktree add' fails on an existing path, so without this a second
review of the same PR (the re-request-review flow) would break."
  (let ((plan (decknix--review-worktree-plan
               "/r/repo" 5 (lambda (p) (equal p "/r/repo-worktrees/pr-5")))))
    (should (eq (car plan) 'reuse))
    (should (equal (cdr plan) "/r/repo-worktrees/pr-5"))))

(ert-deftest decknix-review-wt--plan-is-per-pr ()
  "Two PRs in one repo get separate worktrees, so parallel reviews cannot
check out over each other."
  (should (equal (cdr (decknix--review-worktree-plan "/r/repo" 1 nil))
                 "/r/repo-worktrees/pr-1"))
  (should (equal (cdr (decknix--review-worktree-plan "/r/repo" 2 nil))
                 "/r/repo-worktrees/pr-2")))

;; ---------------------------------------------------------------------
;; Prune safety (step 2 groundwork)
;; ---------------------------------------------------------------------

(ert-deftest decknix-review-wt--prunable-only-when-clean-and-unused ()
  "A review worktree is pruned only when nothing would be lost.

Dirty means the reviewer left edits; in-use means a session is still
rooted there.  Either one blocks removal -- the interlock the existing
worktree cleanup already applies, restated here so the review path
cannot bypass it."
  (should (decknix--review-worktree-prunable-p "/w/pr-1" nil nil))
  (should-not (decknix--review-worktree-prunable-p "/w/pr-1" t nil))
  (should-not (decknix--review-worktree-prunable-p "/w/pr-1" nil '("conv-key")))
  (should-not (decknix--review-worktree-prunable-p "/w/pr-1" t '("conv-key"))))

(ert-deftest decknix-review-wt--prunable-needs-a-path ()
  "No path means nothing to prune."
  (should-not (decknix--review-worktree-prunable-p nil nil nil)))

(ert-deftest decknix-review-wt--only-prunes-review-worktrees ()
  "Only a `pr-N' worktree under a `-worktrees' parent is ever pruned.

The prune runs automatically on review submit, so it must never be able
to remove a feature worktree the user is working in."
  (should (decknix--review-worktree-own-path-p "/r/repo-worktrees/pr-42"))
  (should-not (decknix--review-worktree-own-path-p "/r/repo-worktrees/CONN-539-fix"))
  (should-not (decknix--review-worktree-own-path-p "/r/repo"))
  (should-not (decknix--review-worktree-own-path-p "/somewhere/pr-42"))
  (should-not (decknix--review-worktree-own-path-p nil)))

(provide 'decknix-agent-review-worktree-test)
;;; decknix-agent-review-worktree-test.el ends here
