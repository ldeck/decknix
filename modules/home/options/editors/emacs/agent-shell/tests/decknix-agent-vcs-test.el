;;; decknix-agent-vcs-test.el --- Tests for VCS detection -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-vcs "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning current behaviour of `decknix--vcs-kind'.
;; Each test creates a fresh tmp directory, lays out the appropriate
;; marker file or directory, asserts the classification, then cleans up.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-vcs)

;; -- Fixtures ------------------------------------------------------

(defmacro decknix-test--with-tmp-dir (var &rest body)
  "Bind VAR to a fresh tmp directory inside BODY; clean up afterwards."
  (declare (indent 1))
  `(let ((,var (make-temp-file "decknix-vcs-test-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

;; -- detection branches --------------------------------------------

(ert-deftest decknix-vcs-kind--no-vcs ()
  "Empty directory returns nil."
  (decknix-test--with-tmp-dir tmp
    (should (null (decknix--vcs-kind tmp)))))

(ert-deftest decknix-vcs-kind--git-directory ()
  "Standard git repo: .git is a directory."
  (decknix-test--with-tmp-dir tmp
    (make-directory (expand-file-name ".git" tmp))
    (should (eq (decknix--vcs-kind tmp) 'git))))

(ert-deftest decknix-vcs-kind--git-worktree-file ()
  "Git worktree: .git is a file pointing to the main repo's worktrees dir."
  (decknix-test--with-tmp-dir tmp
    (with-temp-file (expand-file-name ".git" tmp)
      (insert "gitdir: /path/to/main/.git/worktrees/feature-x\n"))
    (should (eq (decknix--vcs-kind tmp) 'git))))

(ert-deftest decknix-vcs-kind--pijul ()
  "Pijul repo: .pijul directory."
  (decknix-test--with-tmp-dir tmp
    (make-directory (expand-file-name ".pijul" tmp))
    (should (eq (decknix--vcs-kind tmp) 'pijul))))

(ert-deftest decknix-vcs-kind--jj ()
  "Jujutsu repo: .jj directory."
  (decknix-test--with-tmp-dir tmp
    (make-directory (expand-file-name ".jj" tmp))
    (should (eq (decknix--vcs-kind tmp) 'jj))))

(ert-deftest decknix-vcs-kind--git-precedence ()
  "When both .git and .pijul exist, git wins (cond branch order)."
  (decknix-test--with-tmp-dir tmp
    (make-directory (expand-file-name ".git" tmp))
    (make-directory (expand-file-name ".pijul" tmp))
    (should (eq (decknix--vcs-kind tmp) 'git))))

(ert-deftest decknix-vcs-kind--pijul-vs-jj-precedence ()
  "When .pijul and .jj both exist (no .git), pijul wins."
  (decknix-test--with-tmp-dir tmp
    (make-directory (expand-file-name ".pijul" tmp))
    (make-directory (expand-file-name ".jj" tmp))
    (should (eq (decknix--vcs-kind tmp) 'pijul))))

(ert-deftest decknix-vcs-kind--accepts-trailing-slash ()
  "DIR with or without trailing slash both work (file-name-as-directory)."
  (decknix-test--with-tmp-dir tmp
    (make-directory (expand-file-name ".git" tmp))
    (let ((no-slash  (directory-file-name tmp))
          (with-slash (file-name-as-directory tmp)))
      (should (eq (decknix--vcs-kind no-slash) 'git))
      (should (eq (decknix--vcs-kind with-slash) 'git)))))

(ert-deftest decknix-vcs-kind--unrelated-files-ignored ()
  "Random files in the directory don't trigger any branch."
  (decknix-test--with-tmp-dir tmp
    (with-temp-file (expand-file-name "README.md" tmp) (insert "x"))
    (with-temp-file (expand-file-name ".gitignore" tmp) (insert "*.log"))
    (should (null (decknix--vcs-kind tmp)))))

(provide 'decknix-agent-vcs-test)
;;; decknix-agent-vcs-test.el ends here
