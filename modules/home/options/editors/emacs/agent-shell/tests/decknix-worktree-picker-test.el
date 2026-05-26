;;; decknix-worktree-picker-test.el --- Tests for worktree picker -*- lexical-binding: t -*-

(require 'ert)
(require 'decknix-worktree-picker)
(require 'decknix-test-helpers)

(ert-deftest decknix-worktree-picker-list-entries--mocked ()
  "Test that list entries join registry data with PR state.
The hub WIP payload uses the canonical
((updated . T) (repos . (((repo . R) (prs . (PR ...))) ...)))
shape -- the worktree picker must traverse repos -> prs to
build its (repo . branch) -> state map, NOT iterate
decknix--hub-wip as if it were a flat PR list (which would
feed (updated . T) to assoc and raise listp)."
  (let ((decknix--hub-worktree-cache (make-hash-table :test 'equal))
        (decknix--hub-wip
         '((updated . "2026-05-26T00:00:00Z")
           (repos . (((repo . "owner/repo")
                      (prs . (((number . 42)
                               (branch . "feature/foo")
                               (state . "merged"))))))))))
    (puthash "owner/repo" '(:primary "/tmp/repo" :worktrees (("feature/foo" . "/tmp/repo-worktrees/feature/foo"))) decknix--hub-worktree-cache)
    
    ;; Mock shell-command-to-string to return audit JSON
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_)
                 (json-encode
                  (list
                   '((repo . "owner/repo")
                     (primary . "/tmp/repo")
                     (stale . nil)
                     (worktrees . (((branch . "feature/foo")
                                    (path . "/tmp/repo-worktrees/feature/foo")
                                    (dirty . nil)
                                    (orphan . nil)
                                    (active . nil)
                                    (merged . t)
                                    (age_days . 3))))))))))
      (let ((entries (decknix-worktree-picker-list-entries)))
        (should (= (length entries) 1))
        (let* ((entry (car entries))
               (id (car entry))
               (cols (cadr entry)))
          (should (equal (nth 0 id) "owner/repo"))
          (should (equal (nth 1 id) "feature/foo"))
          (should (string-match-p "✓" (aref cols 2)))
          (should (string-match-p "merged" (aref cols 3)))
          (should (equal (aref cols 4) "3d")))))))

(ert-deftest decknix-worktree-picker--get-pr-map--canonical-shape ()
  "--get-pr-map must traverse repos -> prs, not iterate hub-wip.
Regression test for the listp error raised when the function fed
the leading (updated . T) cons to assoc as if it were a PR."
  (let ((decknix--hub-wip
         '((updated . "2026-05-26T00:00:00Z")
           (repos . (((repo . "o/r1")
                      (prs . (((branch . "main")  (state . "open"))
                              ((branch . "feat")  (state . "merged")))))
                     ((repo . "o/r2")
                      (prs . (((branch . "dev")   (state . "closed"))))))))))
    (let ((m (decknix-worktree-picker--get-pr-map)))
      (should (equal (gethash (cons "o/r1" "main") m) "open"))
      (should (equal (gethash (cons "o/r1" "feat") m) "merged"))
      (should (equal (gethash (cons "o/r2" "dev")  m) "closed")))))

(ert-deftest decknix-worktree-picker--get-pr-map--normalizes-repo-case ()
  "PR-map keys must be normalised to lowercase so that audit data
\(which surfaces repos as `upsiderealty/foo') matches hub-wip
data (which preserves the GitHub casing `UpsideRealty/foo').
Without normalisation every PR-map lookup misses and the picker
shows `none' for every row."
  (let ((decknix--hub-wip
         '((updated . "2026-05-26T00:00:00Z")
           (repos . (((repo . "UpsideRealty/proptrack-integration")
                      (prs . (((branch . "feature/x") (state . "open"))))))))))
    (let ((m (decknix-worktree-picker--get-pr-map)))
      (should (equal (gethash (cons "upsiderealty/proptrack-integration"
                                    "feature/x")
                              m)
                     "open")))))

(ert-deftest decknix-worktree-picker-list-entries--mixed-case-repo-state ()
  "Joining audit (lowercase repo) with hub-wip (mixed case) must
populate the PR State column with the lowercase state, not the
`-' fallback used when no PR is associated."
  (let ((decknix--hub-worktree-cache (make-hash-table :test 'equal))
        (decknix--hub-wip
         '((updated . "2026-05-26T00:00:00Z")
           (repos . (((repo . "UpsideRealty/trademe-integration")
                      (prs . (((branch . "feature/foo") (state . "open"))))))))))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_)
                 (json-encode
                  (list
                   '((repo . "upsiderealty/trademe-integration")
                     (primary . "/tmp/tm")
                     (stale . nil)
                     (worktrees . (((branch . "feature/foo")
                                    (path . "/tmp/tm-wt/feature/foo")
                                    (dirty . nil)
                                    (orphan . nil)
                                    (active . nil)
                                    (merged . nil)
                                    (age_days . 1))))))))))
      (let ((entries (decknix-worktree-picker-list-entries)))
        (should (= (length entries) 1))
        (let ((cols (cadr (car entries))))
          (should (string-match-p "open" (aref cols 3))))))))

(ert-deftest decknix-worktree-picker-list-entries--no-pr-uses-dash ()
  "When no PR exists for a (repo, branch) the PR State column
should show `-', not the legacy `none' placeholder."
  (let ((decknix--hub-worktree-cache (make-hash-table :test 'equal))
        (decknix--hub-wip '((updated . "x") (repos . ()))))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_)
                 (json-encode
                  (list
                   '((repo . "owner/repo")
                     (primary . "/tmp/r")
                     (stale . nil)
                     (worktrees . (((branch . "feature/orphan-wt")
                                    (path . "/tmp/r-wt/feature/orphan-wt")
                                    (dirty . nil)
                                    (orphan . nil)
                                    (active . nil)
                                    (merged . t)
                                    (age_days . 4))))))))))
      (let ((entries (decknix-worktree-picker-list-entries)))
        (should (= (length entries) 1))
        (let ((cols (cadr (car entries))))
          (should (string-match-p "\\`-\\'"
                                  (substring-no-properties (aref cols 3))))
          (should-not (string-match-p "none"
                                      (substring-no-properties (aref cols 3)))))))))

(ert-deftest decknix-worktree-picker-list-entries--closed-state-is-lowercase ()
  "The closed filter must trip on the lowercase `closed' state
emitted by the hub adapter; the legacy `CLOSED' comparison
silently misses every real-world PR."
  (let ((decknix--hub-worktree-cache (make-hash-table :test 'equal))
        (decknix--hub-wip
         '((updated . "x")
           (repos . (((repo . "owner/repo")
                      (prs . (((branch . "feature/bar") (state . "closed"))))))))))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_)
                 (json-encode
                  (list
                   '((repo . "owner/repo")
                     (primary . "/tmp/r")
                     (stale . nil)
                     (worktrees . (((branch . "feature/bar")
                                    (path . "/tmp/r-wt/feature/bar")
                                    (dirty . nil)
                                    (orphan . nil)
                                    (active . nil)
                                    (merged . nil)
                                    (age_days . 5))))))))))
      ;; Only the closed filter is active; all others off.  The row must
      ;; still show up, proving the lowercase state was matched.
      (let ((decknix-worktree-picker--filter-merged nil)
            (decknix-worktree-picker--filter-closed t)
            (decknix-worktree-picker--filter-no-session nil)
            (decknix-worktree-picker--filter-dirty nil)
            (decknix-worktree-picker--filter-orphans nil)
            (decknix-worktree-picker--filter-repo nil)
            (decknix-worktree-picker--filter-min-age nil))
        (let ((entries (decknix-worktree-picker-list-entries)))
          (should (= (length entries) 1)))))))

(ert-deftest decknix-worktree-picker-list-entries--filter-by-repo ()
  "When `decknix-worktree-picker--filter-repo' is set to a
substring, only worktrees whose repo contains that substring
\(case-insensitive) survive the filter."
  (let ((decknix--hub-worktree-cache (make-hash-table :test 'equal))
        (decknix--hub-wip '((updated . "x") (repos . ()))))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_)
                 (json-encode
                  (list
                   '((repo . "owner/alpha")
                     (primary . "/tmp/a") (stale . nil)
                     (worktrees . (((branch . "main") (path . "/tmp/a")
                                    (dirty . nil) (orphan . nil) (active . nil)
                                    (merged . nil) (age_days . 1)))))
                   '((repo . "owner/beta")
                     (primary . "/tmp/b") (stale . nil)
                     (worktrees . (((branch . "main") (path . "/tmp/b")
                                    (dirty . nil) (orphan . nil) (active . nil)
                                    (merged . nil) (age_days . 1))))))))))
      (let ((decknix-worktree-picker--filter-merged nil)
            (decknix-worktree-picker--filter-closed nil)
            (decknix-worktree-picker--filter-no-session t)
            (decknix-worktree-picker--filter-dirty nil)
            (decknix-worktree-picker--filter-orphans nil)
            (decknix-worktree-picker--filter-repo "ALPHA")
            (decknix-worktree-picker--filter-min-age nil))
        (let ((entries (decknix-worktree-picker-list-entries)))
          (should (= (length entries) 1))
          (should (equal (nth 0 (car (car entries))) "owner/alpha")))))))

(ert-deftest decknix-worktree-picker-list-entries--filter-by-min-age ()
  "When `decknix-worktree-picker--filter-min-age' is set to N,
only worktrees aged at least N days survive."
  (let ((decknix--hub-worktree-cache (make-hash-table :test 'equal))
        (decknix--hub-wip '((updated . "x") (repos . ()))))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_)
                 (json-encode
                  (list
                   '((repo . "owner/repo") (primary . "/tmp/r") (stale . nil)
                     (worktrees . (((branch . "fresh") (path . "/tmp/r/fresh")
                                    (dirty . nil) (orphan . nil) (active . nil)
                                    (merged . nil) (age_days . 1))
                                   ((branch . "old")   (path . "/tmp/r/old")
                                    (dirty . nil) (orphan . nil) (active . nil)
                                    (merged . nil) (age_days . 30))))))))))
      (let ((decknix-worktree-picker--filter-merged nil)
            (decknix-worktree-picker--filter-closed nil)
            (decknix-worktree-picker--filter-no-session t)
            (decknix-worktree-picker--filter-dirty nil)
            (decknix-worktree-picker--filter-orphans nil)
            (decknix-worktree-picker--filter-repo nil)
            (decknix-worktree-picker--filter-min-age 7))
        (let ((entries (decknix-worktree-picker-list-entries)))
          (should (= (length entries) 1))
          (should (equal (nth 1 (car (car entries))) "old")))))))

(ert-deftest decknix-worktree-picker--get-marked--returns-marked-ids ()
  "After marking rows with `m', `--get-marked' returns the IDs of
the tagged rows in document order.  Regression: the previous
implementation called `tabulated-list-get-tag', which is not a
real function in Emacs and raised `void-function' on `x'/`X'."
  (let ((decknix--hub-worktree-cache (make-hash-table :test 'equal))
        (decknix--hub-wip '((updated . "x") (repos . ()))))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_)
                 (json-encode
                  (list
                   '((repo . "owner/repo") (primary . "/tmp/r") (stale . nil)
                     (worktrees . (((branch . "a") (path . "/tmp/r/a")
                                    (dirty . nil) (orphan . nil) (active . nil)
                                    (merged . t) (age_days . 1))
                                   ((branch . "b") (path . "/tmp/r/b")
                                    (dirty . nil) (orphan . nil) (active . nil)
                                    (merged . t) (age_days . 2))
                                   ((branch . "c") (path . "/tmp/r/c")
                                    (dirty . nil) (orphan . nil) (active . nil)
                                    (merged . t) (age_days . 3))))))))))
      (with-temp-buffer
        (decknix-worktree-picker-mode)
        (tabulated-list-print)
        (goto-char (point-min))
        ;; Mark rows 1 and 3, leave row 2 unmarked.
        (decknix-worktree-picker-mark)   ; a (advances)
        (forward-line 1)                 ; skip b
        (decknix-worktree-picker-mark)   ; c
        (let ((marked (decknix-worktree-picker--get-marked)))
          (should (= (length marked) 2))
          (should (equal (nth 1 (nth 0 marked)) "a"))
          (should (equal (nth 1 (nth 1 marked)) "c")))))))

(ert-deftest decknix-worktree-picker--get-marked--empty-when-none-marked ()
  "With no rows tagged, `--get-marked' returns nil rather than
collecting every row by accident."
  (let ((decknix--hub-worktree-cache (make-hash-table :test 'equal))
        (decknix--hub-wip '((updated . "x") (repos . ()))))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_)
                 (json-encode
                  (list
                   '((repo . "owner/repo") (primary . "/tmp/r") (stale . nil)
                     (worktrees . (((branch . "a") (path . "/tmp/r/a")
                                    (dirty . nil) (orphan . nil) (active . nil)
                                    (merged . t) (age_days . 1))))))))))
      (with-temp-buffer
        (decknix-worktree-picker-mode)
        (tabulated-list-print)
        (should (null (decknix-worktree-picker--get-marked)))))))

(provide 'decknix-worktree-picker-test)
;;; decknix-worktree-picker-test.el ends here
