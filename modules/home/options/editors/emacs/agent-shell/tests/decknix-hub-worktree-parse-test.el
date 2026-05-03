;;; decknix-hub-worktree-parse-test.el --- Tests for hub worktree parser -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-worktree-parse "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning current behaviour of the worktree parser +
;; canonical helpers extracted from the agent-shell heredoc.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-hub-worktree-parse)

;; -- canonical-repo ------------------------------------------------

(ert-deftest decknix-hub-worktree-canonical-repo--nil ()
  "Nil input returns nil."
  (should (null (decknix--hub-worktree-canonical-repo nil))))

(ert-deftest decknix-hub-worktree-canonical-repo--non-string ()
  "Non-string input returns nil (defensive on integers, symbols, lists)."
  (should (null (decknix--hub-worktree-canonical-repo 42)))
  (should (null (decknix--hub-worktree-canonical-repo 'sym)))
  (should (null (decknix--hub-worktree-canonical-repo '("foo")))))

(ert-deftest decknix-hub-worktree-canonical-repo--lowercase ()
  "Already-lowercase input passes through."
  (should (equal (decknix--hub-worktree-canonical-repo "owner/repo")
                 "owner/repo")))

(ert-deftest decknix-hub-worktree-canonical-repo--mixed-case ()
  "Mixed-case input is lowercased."
  (should (equal (decknix--hub-worktree-canonical-repo "Owner/Repo")
                 "owner/repo"))
  (should (equal (decknix--hub-worktree-canonical-repo "RAYWHITE/Decknix")
                 "raywhite/decknix")))

(ert-deftest decknix-hub-worktree-canonical-repo--preserves-slash ()
  "Slash is preserved (no path manipulation, just lowercase)."
  (should (equal (decknix--hub-worktree-canonical-repo "A/B/C")
                 "a/b/c")))

;; -- repo-from-url -------------------------------------------------

(ert-deftest decknix-hub-worktree-repo-from-url--nil ()
  (should (null (decknix--hub-worktree-repo-from-url nil))))

(ert-deftest decknix-hub-worktree-repo-from-url--non-string ()
  (should (null (decknix--hub-worktree-repo-from-url 42))))

(ert-deftest decknix-hub-worktree-repo-from-url--https ()
  "Recognises https://github.com/OWNER/REPO."
  (should (equal (decknix--hub-worktree-repo-from-url
                  "https://github.com/owner/repo")
                 "owner/repo")))

(ert-deftest decknix-hub-worktree-repo-from-url--https-dot-git ()
  "Strips .git suffix."
  (should (equal (decknix--hub-worktree-repo-from-url
                  "https://github.com/owner/repo.git")
                 "owner/repo")))

(ert-deftest decknix-hub-worktree-repo-from-url--https-trailing-slash ()
  "Strips trailing slash."
  (should (equal (decknix--hub-worktree-repo-from-url
                  "https://github.com/owner/repo/")
                 "owner/repo")))

(ert-deftest decknix-hub-worktree-repo-from-url--ssh ()
  "Recognises git@github.com:OWNER/REPO."
  (should (equal (decknix--hub-worktree-repo-from-url
                  "git@github.com:owner/repo.git")
                 "owner/repo")))

(ert-deftest decknix-hub-worktree-repo-from-url--canonicalises-case ()
  "Output is downcased via canonical-repo."
  (should (equal (decknix--hub-worktree-repo-from-url
                  "https://github.com/Owner/Repo.git")
                 "owner/repo")))

(ert-deftest decknix-hub-worktree-repo-from-url--non-github ()
  "Non-github.com URLs return nil."
  (should (null (decknix--hub-worktree-repo-from-url
                 "https://gitlab.com/owner/repo")))
  (should (null (decknix--hub-worktree-repo-from-url
                 "https://bitbucket.org/owner/repo"))))

(ert-deftest decknix-hub-worktree-repo-from-url--garbage ()
  "Strings without a github.com host return nil."
  (should (null (decknix--hub-worktree-repo-from-url "not a url")))
  (should (null (decknix--hub-worktree-repo-from-url ""))))

;; -- normalize-path ------------------------------------------------

(ert-deftest decknix-hub-worktree-normalize-path--nil ()
  (should (null (decknix--hub-worktree-normalize-path nil))))

(ert-deftest decknix-hub-worktree-normalize-path--non-string ()
  (should (null (decknix--hub-worktree-normalize-path 42))))

(ert-deftest decknix-hub-worktree-normalize-path--absolute ()
  "Absolute path is returned unchanged (after expand-file-name)."
  (should (equal (decknix--hub-worktree-normalize-path "/tmp/foo")
                 (expand-file-name "/tmp/foo"))))

(ert-deftest decknix-hub-worktree-normalize-path--tilde ()
  "Tilde is expanded."
  (let ((result (decknix--hub-worktree-normalize-path "~/code/repo")))
    (should (stringp result))
    (should-not (string-match-p "~" result))
    (should (string-prefix-p "/" result))))

(ert-deftest decknix-hub-worktree-normalize-path--relative ()
  "Relative path is made absolute."
  (let ((result (decknix--hub-worktree-normalize-path "foo/bar")))
    (should (string-prefix-p "/" result))))

;; -- parse-porcelain -----------------------------------------------

(ert-deftest decknix-hub-worktree-parse-porcelain--empty ()
  "Empty string returns empty list."
  (should (equal (decknix--hub-worktree-parse-porcelain "") nil)))

(ert-deftest decknix-hub-worktree-parse-porcelain--nil ()
  "Nil input is treated as empty."
  (should (equal (decknix--hub-worktree-parse-porcelain nil) nil)))

(ert-deftest decknix-hub-worktree-parse-porcelain--single-branch ()
  "Single regular worktree on a branch."
  (should (equal
           (decknix--hub-worktree-parse-porcelain
            "worktree /home/me/code/repo\nHEAD abc1234567890\nbranch refs/heads/main\n")
           '(("main" . "/home/me/code/repo")))))

(ert-deftest decknix-hub-worktree-parse-porcelain--detached-head ()
  "Detached HEAD is keyed by short (7-char) sha."
  (should (equal
           (decknix--hub-worktree-parse-porcelain
            "worktree /home/me/code/repo\nHEAD abc1234567890def\ndetached\n")
           '(("abc1234" . "/home/me/code/repo")))))

(ert-deftest decknix-hub-worktree-parse-porcelain--detached-short-sha ()
  "Short HEAD sha (<7 chars) is taken in full without crashing."
  (should (equal
           (decknix--hub-worktree-parse-porcelain
            "worktree /home/me/code/repo\nHEAD abc12\n")
           '(("abc12" . "/home/me/code/repo")))))

(ert-deftest decknix-hub-worktree-parse-porcelain--bare-skipped ()
  "Bare repo records are dropped."
  (should (equal
           (decknix--hub-worktree-parse-porcelain
            "worktree /home/me/code/bare.git\nbare\n")
           nil)))

(ert-deftest decknix-hub-worktree-parse-porcelain--multiple-worktrees ()
  "Multiple records are flushed in source order; result reverses for forward order."
  (should (equal
           (decknix--hub-worktree-parse-porcelain
            (concat
             "worktree /home/me/code/repo\nHEAD aaaaaaa\nbranch refs/heads/main\n"
             "\n"
             "worktree /home/me/code/repo-feature\nHEAD bbbbbbb\nbranch refs/heads/feature/x\n"))
           '(("main"      . "/home/me/code/repo")
             ("feature/x" . "/home/me/code/repo-feature")))))

(ert-deftest decknix-hub-worktree-parse-porcelain--bare-then-branch ()
  "Bare flag applies only to its record; following branch worktree is kept."
  (should (equal
           (decknix--hub-worktree-parse-porcelain
            (concat
             "worktree /home/me/code/bare.git\nbare\n"
             "\n"
             "worktree /home/me/code/repo\nHEAD ccccccc\nbranch refs/heads/main\n"))
           '(("main" . "/home/me/code/repo")))))

(ert-deftest decknix-hub-worktree-parse-porcelain--blank-line-eof ()
  "Trailing blank line does not duplicate or lose the final record."
  (should (equal
           (decknix--hub-worktree-parse-porcelain
            "worktree /home/me/code/repo\nHEAD ddddddd\nbranch refs/heads/main\n\n")
           '(("main" . "/home/me/code/repo")))))

(ert-deftest decknix-hub-worktree-parse-porcelain--malformed-lines-ignored ()
  "Lines that don't match any known record kind are silently ignored."
  (should (equal
           (decknix--hub-worktree-parse-porcelain
            (concat
             "worktree /home/me/code/repo\n"
             "junk that should not match\n"
             "HEAD eeeeeee\nbranch refs/heads/dev\n"))
           '(("dev" . "/home/me/code/repo")))))

(ert-deftest decknix-hub-worktree-parse-porcelain--branch-without-head ()
  "Branch line wins over (missing) HEAD; record is keyed by branch name."
  (should (equal
           (decknix--hub-worktree-parse-porcelain
            "worktree /home/me/code/repo\nbranch refs/heads/wip\n")
           '(("wip" . "/home/me/code/repo")))))

(provide 'decknix-hub-worktree-parse-test)
;;; decknix-hub-worktree-parse-test.el ends here
