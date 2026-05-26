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

(provide 'decknix-worktree-picker-test)
;;; decknix-worktree-picker-test.el ends here
