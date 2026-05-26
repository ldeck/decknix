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

(ert-deftest decknix-worktree-picker--age-sort--numeric-order ()
  "Age column must sort by the leading integer, not by string
comparison.  Lexicographically \"30d\" < \"3d\" (because \"0\" <
\"d\"), which buries the genuinely-oldest rows in the middle of
the list -- the opposite of what the user expects when sorting
worktrees by age."
  (let ((entries (list (list 'id1 (vector "r" "b1" "" "-" "30d"))
                       (list 'id2 (vector "r" "b2" "" "-" "3d"))
                       (list 'id3 (vector "r" "b3" "" "-" "5d")))))
    (let ((sorted (sort (copy-sequence entries)
                        #'decknix-worktree-picker--age-sort)))
      (should (equal (aref (cadr (nth 0 sorted)) 4) "3d"))
      (should (equal (aref (cadr (nth 1 sorted)) 4) "5d"))
      (should (equal (aref (cadr (nth 2 sorted)) 4) "30d")))))

(ert-deftest decknix-worktree-picker--max-widths--from-rendered-buffer ()
  "`--max-widths' must walk the printed buffer (not re-fetch the
audit JSON) and return the max display width per column, with
the column header acting as a floor so very narrow values do
not collapse the header label."
  (let ((decknix--hub-worktree-cache (make-hash-table :test 'equal))
        (decknix--hub-wip '((updated . "x") (repos . ()))))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_)
                 (json-encode
                  (list
                   '((repo . "owner/very-long-repo-name")
                     (primary . "/tmp/r") (stale . nil)
                     (worktrees . (((branch . "feat/much-longer-branch-than-the-default")
                                    (path . "/tmp/r/x") (dirty . nil)
                                    (orphan . nil) (active . nil)
                                    (merged . t) (age_days . 100))))))))))
      (with-temp-buffer
        (decknix-worktree-picker-mode)
        (tabulated-list-print)
        (let ((widths (decknix-worktree-picker--max-widths)))
          (should (>= (nth 0 widths) (length "owner/very-long-repo-name")))
          (should (>= (nth 1 widths)
                      (length "feat/much-longer-branch-than-the-default")))
          ;; Header floor: PR State header is wider than "-".
          (should (>= (nth 3 widths) (length "PR State")))
          (should (>= (nth 4 widths) (length "100d"))))))))

(ert-deftest decknix-worktree-picker-expand-all-columns--resizes-format ()
  "`expand-all-columns' must rewrite `tabulated-list-format' so
each column's width equals its widest rendered cell (or column
header, whichever is wider).  Mutating the literal vector
in-place would leak across buffers, so the new format must be a
fresh structure (`eq' to neither the original vector nor its
inner specs)."
  (let ((decknix--hub-worktree-cache (make-hash-table :test 'equal))
        (decknix--hub-wip '((updated . "x") (repos . ()))))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_)
                 (json-encode
                  (list
                   '((repo . "owner/very-long-repo-name")
                     (primary . "/tmp/r") (stale . nil)
                     (worktrees . (((branch . "feat/much-longer-branch")
                                    (path . "/tmp/r/x") (dirty . nil)
                                    (orphan . nil) (active . nil)
                                    (merged . t) (age_days . 100))))))))))
      (with-temp-buffer
        (decknix-worktree-picker-mode)
        (tabulated-list-print)
        (let ((original tabulated-list-format))
          (decknix-worktree-picker-expand-all-columns)
          (should-not (eq tabulated-list-format original))
          (should (>= (nth 1 (aref tabulated-list-format 0))
                      (length "owner/very-long-repo-name")))
          (should (>= (nth 1 (aref tabulated-list-format 1))
                      (length "feat/much-longer-branch")))
          (should (>= (nth 1 (aref tabulated-list-format 4))
                      (length "100d"))))))))

(ert-deftest decknix-worktree-picker-expand-column-at-point--resizes-one ()
  "`expand-column-at-point' must widen only the column at point
and leave the others untouched.  Without this, the user would
have to expand everything just to read one long branch name."
  (let ((decknix--hub-worktree-cache (make-hash-table :test 'equal))
        (decknix--hub-wip '((updated . "x") (repos . ()))))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_)
                 (json-encode
                  (list
                   '((repo . "owner/very-long-repo-name")
                     (primary . "/tmp/r") (stale . nil)
                     (worktrees . (((branch . "short")
                                    (path . "/tmp/r/x") (dirty . nil)
                                    (orphan . nil) (active . nil)
                                    (merged . t) (age_days . 1))))))))))
      (with-temp-buffer
        (decknix-worktree-picker-mode)
        (tabulated-list-print)
        (goto-char (point-min))
        ;; Position into the first column (Repo, after padding).
        (forward-char (1+ (or tabulated-list-padding 0)))
        (let ((orig-branch-w (nth 1 (aref tabulated-list-format 1))))
          (decknix-worktree-picker-expand-column-at-point)
          (should (>= (nth 1 (aref tabulated-list-format 0))
                      (length "owner/very-long-repo-name")))
          (should (= (nth 1 (aref tabulated-list-format 1))
                     orig-branch-w)))))))

(ert-deftest decknix-worktree-picker--menu-bar--exposes-dired-like-menus ()
  "The mode keymap must publish menu-bar entries so mouse users can
discover the available commands without consulting the docstring or
header-line.  Dired exposes Operate / Mark / Regexp / Immediate as
separate top-level menus; the worktree picker mirrors that pattern
with Operate / Mark / Filter / View."
  (let ((map decknix-worktree-picker-mode-map))
    (dolist (key '(operate mark filter view))
      (let ((entry (lookup-key map (vector 'menu-bar key))))
        (should (keymapp entry))))))

(ert-deftest decknix-worktree-picker--menu-bar--wires-destructive-verbs ()
  "The Operate menu must surface the destructive verbs (prune and
remove) by name -- not by the cryptic `x'/`X' keys -- so a mouse
user can read the consequence before invoking it.  Guarding both
verbs catches the easy regression of dropping one (only `prune'
on the keymap, only `remove' on the menu, etc.)."
  (let* ((map decknix-worktree-picker-mode-map)
         (operate (lookup-key map [menu-bar operate]))
         (commands (let (acc)
                     (map-keymap
                      (lambda (_ev binding)
                        (let ((cmd (cond
                                    ((symbolp binding) binding)
                                    ;; menu-item form: (menu-item NAME CMD . PROPS)
                                    ((and (consp binding)
                                          (eq (car binding) 'menu-item))
                                     (nth 2 binding))
                                    ;; legacy form: (NAME . CMD)
                                    ((and (consp binding)
                                          (symbolp (cdr binding)))
                                     (cdr binding)))))
                          (when cmd (push cmd acc))))
                      operate)
                     acc)))
    (should (memq 'decknix-worktree-picker-prune commands))
    (should (memq 'decknix-worktree-picker-remove commands))))

(provide 'decknix-worktree-picker-test)
;;; decknix-worktree-picker-test.el ends here
