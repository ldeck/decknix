;;; decknix-agent-review-collaborators-test.el --- Tests for review collaborators store -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-review-collaborators "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the three review-collaborator
;; entry points.  Persistence tests use a per-test mktemp file
;; bound to `decknix-agent-review-collaborators-file' so they
;; never touch ~/.config/decknix/review-collaborators.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-review-collaborators)

(defvar decknix-test-rc--tmp-dir nil)

(defmacro decknix-test-rc-with-tmp (&rest body)
  "Run BODY with a fresh tmp dir + file rebinding for the store."
  (declare (indent 0))
  `(let* ((decknix-test-rc--tmp-dir
           (make-temp-file "decknix-rc-" t))
          (decknix-agent-review-collaborators-file
           (expand-file-name "store.el" decknix-test-rc--tmp-dir))
          (decknix-agent-review-collaborators '()))
     (unwind-protect
         (progn ,@body)
       (delete-directory decknix-test-rc--tmp-dir t))))

;; -- author -------------------------------------------------------

(ert-deftest decknix-agent-review-collaborators--author-prefers-override ()
  "Returns `decknix-agent-review-author' when bound."
  (let ((decknix-agent-review-author "alice")
        (user-login-name "bob"))
    (should (equal "alice" (decknix--agent-review-author)))))

(ert-deftest decknix-agent-review-collaborators--author-falls-back-to-login ()
  "Returns `user-login-name' when override is nil."
  (let ((decknix-agent-review-author nil)
        (user-login-name "bob"))
    (should (equal "bob" (decknix--agent-review-author)))))

(ert-deftest decknix-agent-review-collaborators--author-falls-back-to-me ()
  "Returns literal \"me\" when both override and login are nil."
  (let ((decknix-agent-review-author nil)
        (user-login-name nil))
    (should (equal "me" (decknix--agent-review-author)))))

;; -- load ---------------------------------------------------------

(ert-deftest decknix-agent-review-collaborators--load-noop-when-missing ()
  "Does nothing when the persistence file does not exist."
  (decknix-test-rc-with-tmp
    (decknix--agent-review-load-collaborators)
    (should (null decknix-agent-review-collaborators))))

(ert-deftest decknix-agent-review-collaborators--load-reads-list ()
  "Reads a previously-written list back into the in-memory store."
  (decknix-test-rc-with-tmp
    (with-temp-file decknix-agent-review-collaborators-file
      (prin1 '("alice" "bob" "carol") (current-buffer)))
    (decknix--agent-review-load-collaborators)
    (should (equal '("alice" "bob" "carol")
                   decknix-agent-review-collaborators))))

(ert-deftest decknix-agent-review-collaborators--load-skips-non-list ()
  "Leaves the store untouched when the file holds a non-list."
  (decknix-test-rc-with-tmp
    (setq decknix-agent-review-collaborators '("seed"))
    (with-temp-file decknix-agent-review-collaborators-file
      (prin1 "not a list" (current-buffer)))
    (decknix--agent-review-load-collaborators)
    (should (equal '("seed") decknix-agent-review-collaborators))))

(ert-deftest decknix-agent-review-collaborators--load-swallows-read-error ()
  "Returns nil silently when the file cannot be parsed."
  (decknix-test-rc-with-tmp
    (with-temp-file decknix-agent-review-collaborators-file
      (insert "this is not lisp ((((("))
    (should-not (decknix--agent-review-load-collaborators))))

;; -- save ---------------------------------------------------------

(ert-deftest decknix-agent-review-collaborators--save-creates-parent-dir ()
  "`make-directory' creates the parent directory if missing."
  (decknix-test-rc-with-tmp
    (let ((decknix-agent-review-collaborators-file
           (expand-file-name "deep/nested/store.el"
                             decknix-test-rc--tmp-dir)))
      (setq decknix-agent-review-collaborators '("x"))
      (decknix--agent-review-save-collaborators)
      (should (file-exists-p decknix-agent-review-collaborators-file)))))

(ert-deftest decknix-agent-review-collaborators--save-and-load-roundtrip ()
  "Saved data reloads identically through `read'."
  (decknix-test-rc-with-tmp
    (setq decknix-agent-review-collaborators
          '("alice" "bob" "carol@org"))
    (decknix--agent-review-save-collaborators)
    (setq decknix-agent-review-collaborators nil)
    (decknix--agent-review-load-collaborators)
    (should (equal '("alice" "bob" "carol@org")
                   decknix-agent-review-collaborators))))

(provide 'decknix-agent-review-collaborators-test)
;;; decknix-agent-review-collaborators-test.el ends here
