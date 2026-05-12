;;; decknix-agent-clipboard-test.el --- Tests for clipboard URL helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-clipboard "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix--agent-clipboard-url'.
;; The kill ring is exercised via `kill-new' + `with-temp-buffer'
;; (kill ring is global, so each test resets it via
;; `let'-shadowed `kill-ring' / `kill-ring-yank-pointer').  The
;; `pbpaste' fallback is exercised by stubbing
;; `shell-command-to-string' through `cl-letf'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-clipboard)

(defmacro decknix-test-clip-with-empty-kill-ring (&rest body)
  "Run BODY with a freshly-empty kill ring."
  (declare (indent 0))
  `(let ((kill-ring nil)
         (kill-ring-yank-pointer nil))
     ,@body))

;; -- kill-ring branch --------------------------------------------

(ert-deftest decknix-agent-clipboard--reads-pr-url-from-kill-ring ()
  "Returns a PR URL when the kill ring head contains one."
  (decknix-test-clip-with-empty-kill-ring
    (kill-new "https://github.com/foo/bar/pull/42")
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_) (error "Should not fall through to pbpaste"))))
      (should (equal "https://github.com/foo/bar/pull/42"
                     (decknix--agent-clipboard-url))))))

(ert-deftest decknix-agent-clipboard--trims-whitespace-from-kill-ring ()
  "Trims surrounding whitespace from the kill ring entry."
  (decknix-test-clip-with-empty-kill-ring
    (kill-new "  https://github.com/foo/bar/pull/1  \n")
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_) "")))
      (should (equal "https://github.com/foo/bar/pull/1"
                     (decknix--agent-clipboard-url))))))

(ert-deftest decknix-agent-clipboard--nil-when-kill-ring-non-pr ()
  "Falls through to pbpaste (and returns nil) for non-PR kill ring text.
The kill ring matches always: `current-kill' returns it, so when it
isn't a PR URL the function returns nil without consulting pbpaste."
  (decknix-test-clip-with-empty-kill-ring
    (kill-new "just some text, no url")
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_) "https://example.com")))
      (should (null (decknix--agent-clipboard-url))))))

;; -- pbpaste fallback --------------------------------------------

(ert-deftest decknix-agent-clipboard--falls-back-to-pbpaste ()
  "Reads from pbpaste when the kill ring is empty."
  (decknix-test-clip-with-empty-kill-ring
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_) "https://github.com/x/y/pull/9\n")))
      (should (equal "https://github.com/x/y/pull/9"
                     (decknix--agent-clipboard-url))))))

(ert-deftest decknix-agent-clipboard--pbpaste-non-pr-returns-nil ()
  "Returns nil when pbpaste output isn't a PR URL."
  (decknix-test-clip-with-empty-kill-ring
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_) "https://example.com/foo")))
      (should (null (decknix--agent-clipboard-url))))))

(ert-deftest decknix-agent-clipboard--swallows-pbpaste-error ()
  "Returns nil cleanly when pbpaste signals an error."
  (decknix-test-clip-with-empty-kill-ring
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_) (error "pbpaste not found"))))
      (should (null (decknix--agent-clipboard-url))))))

;; -- decknix--clipboard-github-pr-url ----------------------------

(ert-deftest decknix-clipboard-github-pr-url--matches-canonical-pr-url ()
  "Returns the kill ring head when it is a fully-qualified PR URL."
  (decknix-test-clip-with-empty-kill-ring
    (kill-new "https://github.com/foo/bar/pull/42")
    (should (equal "https://github.com/foo/bar/pull/42"
                   (decknix--clipboard-github-pr-url)))))

(ert-deftest decknix-clipboard-github-pr-url--trims-whitespace ()
  "Trims surrounding whitespace from the kill ring entry."
  (decknix-test-clip-with-empty-kill-ring
    (kill-new "  https://github.com/foo/bar/pull/1  \n")
    (should (equal "https://github.com/foo/bar/pull/1"
                   (decknix--clipboard-github-pr-url)))))

(ert-deftest decknix-clipboard-github-pr-url--rejects-bare-repo ()
  "Returns nil for repo URLs without a `/pull/N' segment."
  (decknix-test-clip-with-empty-kill-ring
    (kill-new "https://github.com/foo/bar")
    (should (null (decknix--clipboard-github-pr-url)))))

(ert-deftest decknix-clipboard-github-pr-url--rejects-non-github ()
  "Returns nil for non-GitHub URLs."
  (decknix-test-clip-with-empty-kill-ring
    (kill-new "https://example.com/foo/bar/pull/1")
    (should (null (decknix--clipboard-github-pr-url)))))

(ert-deftest decknix-clipboard-github-pr-url--nil-on-empty-kill-ring ()
  "Returns nil when the kill ring is empty (no `pbpaste' fallback)."
  (decknix-test-clip-with-empty-kill-ring
    (should (null (decknix--clipboard-github-pr-url)))))

;; -- decknix--clipboard-github-repo-url --------------------------

(ert-deftest decknix-clipboard-github-repo-url--matches-bare-repo ()
  "Returns the kill ring head when it is a GitHub repo URL."
  (decknix-test-clip-with-empty-kill-ring
    (kill-new "https://github.com/foo/bar")
    (should (equal "https://github.com/foo/bar"
                   (decknix--clipboard-github-repo-url)))))

(ert-deftest decknix-clipboard-github-repo-url--rejects-pr-url ()
  "Returns nil for PR URLs -- those belong to the PR helper."
  (decknix-test-clip-with-empty-kill-ring
    (kill-new "https://github.com/foo/bar/pull/42")
    (should (null (decknix--clipboard-github-repo-url)))))

(ert-deftest decknix-clipboard-github-repo-url--trims-whitespace ()
  "Trims surrounding whitespace from the kill ring entry."
  (decknix-test-clip-with-empty-kill-ring
    (kill-new "  https://github.com/foo/bar  \n")
    (should (equal "https://github.com/foo/bar"
                   (decknix--clipboard-github-repo-url)))))

(ert-deftest decknix-clipboard-github-repo-url--rejects-non-github ()
  "Returns nil for non-GitHub URLs."
  (decknix-test-clip-with-empty-kill-ring
    (kill-new "https://example.com/foo/bar")
    (should (null (decknix--clipboard-github-repo-url)))))

(ert-deftest decknix-clipboard-github-repo-url--nil-on-empty-kill-ring ()
  "Returns nil when the kill ring is empty."
  (decknix-test-clip-with-empty-kill-ring
    (should (null (decknix--clipboard-github-repo-url)))))

(provide 'decknix-agent-clipboard-test)
;;; decknix-agent-clipboard-test.el ends here
