;;; decknix-agent-vcs.el --- VCS detection helper -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, vcs, git, pijul, jj

;;; Commentary:
;;
;; VCS-detection primitives extracted from the agent-shell heredoc:
;;
;;   `decknix--vcs-kind'              (DIR -> 'git | 'pijul | 'jj | nil)
;;   `decknix--git-remote-url'        (DIR -> "https://github.com/OWNER/REPO" | nil)
;;   `decknix--detect-default-branch' (DIR -> branch name string)
;;
;; `decknix--vcs-kind' is filesystem-coupled (uses `file-directory-p'
;; and `file-exists-p') but otherwise pure.  Tested with a tmp-dir
;; fixture that creates the marker file/dir in different layouts
;; (regular repo, worktree with .git as a file, no VCS, etc.).
;;
;; Handles the git-worktree edge case where `.git' inside a worktree
;; is a regular FILE (containing `gitdir: /path/to/main/.git/worktrees/X')
;; rather than a directory — both forms count as `git'.
;;
;; `decknix--git-remote-url' and `decknix--detect-default-branch'
;; shell out to git/gh/pijul.  Tests use `cl-letf' to mock
;; `shell-command-to-string' so the URL canonicalisation logic
;; (SSH->HTTPS rewrite, .git suffix strip, github.com gating) and
;; the per-VCS dispatch in `decknix--detect-default-branch' can be
;; pinned without a real network or repo.

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

(defun decknix--git-remote-url (dir)
  "Return the github.com/OWNER/REPO URL for DIR's origin remote, or nil.
Converts SSH form (git@github.com:OWNER/REPO.git) to HTTPS and strips
any trailing .git suffix.  Returns nil unless the remote is on github.com."
  (let* ((default-directory (file-name-as-directory
                              (expand-file-name dir)))
         (raw (condition-case nil
                  (string-trim
                   (shell-command-to-string
                    "git config --get remote.origin.url"))
                (error ""))))
    (when (and raw (not (string-empty-p raw)))
      (let ((url raw))
        (when (string-match "^git@github\\.com:\\(.+\\)$" url)
          (setq url (concat "https://github.com/"
                            (match-string 1 url))))
        (when (string-suffix-p ".git" url)
          (setq url (substring url 0 -4)))
        (when (string-match-p "github\\.com/" url) url)))))

(defun decknix--detect-default-branch (dir)
  "Return the default branch name for the repo at DIR, as a string.
Uses `gh repo view' first (authoritative for GitHub), falls back to
origin HEAD and `init.defaultBranch' for git, `pijul channel' for
pijul, and returns \"main\" as last-resort fallback for jj and
unknown VCSes."
  (let* ((default-directory (file-name-as-directory
                              (expand-file-name dir)))
         (vcs (decknix--vcs-kind dir))
         (try (lambda (cmd re group)
                (let ((out (condition-case nil
                               (string-trim
                                (shell-command-to-string
                                 (concat cmd " 2>/dev/null")))
                             (error ""))))
                  (when (and out (not (string-empty-p out)))
                    (if re
                        (when (string-match re out)
                          (match-string group out))
                      out))))))
    (or (pcase vcs
          ('git
           (or (funcall try
                "gh repo view --json defaultBranchRef -q .defaultBranchRef.name"
                nil nil)
               (funcall try
                "git symbolic-ref --short refs/remotes/origin/HEAD"
                "^origin/\\(.+\\)$" 1)
               (funcall try
                "git config init.defaultBranch" nil nil)))
          ('pijul
           (funcall try "pijul channel" "^\\* \\(\\S-+\\)" 1))
          (_ nil))
        "main")))

(provide 'decknix-agent-vcs)
;;; decknix-agent-vcs.el ends here
