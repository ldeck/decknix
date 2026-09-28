;;; decknix-worktree-picker-test.el --- Tests for worktree picker -*- lexical-binding: t -*-

(require 'ert)
(require 'decknix-worktree-picker)

;; `list-entries' used to shell out; it now reads the async cache via
;; `--audit-report'. The tests below stub `shell-command-to-string' to supply
;; an audit payload, which is still the clearest way to drive them, so the seam
;; is pointed back at that stub here. The cache path itself is covered by
;; `decknix-wtp-audit-report--reads-the-cache' below, since that is the part
;; production actually uses.
(defun decknix-worktree-picker--audit-report ()
  "Test shim: parse whatever `shell-command-to-string' yields."
  (json-parse-string (shell-command-to-string "decknix wt audit --json")
                     :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))


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


;;; decknix-worktree-picker-test.el ends here

;; -- primary checkout detection ---------------------------------------
;;
;; `decknix wt audit --json' reports a repo's `primary' alongside its
;; worktrees, so the picker listed main working trees as prune candidates:
;; 9 of 21 rows on 2026-09-25, including /Users/ldeck/tools/decknix and
;; two service checkouts on `main'. Marking one and pruning attempted
;; `git worktree remove' on a main working tree.

(ert-deftest decknix-wt-primary--matches-the-repos-primary ()
  "The primary checkout is identified by path, not by name."
  (should (decknix-worktree-picker--primary-p
           "/Users/ldeck/tools/decknix" "/Users/ldeck/tools/decknix"))
  (should (decknix-worktree-picker--primary-p
           "/Users/ldeck/tools/decknix/" "/Users/ldeck/tools/decknix")))

(ert-deftest decknix-wt-primary--a-sibling-worktree-is-not-primary ()
  "A worktree beside the primary, sharing its name prefix, is not primary.

decknix has `decknix-spec-sidebar-ret' beside `decknix', so a prefix or
name heuristic would mislabel it. It is also why the `-worktrees/' path
convention cannot be used as the test: real worktrees do not all follow
it."
  (should-not (decknix-worktree-picker--primary-p
               "/Users/ldeck/tools/decknix-spec-sidebar-ret"
               "/Users/ldeck/tools/decknix")))

(ert-deftest decknix-wt-primary--conventional-worktree-is-not-primary ()
  "A worktree under `<repo>-worktrees/' is not the primary."
  (should-not (decknix-worktree-picker--primary-p
               "/Users/ldeck/Code/nurturecloud/connect-to-core-worktrees/flake-outputs"
               "/Users/ldeck/Code/nurturecloud/connect-to-core")))

(ert-deftest decknix-wt-primary--missing-or-blank-input-is-not-primary ()
  "Absent data must not cause a row to be treated as the primary.
Hiding a real worktree is worse than showing a primary: the user can see
the latter, but a silently dropped row looks like it was already pruned."
  (should-not (decknix-worktree-picker--primary-p nil "/a"))
  (should-not (decknix-worktree-picker--primary-p "/a" nil))
  (should-not (decknix-worktree-picker--primary-p "/a" "")))

;; -- primary-branch rows ----------------------------------------------
;;
;; Distinct from the primary CHECKOUT: `decknix wt audit --json' reported 6
;; worktrees outside their repo's primary path but still tracking `main'
;; (nc-helix/helix, oneroof-integration, trademe-integration and others on
;; 2026-09-26). A primary branch is never a PR branch, so those rows are
;; noise in a PR-oriented listing, and hiding them needs a different test
;; than the path comparison.

(ert-deftest decknix-wt-primary-branch--recognises-the-usual-names ()
  "main, master and the other configured names all count."
  (should (decknix-worktree-picker--primary-branch-p "main"))
  (should (decknix-worktree-picker--primary-branch-p "master"))
  (should (decknix-worktree-picker--primary-branch-p "trunk")))

(ert-deftest decknix-wt-primary-branch--includes-development ()
  "`upside' defaults to `development', not `main'.
A two-name list would leave the monolith's checkouts unfilterable, which is
why this is a defcustom rather than a hardcoded pair."
  (should (decknix-worktree-picker--primary-branch-p "development"))
  (should (member "development" decknix-worktree-picker-primary-branches)))

(ert-deftest decknix-wt-primary-branch--is-case-insensitive ()
  "Branch case should not decide whether a row is filtered."
  (should (decknix-worktree-picker--primary-branch-p "Main"))
  (should (decknix-worktree-picker--primary-branch-p "MASTER")))

(ert-deftest decknix-wt-primary-branch--a-feature-branch-is-not-primary ()
  "A ticket branch must never be hidden by this filter."
  (should-not (decknix-worktree-picker--primary-branch-p "CONN-539-jlink"))
  (should-not (decknix-worktree-picker--primary-branch-p "flake-outputs"))
  (should-not (decknix-worktree-picker--primary-branch-p "main-ish"))
  (should-not (decknix-worktree-picker--primary-branch-p "feature/main")))

(ert-deftest decknix-wt-primary-branch--respects-the-custom-list ()
  "Rebinding the list changes what is treated as primary."
  (let ((decknix-worktree-picker-primary-branches '("release")))
    (should (decknix-worktree-picker--primary-branch-p "release"))
    (should-not (decknix-worktree-picker--primary-branch-p "main"))))

(ert-deftest decknix-wt-primary-branch--degenerate-input ()
  "A nil branch is not primary."
  (should-not (decknix-worktree-picker--primary-branch-p nil))
  (should-not (decknix-worktree-picker--primary-branch-p "")))


(ert-deftest decknix-wtp-audit-report--reads-the-cache ()
  "The real `--audit-report' groups cached rows, with no subprocess.

A synchronous `decknix wt audit --json' per paint froze Emacs, and every
filter toggle goes through `revert-buffer', so each keystroke paid for
another one. `shell-command-to-string' is made to error here so a
regression back to shelling out fails loudly rather than just being slow."
  (let ((decknix--hub-wt-facts (make-hash-table :test 'equal))
        (decknix--hub-wt-facts-ts (float-time)))
    (puthash "/w/a" '(:repo "o/r" :branch "br-a" :path "/w/a"
                      :merged t :orphan nil :active nil :dirty nil :age 3)
             decknix--hub-wt-facts)
    (puthash "/w/b" '(:repo "o/r" :branch "br-b" :path "/w/b"
                      :merged nil :orphan t :active nil :dirty nil :age 9)
             decknix--hub-wt-facts)
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (&rest _) (error "audit must not shell out")))
              ((symbol-function 'decknix-worktree-picker--audit-report)
               (symbol-function 'decknix-worktree-picker--audit-report-real)))
      (let* ((report (decknix-worktree-picker--audit-report-real))
             (wts (alist-get 'worktrees (car report))))
        (should (= 1 (length report)))
        (should (equal "o/r" (alist-get 'repo (car report))))
        (should (= 2 (length wts)))))))


;; -- PR state falls back to the remembered PR -------------------------
;;
;; The map is built from `github-wip.json', which carries OPEN PRs only, so
;; the column was empty for most rows: a worktree usually outlives its PR.
;; Measured 2026-09-28: of 34 branches, 11 had MERGED PRs and 7 CLOSED, all
;; rendering as `-'.

(ert-deftest decknix-wtp-pr-state--open-feed-wins ()
  "A branch in the open feed uses that state without consulting memory."
  (let ((map (make-hash-table :test 'equal)))
    (puthash (cons "o/r" "br") "open" map)
    (cl-letf (((symbol-function 'decknix--hub-pr-memory-lookup)
               (lambda (&rest _) (error "memory must not be consulted"))))
      (should (equal "open" (decknix-worktree-picker--pr-state-for "O/R" "br" map))))))

(ert-deftest decknix-wtp-pr-state--falls-back-to-memory-for-merged ()
  "A merged PR is absent from the feed and resolved through memory."
  (let ((map (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'decknix--hub-pr-memory-lookup)
               (lambda (_repo _branch) '(:number 20 :url "https://x/pull/20")))
              ((symbol-function 'decknix--hub-pr-status)
               (lambda (_url) '((state . "MERGED")))))
      (should (equal "merged"
                     (decknix-worktree-picker--pr-state-for "o/r" "br" map))))))

(ert-deftest decknix-wtp-pr-state--unknown-stays-nil ()
  "No feed entry and no memory yields nil, which renders as `-'.
Guessing a state would be worse than an empty column."
  (let ((map (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'decknix--hub-pr-memory-lookup)
               (lambda (&rest _) nil)))
      (should-not (decknix-worktree-picker--pr-state-for "o/r" "br" map)))))

(ert-deftest decknix-wtp-pr-state--memory-without-status-stays-nil ()
  "A remembered PR whose state has not loaded does not invent one."
  (let ((map (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'decknix--hub-pr-memory-lookup)
               (lambda (&rest _) '(:number 20 :url "https://x/pull/20")))
              ((symbol-function 'decknix--hub-pr-status)
               (lambda (_url) nil)))
      (should-not (decknix-worktree-picker--pr-state-for "o/r" "br" map)))))


;; -- PR URL resolution for the browse action --------------------------

(ert-deftest decknix-wtp-pr-url--open-feed-supplies-it ()
  "A live PR's URL comes from the feed, matched case-insensitively on repo."
  (let ((decknix--hub-wip
         '((repos . (((repo . "NC-Helix/platform-cli")
                      (prs . (((branch . "feat/x")
                               (url . "https://github.com/nc-helix/platform-cli/pull/1")))))))))) 
    (should (equal "https://github.com/nc-helix/platform-cli/pull/1"
                   (decknix-worktree-picker--pr-url-for
                    "nc-helix/platform-cli" "feat/x")))))

(ert-deftest decknix-wtp-pr-url--merged-pr-comes-from-memory ()
  "A merged PR has left the feed, so the remembered URL is used.
Without this, a row showing `merged' could not be opened -- which is the gap
that made the picker less useful than the sidebar."
  (let ((decknix--hub-wip nil))
    (cl-letf (((symbol-function 'decknix--hub-pr-memory-lookup)
               (lambda (_r _b) '(:number 20 :url "https://x/pull/20"))))
      (should (equal "https://x/pull/20"
                     (decknix-worktree-picker--pr-url-for "o/r" "br"))))))

(ert-deftest decknix-wtp-pr-url--unknown-is-nil ()
  "No feed entry and no memory yields nil, so the caller can say so."
  (let ((decknix--hub-wip nil))
    (cl-letf (((symbol-function 'decknix--hub-pr-memory-lookup)
               (lambda (&rest _) nil)))
      (should-not (decknix-worktree-picker--pr-url-for "o/r" "br")))))

(ert-deftest decknix-wtp-pr-url--wrong-branch-does-not-match ()
  "A repo match is not enough; the branch must match too."
  (let ((decknix--hub-wip
         '((repos . (((repo . "o/r")
                      (prs . (((branch . "other") (url . "https://x/pull/9"))))))))))
    (cl-letf (((symbol-function 'decknix--hub-pr-memory-lookup)
               (lambda (&rest _) nil)))
      (should-not (decknix-worktree-picker--pr-url-for "o/r" "br")))))


(provide 'decknix-worktree-picker-test)
