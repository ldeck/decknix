;;; decknix-worktree-picker-test.el --- Tests for worktree picker -*- lexical-binding: t -*-

(require 'ert)
(require 'decknix-worktree-picker)
(require 'decknix-test-helpers)

(ert-deftest decknix-worktree-picker-list-entries--mocked ()
  "Test that list entries join registry data with PR state."
  (let ((decknix--hub-worktree-cache (make-hash-table :test 'equal))
        (decknix--hub-wip '(((repo . "owner/repo") (branch . "feature/foo") (state . "merged") (merged_at . "2026-05-22T00:00:00Z")))))
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

(provide 'decknix-worktree-picker-test)
;;; decknix-worktree-picker-test.el ends here
