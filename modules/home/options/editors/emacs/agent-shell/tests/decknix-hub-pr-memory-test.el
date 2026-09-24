;;; decknix-hub-pr-memory-test.el --- Tests for branch to PR memory -*- lexical-binding: t -*-

;;; Commentary:
;;
;; A merged worktree rendered as a dim `wip' row with no `#N' and no
;; actionable URL, because `decknix--hub-wip-placeholder-rows' selects
;; worktrees "lacking a matching OPEN PR" and cannot tell "never had one"
;; from "had one that merged".
;;
;; The pure layers are tested here per AGENTS.md Rule 2.  The harvest
;; fixture is shaped like the real feed (repos -> prs) so a change to that
;; shape fails here rather than silently emptying the memory.

;;; Code:

(require 'ert)
(require 'decknix-hub-pr-memory)

(defconst decknix-pr-memory-test--feed
  '((repos . (((repo . "nc-helix/platform-cli")
               (prs . (((number . 41) (branch . "CONN-539-jlink")
                        (url . "https://github.com/nc-helix/platform-cli/pull/41")
                        (state . "OPEN"))
                       ((number . 44) (branch . "CONN-828-nix")
                        (url . "https://github.com/nc-helix/platform-cli/pull/44")
                        (state . "OPEN")))))
              ((repo . "UpsideRealty/upside")
               (prs . (((number . 210) (branch . "NC-8784-reinz")
                        (url . "https://github.com/UpsideRealty/upside/pull/210")
                        (state . "OPEN"))))))))
  "A WIP feed in the real shape, including mixed-case owner/repo.")

;; --- keying -----------------------------------------------------------

(ert-deftest decknix-pr-memory-key--canonicalises-repo-case ()
  "Repo case is normalised; branch case is NOT.

`gh search prs' may return mixed casing for `owner/repo' while the
worktree registry stores lowercase, which is why
`decknix--hub-wip-placeholder-rows' already lowercases for its dedup.
Branch names are case-sensitive on GitHub and must not be folded."
  (should (equal (decknix--hub-pr-memory-key "UpsideRealty/upside" "NC-1")
                 (decknix--hub-pr-memory-key "upsiderealty/upside" "NC-1")))
  (should-not (equal (decknix--hub-pr-memory-key "a/b" "Branch")
                     (decknix--hub-pr-memory-key "a/b" "branch"))))

(ert-deftest decknix-pr-memory-key--rejects-incomplete-input ()
  "A key needs both halves; a half key would collide across branches."
  (should-not (decknix--hub-pr-memory-key nil "b"))
  (should-not (decknix--hub-pr-memory-key "a/b" nil))
  (should-not (decknix--hub-pr-memory-key "" "b"))
  (should-not (decknix--hub-pr-memory-key "a/b" "")))

(ert-deftest decknix-pr-memory-key--separator-cannot-be-forged ()
  "The separator is not a legal branch character, so keys cannot alias.
With a `/' separator, repo `a/b' branch `c/d' and repo `a/b/c' branch `d'
would produce the same key."
  (should-not (equal (decknix--hub-pr-memory-key "a/b" "c/d")
                     (decknix--hub-pr-memory-key "a/b/c" "d"))))

;; --- harvest ----------------------------------------------------------

(ert-deftest decknix-pr-memory-harvest--reads-the-real-feed-shape ()
  "Every branch-carrying PR across every repo is harvested."
  (let ((got (decknix--hub-pr-memory-harvest decknix-pr-memory-test--feed 100)))
    (should (= 3 (length got)))
    (should (equal 41 (plist-get (cdr (car got)) :number)))
    (should (equal 100 (plist-get (cdr (car got)) :seen)))))

(ert-deftest decknix-pr-memory-harvest--skips-prs-without-branch-or-url ()
  "A row we could not act on is exactly what this module exists to stop."
  (let ((feed '((repos . (((repo . "a/b")
                           (prs . (((number . 1) (url . "u"))
                                   ((number . 2) (branch . "br"))
                                   ((number . 3) (branch . "ok") (url . "u3"))))))))))
    (let ((got (decknix--hub-pr-memory-harvest feed 0)))
      (should (= 1 (length got)))
      (should (equal 3 (plist-get (cdar got) :number))))))

(ert-deftest decknix-pr-memory-harvest--tolerates-an-empty-or-absent-feed ()
  "The sidebar renders before the first poll returns."
  (should-not (decknix--hub-pr-memory-harvest nil 0))
  (should-not (decknix--hub-pr-memory-harvest '((repos . nil)) 0)))

;; --- remember and lookup ----------------------------------------------

(ert-deftest decknix-pr-memory-remember--survives-the-pr-leaving-the-feed ()
  "The whole point: lookup still answers after the PR is no longer open.

The feed only ever carries OPEN PRs, so a merge is indistinguishable from
a disappearance.  Harvesting while it is open is what preserves the
number and URL for afterwards."
  (let ((decknix--hub-pr-memory (make-hash-table :test 'equal)))
    (should (= 3 (decknix--hub-pr-memory-remember
                  decknix-pr-memory-test--feed 100)))
    ;; The PR merges: the next poll simply does not mention it.
    (decknix--hub-pr-memory-remember '((repos . nil)) 200)
    (let ((entry (decknix--hub-pr-memory-lookup
                  "nc-helix/platform-cli" "CONN-539-jlink")))
      (should entry)
      (should (equal 41 (plist-get entry :number)))
      (should (equal "https://github.com/nc-helix/platform-cli/pull/41"
                     (plist-get entry :url))))))

(ert-deftest decknix-pr-memory-lookup--matches-registry-lowercase ()
  "The worktree registry stores lowercase; the feed gave mixed case."
  (let ((decknix--hub-pr-memory (make-hash-table :test 'equal)))
    (decknix--hub-pr-memory-remember decknix-pr-memory-test--feed 0)
    (should (decknix--hub-pr-memory-lookup "upsiderealty/upside" "NC-8784-reinz"))))

(ert-deftest decknix-pr-memory-remember--overwrites-a-reused-branch ()
  "A new PR on the same branch replaces the old association."
  (let ((decknix--hub-pr-memory (make-hash-table :test 'equal)))
    (decknix--hub-pr-memory-remember
     '((repos . (((repo . "a/b") (prs . (((number . 1) (branch . "br")
                                          (url . "u1")))))))) 0)
    (decknix--hub-pr-memory-remember
     '((repos . (((repo . "a/b") (prs . (((number . 9) (branch . "br")
                                          (url . "u9")))))))) 1)
    (should (equal 9 (plist-get (decknix--hub-pr-memory-lookup "a/b" "br")
                                :number)))))

(ert-deftest decknix-pr-memory-lookup--unknown-branch-is-nil ()
  "A branch that never had a PR must not invent one."
  (let ((decknix--hub-pr-memory (make-hash-table :test 'equal)))
    (should-not (decknix--hub-pr-memory-lookup "a/b" "never-had-a-pr"))))

;; --- the state word ---------------------------------------------------

(ert-deftest decknix-pr-memory-label--no-memory-is-the-only-wip ()
  "`wip' is reserved for a branch not yet promoted to a PR.
This is the whole point of the spec: `wip' stopped meaning one thing."
  (should (equal "wip" (decknix--hub-pr-memory-row-label nil nil)))
  (should (equal "wip" (decknix--hub-pr-memory-row-label nil '((state . "MERGED"))))))

(ert-deftest decknix-pr-memory-label--memory-without-status-is-explicit ()
  "A known PR whose state has not loaded says so, rather than lying.
Reporting `wip' here would recreate the bug, and reporting `merged' would
guess."
  (should (equal "pr ?" (decknix--hub-pr-memory-row-label '(:number 41) nil))))

(ert-deftest decknix-pr-memory-label--defers-to-the-existing-vocabulary ()
  "No new words: `decknix--hub-format-row-label' decides.
Pinned so the placeholder path cannot drift from real WIP rows."
  (cl-letf (((symbol-function 'decknix--hub-format-row-label)
             (lambda (pr) (concat "V:" (alist-get 'state pr)))))
    (should (equal "V:MERGED"
                   (decknix--hub-pr-memory-row-label
                    '(:number 41) '((state . "MERGED")))))))

;; --- visibility -------------------------------------------------------

(ert-deftest decknix-pr-memory-visible--local-branch-always-shows ()
  "No remembered PR means local work, which no terminal filter governs."
  (should (decknix--hub-pr-memory-row-visible-p nil nil)))

(ert-deftest decknix-pr-memory-visible--reuses-the-deploy-gated-rule ()
  "A remembered merged PR obeys the SAME rule as a real merged WIP row.
Open question 2 of the spec: a second visibility rule would drift from
`decknix--hub-wip-terminal-visible-p' rather than track it."
  (cl-letf (((symbol-function 'decknix--hub-wip-terminal-visible-p)
             (lambda (_pr &optional _d) 'delegated)))
    (should (eq 'delegated (decknix--hub-pr-memory-row-visible-p
                            '(:number 41) '((state . "MERGED")))))))

(ert-deftest decknix-pr-memory-visible--unresolved-status-still-shows ()
  "Never hide a row because its state has not loaded yet."
  (should (decknix--hub-pr-memory-row-visible-p '(:number 41) nil)))

(provide 'decknix-hub-pr-memory-test)
;;; decknix-hub-pr-memory-test.el ends here
