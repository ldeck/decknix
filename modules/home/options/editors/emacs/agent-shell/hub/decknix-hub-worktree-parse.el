;;; decknix-hub-worktree-parse.el --- Hub worktree parser + canonical helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, git, worktree

;;; Commentary:
;;
;; Pure parser + path-normalisation helpers extracted from the
;; agent-shell heredoc.  All four functions are leaf primitives
;; consumed by the worktree registry layer (which still lives in
;; the heredoc, pending its own follow-up extraction):
;;
;;   `decknix--hub-worktree-canonical-repo'   (string normalize)
;;   `decknix--hub-worktree-repo-from-url'    (URL -> "owner/repo")
;;   `decknix--hub-worktree-normalize-path'   (~-expansion)
;;   `decknix--hub-worktree-parse-porcelain'  (`git worktree list
;;                                             --porcelain' parser)
;;
;; The parser handles the four record kinds documented in
;; git-worktree(1)'s porcelain section: regular branched, detached
;; HEAD (keyed by short sha), bare repos (skipped), and arbitrary
;; record terminators (blank line OR next `worktree' header).

;;; Code:

(require 'cl-lib)

(defun decknix--hub-worktree-canonical-repo (owner-slash-repo)
  "Lowercase OWNER-SLASH-REPO; safe on nil or non-strings."
  (when (and owner-slash-repo (stringp owner-slash-repo))
    (downcase owner-slash-repo)))

(defun decknix--hub-worktree-repo-from-url (url)
  "Extract canonical \"owner/repo\" from URL or nil.
Recognises https://github.com/OWNER/REPO and SSH git@github.com forms."
  (when (and url (stringp url))
    (when (string-match
           "github\\.com[:/]\\([^/]+\\)/\\([^/]+?\\)\\(?:\\.git\\)?/?$"
           url)
      (decknix--hub-worktree-canonical-repo
       (concat (match-string 1 url) "/" (match-string 2 url))))))

(defun decknix--hub-worktree-normalize-path (path)
  "Return absolute, ~-expanded PATH or nil.
`make-process' does not run a shell, so any `~' in a path passed to
`git -C' would be taken literally and silently fail."
  (when (and path (stringp path))
    (expand-file-name path)))

(defun decknix--hub-worktree-parse-porcelain (text)
  "Parse `git worktree list --porcelain' TEXT into ((BRANCH . PATH) ...).
Detached worktrees are keyed by short HEAD sha.  Bare repos are skipped."
  (let ((out nil)
        (cur-path nil) (cur-branch nil) (cur-head nil) (bare nil))
    (cl-flet ((flush ()
                (when (and cur-path (not bare))
                  (push (cons (or cur-branch
                                  (and cur-head
                                       (substring
                                        cur-head 0
                                        (min 7 (length cur-head)))))
                              cur-path)
                        out))))
      (dolist (line (split-string (or text "") "\n"))
        (cond
         ((string-match "^worktree \\(.+\\)$" line)
          (flush)
          (setq cur-path (match-string 1 line)
                cur-branch nil cur-head nil bare nil))
         ((string-match "^bare$" line) (setq bare t))
         ((string-match "^HEAD \\(.+\\)$" line)
          (setq cur-head (match-string 1 line)))
         ((string-match "^branch refs/heads/\\(.+\\)$" line)
          (setq cur-branch (match-string 1 line)))))
      (flush))
    (nreverse out)))

(provide 'decknix-hub-worktree-parse)
;;; decknix-hub-worktree-parse.el ends here
