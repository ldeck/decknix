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

;; -- decknix--git-remote-url ---------------------------------------
;;
;; Mocks `shell-command-to-string' so we can pin the URL
;; canonicalisation logic without a real git invocation.

(defmacro decknix-test--with-git-remote (output &rest body)
  "Bind `shell-command-to-string' to a stub returning OUTPUT inside BODY.
The stub asserts the first call is the expected `git config --get
remote.origin.url' command, then returns OUTPUT verbatim."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'shell-command-to-string)
              (lambda (cmd)
                (should (string-match-p "remote\\.origin\\.url" cmd))
                ,output)))
     ,@body))

(ert-deftest decknix-git-remote-url--ssh-canonicalised ()
  "SSH form is rewritten to https with `.git' stripped."
  (decknix-test--with-git-remote "git@github.com:owner/repo.git\n"
    (should (equal (decknix--git-remote-url "/tmp/anything")
                   "https://github.com/owner/repo"))))

(ert-deftest decknix-git-remote-url--https-passthrough ()
  "HTTPS form keeps its scheme + host, just strips trailing `.git'."
  (decknix-test--with-git-remote "https://github.com/owner/repo.git\n"
    (should (equal (decknix--git-remote-url "/tmp/anything")
                   "https://github.com/owner/repo"))))

(ert-deftest decknix-git-remote-url--no-git-suffix ()
  "URLs already without `.git' are returned untouched."
  (decknix-test--with-git-remote "https://github.com/owner/repo\n"
    (should (equal (decknix--git-remote-url "/tmp/anything")
                   "https://github.com/owner/repo"))))

(ert-deftest decknix-git-remote-url--non-github-rejected ()
  "Non-github.com remotes (e.g., gitlab) return nil."
  (decknix-test--with-git-remote "git@gitlab.com:owner/repo.git\n"
    (should (null (decknix--git-remote-url "/tmp/anything")))))

(ert-deftest decknix-git-remote-url--empty-output-nil ()
  "Empty `git config' output (no remote configured) returns nil."
  (decknix-test--with-git-remote ""
    (should (null (decknix--git-remote-url "/tmp/anything")))))

(ert-deftest decknix-git-remote-url--whitespace-trimmed ()
  "Leading/trailing whitespace in the git output is stripped."
  (decknix-test--with-git-remote "   git@github.com:owner/repo.git  \n"
    (should (equal (decknix--git-remote-url "/tmp/anything")
                   "https://github.com/owner/repo"))))

;; -- decknix--detect-default-branch --------------------------------
;;
;; Per-VCS dispatch tests.  We mock both `decknix--vcs-kind' (to
;; pick the dispatch arm) and `shell-command-to-string' (to control
;; what each shell-out returns) using `cl-letf'.  The fallback chain
;; for git is gh -> origin/HEAD -> init.defaultBranch -> "main".

(defmacro decknix-test--with-detect-fixture
    (vcs-kind shell-fn &rest body)
  "Stub `decknix--vcs-kind' to VCS-KIND and `shell-command-to-string' to SHELL-FN.
SHELL-FN is a lambda receiving the COMMAND string and returning the
fake stdout for that command."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'decknix--vcs-kind)
              (lambda (_dir) ,vcs-kind))
             ((symbol-function 'shell-command-to-string) ,shell-fn))
     ,@body))

(ert-deftest decknix-detect-default-branch--git-gh-wins ()
  "When `gh repo view' returns a branch name, it short-circuits the chain."
  (decknix-test--with-detect-fixture 'git
      (lambda (cmd)
        (cond
         ((string-match-p "gh repo view" cmd) "develop\n")
         (t (error "should not have fallen through to %s" cmd))))
    (should (equal (decknix--detect-default-branch "/tmp/x") "develop"))))

(ert-deftest decknix-detect-default-branch--git-falls-back-to-origin-head ()
  "Empty `gh' output falls through to origin/HEAD with regexp extraction."
  (decknix-test--with-detect-fixture 'git
      (lambda (cmd)
        (cond
         ((string-match-p "gh repo view" cmd) "")
         ((string-match-p "symbolic-ref" cmd) "origin/main\n")
         (t (error "should not have fallen through to %s" cmd))))
    (should (equal (decknix--detect-default-branch "/tmp/x") "main"))))

(ert-deftest decknix-detect-default-branch--git-falls-back-to-init-default ()
  "Both gh and origin/HEAD empty -> `git config init.defaultBranch'."
  (decknix-test--with-detect-fixture 'git
      (lambda (cmd)
        (cond
         ((string-match-p "gh repo view" cmd) "")
         ((string-match-p "symbolic-ref" cmd) "")
         ((string-match-p "init.defaultBranch" cmd) "trunk\n")
         (t "")))
    (should (equal (decknix--detect-default-branch "/tmp/x") "trunk"))))

(ert-deftest decknix-detect-default-branch--git-all-empty-fallback-main ()
  "Whole git chain empty -> last-resort \"main\"."
  (decknix-test--with-detect-fixture 'git (lambda (_cmd) "")
    (should (equal (decknix--detect-default-branch "/tmp/x") "main"))))

(ert-deftest decknix-detect-default-branch--pijul-channel-extracted ()
  "Pijul branch parses the leading `* CHANNEL' line."
  (decknix-test--with-detect-fixture 'pijul
      (lambda (cmd)
        (should (string-match-p "pijul channel" cmd))
        "* feature-x\n  main\n  other\n")
    (should (equal (decknix--detect-default-branch "/tmp/x") "feature-x"))))

(ert-deftest decknix-detect-default-branch--jj-fallback-main ()
  "JJ has no dispatch arm -> last-resort \"main\"."
  (decknix-test--with-detect-fixture 'jj
      (lambda (_cmd) (error "shell-command-to-string should not run for jj"))
    (should (equal (decknix--detect-default-branch "/tmp/x") "main"))))

(ert-deftest decknix-detect-default-branch--unknown-vcs-fallback-main ()
  "Unknown VCS (nil) -> last-resort \"main\"."
  (decknix-test--with-detect-fixture nil
      (lambda (_cmd) (error "shell-command-to-string should not run for unknown vcs"))
    (should (equal (decknix--detect-default-branch "/tmp/x") "main"))))

(provide 'decknix-agent-vcs-test)
;;; decknix-agent-vcs-test.el ends here
