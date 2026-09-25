;;; decknix-hub-wt-stale-test.el --- Tests for worktree staleness -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Pure layers per AGENTS.md Rule 2: the staleness predicate and the audit
;; parser.  The fixture mirrors `decknix wt audit --json' so a change to that
;; shape fails here rather than silently yielding no facts -- which would read
;; as "nothing is stale" and quietly stop hiding anything.

;;; Code:

(require 'ert)
(require 'decknix-hub-wt-stale)

;; --- the predicate ----------------------------------------------------

(ert-deftest decknix-wt-stale--merged-with-nothing-in-flight ()
  "A merged worktree with no session and no changes is safe to hide."
  (should (decknix--hub-wt-stale-p '(:merged t :orphan nil :active nil :dirty nil))))

(ert-deftest decknix-wt-stale--orphan-counts-too ()
  "An orphaned branch is stale even when never merged.
28 of 67 worktrees were orphan and 6 merged, so orphan is the larger case."
  (should (decknix--hub-wt-stale-p '(:merged nil :orphan t :active nil :dirty nil))))

(ert-deftest decknix-wt-stale--dirty-is-never-stale ()
  "Uncommitted work outranks a merged PR.
7 of 67 worktrees were dirty. Hiding one is how the work gets lost, so this
holds even though the PR is finished."
  (should-not (decknix--hub-wt-stale-p '(:merged t :orphan t :active nil :dirty t))))

(ert-deftest decknix-wt-stale--an-active-session-is-never-stale ()
  "A live session is the reason the worktree exists.
It outranks any PR state, including merged AND orphaned."
  (should-not (decknix--hub-wt-stale-p '(:merged t :orphan t :active t :dirty nil))))

(ert-deftest decknix-wt-stale--neither-merged-nor-orphan-stays ()
  "Work in progress is not stale."
  (should-not (decknix--hub-wt-stale-p '(:merged nil :orphan nil :active nil :dirty nil))))

(ert-deftest decknix-wt-stale--unknown-facts-are-shown ()
  "Nil facts mean unknown, and unknown must never hide a row.

A row the user can see is recoverable; a silently dropped one looks as though
it was already pruned. This is the same reason the PR-memory visibility rule
defaults to visible when nothing is remembered."
  (should-not (decknix--hub-wt-stale-p nil))
  (should-not (decknix--hub-wt-stale-p '())))

;; --- the hide gate ----------------------------------------------------

(ert-deftest decknix-wt-stale--toggle-off-shows-everything ()
  "With hiding disabled, even a provably stale worktree is listed."
  (let ((decknix--hub-wt-facts (make-hash-table :test 'equal))
        (decknix-hub-wt-hide-stale nil))
    (puthash "/w/gone" '(:merged t :orphan nil :active nil :dirty nil)
             decknix--hub-wt-facts)
    (should-not (decknix--hub-wt-hidden-p "/w/gone"))))

(ert-deftest decknix-wt-stale--hide-gate-uses-the-cache ()
  "A cached stale path is hidden; an uncached one is not."
  (let ((decknix--hub-wt-facts (make-hash-table :test 'equal))
        (decknix-hub-wt-hide-stale t))
    (puthash "/w/gone" '(:merged t :orphan nil :active nil :dirty nil)
             decknix--hub-wt-facts)
    (should (decknix--hub-wt-hidden-p "/w/gone"))
    (should-not (decknix--hub-wt-hidden-p "/w/never-audited"))
    (should-not (decknix--hub-wt-hidden-p nil))))

;; --- the parser -------------------------------------------------------

(defconst decknix-wt-stale-test--audit
  "[{\"repo\":\"upsiderealty/ai-cs-developer-setup\",
      \"primary\":\"/Code/nc/ai-cs-developer-setup\",
      \"worktrees\":[
        {\"branch\":\"flake-outputs\",\"path\":\"/Code/nc/ai-cs-worktrees/flake-outputs\",
         \"merged\":true,\"orphan\":false,\"active\":false,\"dirty\":false,\"age_days\":1},
        {\"branch\":\"main\",\"path\":\"/Code/nc/ai-cs-developer-setup\",
         \"merged\":false,\"orphan\":false,\"active\":false,\"dirty\":false,\"age_days\":1}]}]"
  "An audit payload shaped like the real one, including the repo's primary.")

(ert-deftest decknix-wt-parse--reads-worktrees-and-skips-the-primary ()
  "The primary checkout is not a prune candidate and is excluded.
The audit reports it alongside the worktrees, which is what put 9 primary
checkouts into the picker."
  (let ((facts (decknix--hub-wt-parse-audit decknix-wt-stale-test--audit)))
    (should (= 1 (length facts)))
    (should (equal (expand-file-name "/Code/nc/ai-cs-worktrees/flake-outputs")
                   (car (car facts))))
    (should (plist-get (cdr (car facts)) :merged))))

(ert-deftest decknix-wt-parse--json-false-becomes-nil ()
  "JSON false must not read as truthy.
`:false-object nil' does the work, and this pins it: a truthy `dirty' would
make every worktree permanently unhideable."
  (let* ((facts (decknix--hub-wt-parse-audit decknix-wt-stale-test--audit))
         (wt (cdr (car facts))))
    (should-not (plist-get wt :dirty))
    (should-not (plist-get wt :active))
    (should (decknix--hub-wt-stale-p wt))))

(ert-deftest decknix-wt-parse--garbage-yields-no-facts ()
  "Unparseable output is no facts, which shows every row.
Returning facts on a failed audit would hide rows on bad data."
  (should-not (decknix--hub-wt-parse-audit "not json"))
  (should-not (decknix--hub-wt-parse-audit ""))
  (should-not (decknix--hub-wt-parse-audit "[]")))

(ert-deftest decknix-wt-stale-paths--lists-only-the-stale ()
  "The bulk-prune source excludes dirty and active worktrees."
  (let ((decknix--hub-wt-facts (make-hash-table :test 'equal)))
    (puthash "/w/merged" '(:merged t :orphan nil :active nil :dirty nil)
             decknix--hub-wt-facts)
    (puthash "/w/dirty" '(:merged t :orphan nil :active nil :dirty t)
             decknix--hub-wt-facts)
    (puthash "/w/live" '(:merged t :orphan nil :active t :dirty nil)
             decknix--hub-wt-facts)
    (puthash "/w/busy" '(:merged nil :orphan nil :active nil :dirty nil)
             decknix--hub-wt-facts)
    (should (equal '("/w/merged") (decknix-hub-wt-stale-paths)))))

(ert-deftest decknix-wt-parse--primary-match-ignores-a-trailing-slash ()
  "The audit writes `primary' with a trailing slash and the path without.

Measured on the real audit: `experiment-decknix-config' reports primary
\"/Code/nc/decknix-config/\" against worktree path \"/Code/nc/decknix-config\".
`expand-file-name' does not normalise that, so a plain string compare treated
a primary checkout as prunable -- and being merged, clean and sessionless, it
would have been HIDDEN from the sidebar."
  (let ((facts (decknix--hub-wt-parse-audit
                "[{\"repo\":\"r\",\"primary\":\"/Code/nc/decknix-config/\",
                   \"worktrees\":[{\"branch\":\"main\",\"path\":\"/Code/nc/decknix-config\",
                     \"merged\":true,\"orphan\":false,\"active\":false,\"dirty\":false}]}]")))
    (should-not facts)))


(provide 'decknix-hub-wt-stale-test)
;;; decknix-hub-wt-stale-test.el ends here
