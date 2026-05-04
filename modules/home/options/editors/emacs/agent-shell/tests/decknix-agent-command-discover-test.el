;;; decknix-agent-command-discover-test.el --- Tests for command discovery -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-command-discover "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix--agent-command-files'
;; and `decknix--agent-command-description'.  Filesystem is real
;; (per-test mktemp dirs under `decknix-test-cmd-disc--root') so
;; the directory-scan + frontmatter-read paths exercise the real
;; helpers; `project-current' is stubbed via `cl-letf' so the
;; project-level branch is hit deterministically.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-command-discover)

(defvar decknix-test-cmd-disc--root nil)

(defmacro decknix-test-cmd-disc-with-tmp (&rest body)
  "Run BODY with a fresh temp dir bound to `decknix-test-cmd-disc--root'."
  (declare (indent 0))
  `(let ((decknix-test-cmd-disc--root
          (make-temp-file "decknix-cmd-disc-" t)))
     (unwind-protect
         (progn ,@body)
       (delete-directory decknix-test-cmd-disc--root t))))

(defun decknix-test-cmd-disc--write (rel content)
  "Write CONTENT to REL under the test root, creating parent dirs."
  (let ((path (expand-file-name rel decknix-test-cmd-disc--root)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path (insert content))
    path))

;; -- command-files -----------------------------------------------

(ert-deftest decknix-agent-command-discover--files-empty-when-no-dirs ()
  "Returns nil when no configured dir exists."
  (decknix-test-cmd-disc-with-tmp
    (let ((decknix--agent-command-dirs
           (list (expand-file-name "missing" decknix-test-cmd-disc--root))))
      (cl-letf (((symbol-function 'project-current) (lambda (&optional _ _d) nil)))
        (should (null (decknix--agent-command-files)))))))

(ert-deftest decknix-agent-command-discover--files-scans-global-dir ()
  "Picks up *.md files from a configured global directory and labels them.
Rebinds HOME via `process-environment' so `expand-file-name \"~/.augment\"'
resolves under the test tmp root -- this exercises the real scope-prefix
check (global vs project) without monkey-patching `expand-file-name'."
  (decknix-test-cmd-disc-with-tmp
    (let* ((process-environment
            (cons (concat "HOME=" decknix-test-cmd-disc--root)
                  (cl-remove-if (lambda (s) (string-prefix-p "HOME=" s))
                                process-environment)))
           (global (expand-file-name "~/.augment/commands"))
           (decknix--agent-command-dirs (list global)))
      (cl-letf (((symbol-function 'project-current) (lambda (&optional _ _d) nil)))
        (make-directory global t)
        (with-temp-file (expand-file-name "foo.md" global) (insert "x"))
        (with-temp-file (expand-file-name "bar.md" global) (insert "y"))
        (let ((result (decknix--agent-command-files)))
          (should (= 2 (length result)))
          (should (cl-some (lambda (e) (string-match-p "/foo  (global)" (car e))) result))
          (should (cl-some (lambda (e) (string-match-p "/bar  (global)" (car e))) result)))))))

(ert-deftest decknix-agent-command-discover--files-skips-non-md ()
  "Ignores non-.md files in the configured directory."
  (decknix-test-cmd-disc-with-tmp
    (let* ((dir (expand-file-name "global" decknix-test-cmd-disc--root))
           (decknix--agent-command-dirs (list dir)))
      (cl-letf (((symbol-function 'project-current) (lambda (&optional _ _d) nil)))
        (make-directory dir t)
        (with-temp-file (expand-file-name "ok.md" dir) (insert "x"))
        (with-temp-file (expand-file-name "skip.txt" dir) (insert "y"))
        (let ((result (decknix--agent-command-files)))
          (should (= 1 (length result)))
          (should (string-match-p "/ok" (caar result))))))))

(ert-deftest decknix-agent-command-discover--files-includes-project-dir ()
  "Adds project-level .augment/commands when project-current resolves."
  (decknix-test-cmd-disc-with-tmp
    (let* ((global (expand-file-name "global" decknix-test-cmd-disc--root))
           (proj-root (expand-file-name "proj/" decknix-test-cmd-disc--root))
           (proj-cmd-dir (expand-file-name ".augment/commands" proj-root))
           (decknix--agent-command-dirs (list global)))
      (cl-letf (((symbol-function 'project-current)
                 (lambda (&optional _ _d) (cons 'transient proj-root)))
                ((symbol-function 'project-root) (lambda (_p) proj-root)))
        (make-directory global t)
        (make-directory proj-cmd-dir t)
        (with-temp-file (expand-file-name "g.md" global) (insert "x"))
        (with-temp-file (expand-file-name "p.md" proj-cmd-dir) (insert "y"))
        (let* ((result (decknix--agent-command-files))
               (names (mapcar #'car result)))
          (should (= 2 (length result)))
          (should (cl-some (lambda (n) (string-match-p "/p  (project)" n)) names))
          (should (cl-some (lambda (n) (string-match-p "/g" n)) names)))))))

;; -- command-description -----------------------------------------

(ert-deftest decknix-agent-command-discover--desc-extracts-from-frontmatter ()
  "Returns the description value from a YAML frontmatter block."
  (decknix-test-cmd-disc-with-tmp
    (let ((path (decknix-test-cmd-disc--write
                 "cmds/with-desc.md"
                 "---\ndescription: Run a thing\n---\nbody\n")))
      (should (equal "Run a thing"
                     (decknix--agent-command-description path))))))

(ert-deftest decknix-agent-command-discover--desc-empty-without-frontmatter ()
  "Returns the empty string when the file has no frontmatter."
  (decknix-test-cmd-disc-with-tmp
    (let ((path (decknix-test-cmd-disc--write
                 "cmds/no-fm.md" "Just body, no frontmatter\n")))
      (should (equal "" (decknix--agent-command-description path))))))

(ert-deftest decknix-agent-command-discover--desc-empty-when-field-missing ()
  "Returns the empty string when frontmatter exists but no description: line."
  (decknix-test-cmd-disc-with-tmp
    (let ((path (decknix-test-cmd-disc--write
                 "cmds/fm-no-desc.md"
                 "---\ntitle: Foo\n---\nbody\n")))
      (should (equal "" (decknix--agent-command-description path))))))

(provide 'decknix-agent-command-discover-test)
;;; decknix-agent-command-discover-test.el ends here
