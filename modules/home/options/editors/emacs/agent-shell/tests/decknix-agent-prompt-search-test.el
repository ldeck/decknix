;;; decknix-agent-prompt-search-test.el --- Tests for prompt-search jq command -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-prompt-search "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix--prompt-search-jq-cmd'
;; (carved from `decknix-agent-shell-main' / main-bulk into
;; `decknix-agent-prompt-search').  Pins the shell-pipeline contract:
;;
;;   * `find -maxdepth 1 -name '*.json'' under the sessions dir;
;;   * `xargs -0 -P8' for parallel jq fan-out;
;;   * inline `sh -c' wrapper with `jq -c -f <filter> <file> || true'
;;     so a single corrupt file doesn't poison the whole stream;
;;   * sessions dir + jq filter file are both run through
;;     `shell-quote-argument' (defends against paths with spaces).

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Stub the cached-filter ensure helper before loading the module so
;; the byte-compiler resolves the `declare-function' forward ref.
;; Tests rebind it via `cl-letf' to control the returned path.
(unless (fboundp 'decknix--prompt-extract-ensure-jq-filter)
  (defun decknix--prompt-extract-ensure-jq-filter ()
    "/tmp/test-extract.jq"))

(require 'decknix-agent-prompt-search)

;; The sessions-dir defvar is owned by the session-cache module in
;; production; declare it here so let-binding in tests rebinds the
;; same special variable the module reads.
(defvar decknix--agent-sessions-dir)

;; -- jq command shape ---------------------------------------------

(ert-deftest decknix-agent-prompt-search/jq-cmd-shape ()
  "The shell command finds JSON files and fans out to jq via xargs."
  (let ((decknix--agent-sessions-dir "/tmp/test-sessions-dir"))
    (cl-letf (((symbol-function 'decknix--prompt-extract-ensure-jq-filter)
               (lambda () "/tmp/test-extract.jq")))
      (let ((cmd (decknix--prompt-search-jq-cmd)))
        (should (string-match-p "find " cmd))
        (should (string-match-p "test-sessions-dir" cmd))
        (should (string-match-p "-maxdepth 1" cmd))
        (should (string-match-p "-name '\\*\\.json'" cmd))
        (should (string-match-p "xargs -0 -P8" cmd))
        (should (string-match-p "jq -c -f " cmd))
        (should (string-match-p "test-extract\\.jq" cmd))))))

(ert-deftest decknix-agent-prompt-search/jq-cmd-uses-sh-c-wrapper ()
  "Per-file invocation runs through `sh -c' with `|| true' so a
single corrupt session file doesn't kill the whole xargs pipeline."
  (let ((decknix--agent-sessions-dir "/tmp/sessions"))
    (cl-letf (((symbol-function 'decknix--prompt-extract-ensure-jq-filter)
               (lambda () "/tmp/extract.jq")))
      (let ((cmd (decknix--prompt-search-jq-cmd)))
        (should (string-match-p "sh -c " cmd))
        (should (string-match-p "|| true" cmd))))))

(ert-deftest decknix-agent-prompt-search/jq-cmd-suppresses-find-stderr ()
  "Find redirects its stderr to /dev/null so a missing sessions
dir on a fresh install is silent rather than spamming the picker."
  (let ((decknix--agent-sessions-dir "/tmp/sessions"))
    (cl-letf (((symbol-function 'decknix--prompt-extract-ensure-jq-filter)
               (lambda () "/tmp/extract.jq")))
      (let ((cmd (decknix--prompt-search-jq-cmd)))
        (should (string-match-p "2>/dev/null" cmd))))))

(ert-deftest decknix-agent-prompt-search/jq-cmd-quotes-sessions-dir ()
  "Sessions dir flows through `shell-quote-argument' so a space in
the path doesn't shatter the find/xargs pipeline.  We don't pin the
exact quoting style — just that the literal unquoted form never
appears in the emitted command."
  (let ((decknix--agent-sessions-dir "/tmp/has space/sessions"))
    (cl-letf (((symbol-function 'decknix--prompt-extract-ensure-jq-filter)
               (lambda () "/tmp/extract.jq")))
      (let ((cmd (decknix--prompt-search-jq-cmd))
            (quoted (shell-quote-argument "/tmp/has space/sessions")))
        (should (string-match-p (regexp-quote quoted) cmd))
        ;; The naked path with a real space must not appear unescaped.
        (should-not (string-match-p
                     "find /tmp/has space/sessions " cmd))))))

(ert-deftest decknix-agent-prompt-search/jq-cmd-quotes-filter-path ()
  "Filter path is also quoted so a tmp dir path with shell metas
(e.g. `$', spaces) doesn't break the sh -c wrapper."
  (let ((decknix--agent-sessions-dir "/tmp/sessions"))
    (cl-letf (((symbol-function 'decknix--prompt-extract-ensure-jq-filter)
               (lambda () "/tmp/has space/extract.jq")))
      (let ((cmd (decknix--prompt-search-jq-cmd))
            (quoted (shell-quote-argument "/tmp/has space/extract.jq")))
        (should (string-match-p (regexp-quote quoted) cmd))))))

(ert-deftest decknix-agent-prompt-search/jq-cmd-calls-ensure-each-time ()
  "Every call re-asks the prompt-extract module for the cached
filter path -- guarantees the path stays fresh if the tmp file was
cleaned up between async refreshes."
  (let ((decknix--agent-sessions-dir "/tmp/sessions")
        (calls 0))
    (cl-letf (((symbol-function 'decknix--prompt-extract-ensure-jq-filter)
               (lambda ()
                 (cl-incf calls)
                 "/tmp/extract.jq")))
      (decknix--prompt-search-jq-cmd)
      (decknix--prompt-search-jq-cmd)
      (decknix--prompt-search-jq-cmd)
      (should (= calls 3)))))

(provide 'decknix-agent-prompt-search-test)
;;; decknix-agent-prompt-search-test.el ends here
