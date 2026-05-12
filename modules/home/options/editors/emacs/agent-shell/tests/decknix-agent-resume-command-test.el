;;; decknix-agent-resume-command-test.el --- Tests for resume command builder -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-resume-command' (PR
;; B.76).  Pure value-object: composes the auggie ACP command line
;; for a session-resume from BASE-CMD + WORKSPACE + MODEL +
;; SESSION-ID.  No I/O, no buffer state, no closures.
;;
;; Workspace existence validation is the *caller's* responsibility
;; (filesystem I/O is impure); the builder simply includes
;; `--workspace-root WS' iff WORKSPACE is a non-empty string.  This
;; mirrors the upstream contract: pre-validated workspace or nil.

;;; Code:

(require 'ert)
(require 'decknix-agent-resume-command)

(defconst decknix-test--resume-base
  '("auggie" "--acp")
  "Stable BASE-CMD fixture mirroring the production `agent-shell-auggie-acp-command'.")

(ert-deftest decknix-resume-command--minimal-just-session-id ()
  "With nil WORKSPACE and nil MODEL, only `--resume SID' is appended."
  (should (equal (decknix--resume-command-build
                  decknix-test--resume-base nil nil "abc123")
                 '("auggie" "--acp" "--resume" "abc123"))))

(ert-deftest decknix-resume-command--with-workspace ()
  "Non-empty WORKSPACE injects `--workspace-root WS' before `--resume'."
  (should (equal (decknix--resume-command-build
                  decknix-test--resume-base "/home/u/proj" nil "sid")
                 '("auggie" "--acp"
                   "--workspace-root" "/home/u/proj"
                   "--resume" "sid"))))

(ert-deftest decknix-resume-command--empty-workspace-string-omitted ()
  "Empty-string WORKSPACE is treated as nil (no `--workspace-root')."
  (should (equal (decknix--resume-command-build
                  decknix-test--resume-base "" nil "sid")
                 '("auggie" "--acp" "--resume" "sid"))))

(ert-deftest decknix-resume-command--with-model ()
  "Non-empty MODEL injects `--model M' before `--resume'."
  (should (equal (decknix--resume-command-build
                  decknix-test--resume-base nil "claude-sonnet-4" "sid")
                 '("auggie" "--acp"
                   "--model" "claude-sonnet-4"
                   "--resume" "sid"))))

(ert-deftest decknix-resume-command--workspace-then-model-then-resume ()
  "Argument order is workspace -> model -> resume, matching the bulk implementation."
  (should (equal (decknix--resume-command-build
                  decknix-test--resume-base "/ws" "gpt-5" "sid")
                 '("auggie" "--acp"
                   "--workspace-root" "/ws"
                   "--model" "gpt-5"
                   "--resume" "sid"))))

(ert-deftest decknix-resume-command--does-not-mutate-base-cmd ()
  "BASE-CMD must be left unchanged so callers can reuse the global list."
  (let ((base (copy-sequence decknix-test--resume-base)))
    (decknix--resume-command-build base "/ws" "m" "sid")
    (should (equal base decknix-test--resume-base))))

(ert-deftest decknix-resume-command--empty-base-cmd ()
  "An empty BASE-CMD is permitted; result is just the appended args."
  (should (equal (decknix--resume-command-build nil "/ws" "m" "sid")
                 '("--workspace-root" "/ws"
                   "--model" "m"
                   "--resume" "sid"))))

(ert-deftest decknix-resume-command--nil-model-treated-as-absent ()
  "Nil MODEL omits the `--model' flag entirely."
  (let ((cmd (decknix--resume-command-build
              decknix-test--resume-base "/ws" nil "sid")))
    (should-not (member "--model" cmd))))

(ert-deftest decknix-resume-command--nil-workspace-treated-as-absent ()
  "Nil WORKSPACE omits the `--workspace-root' flag entirely."
  (let ((cmd (decknix--resume-command-build
              decknix-test--resume-base nil "m" "sid")))
    (should-not (member "--workspace-root" cmd))))

(provide 'decknix-agent-resume-command-test)
;;; decknix-agent-resume-command-test.el ends here
