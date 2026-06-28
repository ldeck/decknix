;;; decknix-agent-provider-test.el --- Tests for agent provider registry -*- lexical-binding: t -*-

(require 'ert)
(require 'decknix-agent-provider)
(require 'cl-lib)

;; Dummy symbols for testing
(defvar test-auggie-cmd '("auggie" "--acp"))
(defvar test-auggie-auth '(:login t))
(defvar test-auggie-env '(("FOO" . "BAR")))
(defun test-auggie-make-config () '((:buffer-name . "TestAuggie")))

(ert-deftest decknix-agent-provider-registration ()
  "Test registration and basic accessors."
  (let ((decknix-agent-provider-registry nil))
    (decknix-agent-register-provider 'test-agent
      '(:make-config-fn test-auggie-make-config
        :acp-command-var test-auggie-cmd
        :auth-var test-auggie-auth
        :env-var test-auggie-env
        :sessions-dir "~/test/sessions"
        :session-file-extension ".json"
        :history-file "~/test/history.log"
        :label "Test Agent"
        :glyph "T"
        :supports-workspace-root t))

    (let ((props (decknix-agent-require-provider 'test-agent)))
      (should (eq (plist-get props :make-config-fn) 'test-auggie-make-config))
      (should (equal (plist-get props :glyph) "T"))
      (should (equal (decknix-agent-provider-glyph 'test-agent) "T"))
      (should (equal (decknix-agent-provider-acp-command 'test-agent) '("auggie" "--acp")))
      (should (equal (decknix-agent-provider-auth 'test-agent) '(:login t)))
      (should (equal (decknix-agent-provider-env 'test-agent) '(("FOO" . "BAR"))))
      (should (equal (decknix-agent-provider-sessions-dir 'test-agent) (expand-file-name "~/test/sessions")))
      (should (equal (decknix-agent-provider-session-file-extension 'test-agent) ".json"))
      (should (equal (decknix-agent-provider-history-file 'test-agent) (expand-file-name "~/test/history.log")))
      (should (eq (decknix-agent-provider-supports-workspace-root 'test-agent) t)))))

(ert-deftest decknix-agent-provider-label-test ()
  "Test that :label returns the human-readable provider name."
  (let ((decknix-agent-provider-registry nil))
    (decknix-agent-register-provider 'test-auggie '(:label "Auggie" :glyph "A"))
    (decknix-agent-register-provider 'test-claude '(:label "Claude" :glyph "C"))
    ;; Known labels
    (should (equal (decknix-agent-provider-label 'test-auggie) "Auggie"))
    (should (equal (decknix-agent-provider-label 'test-claude) "Claude"))
    ;; Fallback: no :label -> symbol name
    (decknix-agent-register-provider 'test-nolabel '(:glyph "?"))
    (should (equal (decknix-agent-provider-label 'test-nolabel) "test-nolabel"))))

(ert-deftest decknix-agent-command-build-test ()
  "Test the high-level command builder.

Model flags are gated on `:model-launch-flag': only providers that
declare a launch flag (e.g. auggie's \"--model\") pin the model on
the command line.  Flagless providers (Claude, Pi) omit the model
entirely here -- the saved model is replayed over ACP after resume
instead (see `decknix--agent-model-replay-needed-p')."
  (let ((decknix-agent-provider-registry nil))
    (decknix-agent-register-provider 'test-agent
      '(:acp-command-var test-auggie-cmd
        :supports-workspace-root t
        :model-launch-flag "--model"))
    (decknix-agent-register-provider 'test-claude
      '(:acp-command-var test-auggie-cmd
        :supports-workspace-root nil))

    ;; Auggie style (supports workspace root + model launch flag)
    (should (equal (decknix--agent-command-build 'test-agent "~/ws")
                   '("auggie" "--acp" "--workspace-root" "~/ws")))
    (should (equal (decknix--agent-command-build 'test-agent "~/ws" "gpt-4")
                   '("auggie" "--acp" "--workspace-root" "~/ws" "--model" "gpt-4")))
    (should (equal (decknix--agent-command-build 'test-agent "~/ws" "gpt-4" "sid-123")
                   '("auggie" "--acp" "--workspace-root" "~/ws" "--model" "gpt-4" "--resume" "sid-123")))

    ;; Claude style (no workspace root flag, no model launch flag):
    ;; the model is never placed on the command line.
    (should (equal (decknix--agent-command-build 'test-claude "~/ws")
                   '("auggie" "--acp")))
    (should (equal (decknix--agent-command-build 'test-claude "~/ws" "claude-3")
                   '("auggie" "--acp")))
    (should (equal (decknix--agent-command-build 'test-claude "~/ws" "claude-3" "sid-123")
                   '("auggie" "--acp" "--resume" "sid-123")))))

(ert-deftest decknix-agent-provider-model-launch-flag-test ()
  "Accessor returns the declared launch flag, or nil when absent."
  (let ((decknix-agent-provider-registry nil))
    (decknix-agent-register-provider 'test-auggie
      '(:model-launch-flag "--model"))
    (decknix-agent-register-provider 'test-claude '(:glyph "C"))
    (should (equal (decknix-agent-provider-model-launch-flag 'test-auggie)
                   "--model"))
    (should (null (decknix-agent-provider-model-launch-flag 'test-claude)))))

(ert-deftest decknix-agent-model-replay-needed-p-test ()
  "Replay is needed only for a flagless provider with a real model."
  (let ((decknix-agent-provider-registry nil))
    (decknix-agent-register-provider 'test-auggie
      '(:model-launch-flag "--model"))
    (decknix-agent-register-provider 'test-claude '(:glyph "C"))
    ;; Launch-flag provider pins via the command line -> never replays.
    (should-not (decknix--agent-model-replay-needed-p 'test-auggie "gpt-4"))
    ;; Flagless provider with a real model -> replay.
    (should (decknix--agent-model-replay-needed-p 'test-claude "claude-3"))
    ;; Flagless provider but no/empty model -> nothing to replay.
    (should-not (decknix--agent-model-replay-needed-p 'test-claude nil))
    (should-not (decknix--agent-model-replay-needed-p 'test-claude ""))))

(ert-deftest decknix-agent-make-config-test ()
  "Test the high-level config builder and its closure."
  (let ((decknix-agent-provider-registry nil))
    (decknix-agent-register-provider 'test-agent
      '(:make-config-fn test-auggie-make-config
        :auth-var test-auggie-auth
        :env-var test-auggie-env))
    
    (cl-letf (((symbol-function 'agent-shell--make-acp-client)
               (lambda (&rest args) args)))
      (let* ((cmd '("cmd" "arg1"))
             (config (decknix--agent-make-config 'test-agent cmd))
             (client-maker (alist-get :client-maker config)))
        (should (equal (alist-get :buffer-name config) "TestAuggie"))
        (should (functionp client-maker))
        ;; Invoke the closure
        (let ((result (funcall client-maker 'dummy-buffer)))
          (should (equal (plist-get result :command) "cmd"))
          (should (equal (plist-get result :command-params) '("arg1")))
          (should (equal (plist-get result :environment-variables) '(("FOO" . "BAR")))))))))

(provide 'decknix-agent-provider-test)
