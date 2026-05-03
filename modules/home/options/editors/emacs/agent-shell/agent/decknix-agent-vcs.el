;;; decknix-agent-vcs.el --- VCS detection helper -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, vcs, git, pijul, jj

;;; Commentary:
;;
;; Pure VCS-detection primitive extracted from the agent-shell heredoc:
;;
;;   `decknix--vcs-kind'  (DIR -> 'git | 'pijul | 'jj | nil)
;;
;; Filesystem-coupled (uses `file-directory-p' and `file-exists-p')
;; but otherwise pure.  Tested with a tmp-dir fixture that creates
;; the marker file/dir in different layouts (regular repo, worktree
;; with .git as a file, no VCS, etc.).
;;
;; Handles the git-worktree edge case where `.git' inside a worktree
;; is a regular FILE (containing `gitdir: /path/to/main/.git/worktrees/X')
;; rather than a directory — both forms count as `git'.

;;; Code:

(defun decknix--vcs-kind (dir)
  "Return a symbol describing the VCS managing DIR, or nil.
One of: `git', `pijul', `jj', or nil when no recognised VCS is present.
Handles git worktrees (where .git is a file pointing into the main repo)."
  (let ((dir (file-name-as-directory (expand-file-name dir))))
    (cond
     ((or (file-directory-p (expand-file-name ".git" dir))
          (file-exists-p (expand-file-name ".git" dir))) 'git)
     ((file-directory-p (expand-file-name ".pijul" dir)) 'pijul)
     ((file-directory-p (expand-file-name ".jj" dir)) 'jj)
     (t nil))))

(provide 'decknix-agent-vcs)
;;; decknix-agent-vcs.el ends here
