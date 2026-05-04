;;; decknix-agent-workspace-detect-test.el --- Tests for workspace + branch detection -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-workspace-detect "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix--agent-detect-workspace',
;; `decknix--agent-pr-detect-workspace', and
;; `decknix--agent-detect-branch'.  All three are stubbed against
;; the filesystem (`file-directory-p') and the tags-store reader
;; via `cl-letf' so the tests run hermetically in batch Emacs
;; without touching `~/.config/decknix/' or the actual disk.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-workspace-detect)

;; -- Test fixtures -----------------------------------------------

(defvar decknix-test-ws-detect--store nil)
(defvar decknix-test-ws-detect--existing-dirs nil)

(defun decknix-test-ws-detect--fresh-store ()
  (let ((root (make-hash-table :test 'equal))
        (convs (make-hash-table :test 'equal)))
    (puthash "conversations" convs root)
    root))

(defmacro decknix-test-ws-detect-with-stubs (&rest body)
  "Run BODY with stubbed tags-store + filesystem + project."
  (declare (indent 0))
  `(let ((decknix-test-ws-detect--store
          (decknix-test-ws-detect--fresh-store))
         (decknix-test-ws-detect--existing-dirs nil))
     (cl-letf (((symbol-function 'decknix--agent-tags-read)
                (lambda () decknix-test-ws-detect--store))
               ((symbol-function 'decknix--agent-tags-conversations)
                (lambda (s) (gethash "conversations" s)))
               ((symbol-function 'file-directory-p)
                (lambda (p)
                  (member (directory-file-name (expand-file-name p))
                          decknix-test-ws-detect--existing-dirs))))
       ,@body)))

(defun decknix-test-ws-detect--mark-dir (path)
  "Mark PATH as an existing directory for the stub."
  (push (directory-file-name (expand-file-name path))
        decknix-test-ws-detect--existing-dirs))

(defun decknix-test-ws-detect--seed-workspace (conv-key ws)
  (let ((entry (make-hash-table :test 'equal)))
    (puthash "workspace" ws entry)
    (puthash conv-key entry
             (decknix--agent-tags-conversations
              (decknix--agent-tags-read)))))

;; -- detect-workspace --------------------------------------------

(ert-deftest decknix-agent-workspace-detect--ws-falls-back-to-default-dir ()
  "When `project-current' returns nil, falls back to `default-directory'."
  (cl-letf (((symbol-function 'project-current) (lambda (&optional _ _d) nil)))
    (let ((default-directory "/some/where/"))
      (should (equal "/some/where/"
                     (decknix--agent-detect-workspace))))))

(ert-deftest decknix-agent-workspace-detect--ws-prefers-project-root ()
  "When `project-current' resolves, uses `project-root'."
  (cl-letf (((symbol-function 'project-current)
             (lambda (&optional _ _d) '(transient . "/proj/root/")))
            ((symbol-function 'project-root) (lambda (_p) "/proj/root/")))
    (let ((default-directory "/elsewhere/"))
      (should (equal "/proj/root/"
                     (decknix--agent-detect-workspace))))))

;; -- pr-detect-workspace -----------------------------------------

(ert-deftest decknix-agent-workspace-detect--pr-tier1-exact-basename ()
  "Tier 1: saved workspace whose basename matches REPO."
  (decknix-test-ws-detect-with-stubs
    (decknix-test-ws-detect--seed-workspace "ck" "/Code/myorg/myrepo")
    (decknix-test-ws-detect--mark-dir "/Code/myorg/myrepo")
    (should (equal "/Code/myorg/myrepo"
                   (decknix--agent-pr-detect-workspace "myorg" "myrepo")))))

(ert-deftest decknix-agent-workspace-detect--pr-tier1-case-insensitive ()
  "Tier 1: basename match is case-insensitive."
  (decknix-test-ws-detect-with-stubs
    (decknix-test-ws-detect--seed-workspace "ck" "/Code/MyRepo")
    (decknix-test-ws-detect--mark-dir "/Code/MyRepo")
    (should (equal "/Code/MyRepo"
                   (decknix--agent-pr-detect-workspace "myorg" "myrepo")))))

(ert-deftest decknix-agent-workspace-detect--pr-tier2-subdir-of-org ()
  "Tier 2: saved workspace contains REPO as a subdir; returns parent."
  (decknix-test-ws-detect-with-stubs
    (decknix-test-ws-detect--seed-workspace "ck" "/Code/myorg")
    (decknix-test-ws-detect--mark-dir "/Code/myorg/myrepo")
    (let ((got (decknix--agent-pr-detect-workspace "myorg" "myrepo")))
      ;; Tier 2 returns the parent path (file-name-as-directory).
      (should (equal "/Code/myorg/" got)))))

(ert-deftest decknix-agent-workspace-detect--pr-tier3-roots-fallback ()
  "Tier 3: falls through to `decknix-agent-workspace-roots'."
  (decknix-test-ws-detect-with-stubs
    (decknix-test-ws-detect--mark-dir "/roots/myorg/myrepo")
    (let ((decknix-agent-workspace-roots '("/roots/myorg")))
      (should (equal "/roots/myorg/myrepo/"
                     (decknix--agent-pr-detect-workspace "myorg" "myrepo"))))))

(ert-deftest decknix-agent-workspace-detect--pr-no-match-returns-nil ()
  "All tiers miss -> nil."
  (decknix-test-ws-detect-with-stubs
    (let ((decknix-agent-workspace-roots nil))
      (should (null (decknix--agent-pr-detect-workspace "owner" "repo"))))))

(ert-deftest decknix-agent-workspace-detect--pr-tier1-skips-missing-on-disk ()
  "Tier 1 ignores saved workspaces whose path no longer exists."
  (decknix-test-ws-detect-with-stubs
    (decknix-test-ws-detect--seed-workspace "ck" "/Code/myorg/myrepo")
    ;; Don't mark the dir as existing -- file-directory-p returns nil.
    (let ((decknix-agent-workspace-roots nil))
      (should (null (decknix--agent-pr-detect-workspace "myorg" "myrepo"))))))

;; -- detect-branch -----------------------------------------------

(ert-deftest decknix-agent-workspace-detect--branch-returns-trimmed-name ()
  "Returns the trimmed branch name from git."
  (cl-letf (((symbol-function 'shell-command-to-string)
             (lambda (_) "  feature/foo  \n")))
    (should (equal "feature/foo" (decknix--agent-detect-branch "/dir")))))

(ert-deftest decknix-agent-workspace-detect--branch-empty-returns-nil ()
  "Returns nil when git outputs nothing (not a repo)."
  (cl-letf (((symbol-function 'shell-command-to-string) (lambda (_) "")))
    (should (null (decknix--agent-detect-branch "/dir")))))

(ert-deftest decknix-agent-workspace-detect--branch-detached-returns-nil ()
  "Returns nil when HEAD is detached (git outputs `HEAD')."
  (cl-letf (((symbol-function 'shell-command-to-string) (lambda (_) "HEAD\n")))
    (should (null (decknix--agent-detect-branch "/dir")))))

(provide 'decknix-agent-workspace-detect-test)
;;; decknix-agent-workspace-detect-test.el ends here
