;;; decknix-agent-welcome-test.el --- Tests for the compact welcome + setup group -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Two independent trims to the top of every agent-shell buffer:
;;
;;   1. The welcome banner.  Upstream prepends ~14 lines of ASCII art to
;;      `shell-maker-welcome-message'.  On a resumed buffer that is the
;;      first screenful, before any of the conversation.
;;
;;   2. The bootstrapping sections.  Capabilities / config options /
;;      models / modes / commands are five separate top-level fragments;
;;      folded into one collapsed group they cost one line.
;;
;; Only the pure layers are unit-tested per AGENTS.md Rule 2: the string
;; builder, the name resolution, and the argument injection.  The advice
;; that installs them lives in the heredoc.

;;; Code:

(require 'ert)
(require 'decknix-agent-welcome)

;; -- agent name resolution ---------------------------------------

(ert-deftest decknix-agent-welcome-name--prefers-mode-line-name ()
  "The short provider name is what reads well mid-sentence."
  (should (equal "Claude"
                 (decknix--agent-welcome-name
                  '((:mode-line-name . "Claude") (:buffer-name . "Claude-x"))))))

(ert-deftest decknix-agent-welcome-name--falls-back-to-buffer-name ()
  "A provider that sets only `:buffer-name' still names itself."
  (should (equal "Pi" (decknix--agent-welcome-name '((:buffer-name . "Pi"))))))

(ert-deftest decknix-agent-welcome-name--degrades-to-generic ()
  "No config at all still produces a sentence, never nil."
  (should (equal "agent" (decknix--agent-welcome-name nil)))
  (should (equal "agent" (decknix--agent-welcome-name '((:other . "x"))))))

;; -- the welcome string ------------------------------------------

(ert-deftest decknix-agent-welcome-format--names-the-agent-type ()
  "Reads `Welcome to <agent> agent shell'."
  (should (string-match-p "Welcome to Claude agent shell"
                          (decknix--agent-welcome-format "Claude" "RET" "sponsoring"))))

(ert-deftest decknix-agent-welcome-format--keeps-help-and-sponsor-lines ()
  "The two upstream affordances survive the trim."
  (let ((s (decknix--agent-welcome-format "Claude" "RET" "sponsoring")))
    (should (string-match-p "Type help and press RET for details\\." s))
    (should (string-match-p "Like this package\\? Consider ✨sponsoring✨" s))))

(ert-deftest decknix-agent-welcome-format--carries-no-ascii-art ()
  "The banner is the whole point: no box-drawing characters may appear.
Pinned so a future re-wire to an upstream welcome function that
reintroduces the art fails here rather than in a screenshot."
  (let ((s (decknix--agent-welcome-format "Claude" "RET" "sponsoring")))
    (should-not (string-match-p "[█╗╔╝╚║═]" s))))

(ert-deftest decknix-agent-welcome-format--stays-short ()
  "Ten lines or fewer, versus ~24 for the art version.
The exact count is the spacing the user asked for; the bound is here to
catch a regrowth, not to pin whitespace."
  (should (<= (length (split-string (decknix--agent-welcome-format "Claude" "RET" "s") "\n"))
              10)))

(ert-deftest decknix-agent-welcome-format--agent-name-is-bold ()
  "The agent type is colourised AND bold, as requested."
  (let* ((s (decknix--agent-welcome-format "Claude" "RET" "sponsoring"))
         (start (string-match "Claude" s))
         (face (get-text-property start 'font-lock-face s)))
    (should face)
    (should (eq 'decknix-agent-welcome-name face))))

;; -- setup group membership --------------------------------------

(ert-deftest decknix-agent-setup-group--covers-the-five-sections ()
  "Every section the user asked to fold is in the group."
  (dolist (id '("agent_capabilities" "available_config_options"
                "available_models" "available_modes"
                "available_commands_update"))
    (should (decknix--agent-setup-group-block-p id))))

(ert-deftest decknix-agent-setup-group--includes-interleaved-session-markers ()
  "`resumed_session' / `forked_session' must be in the group too.

Not cosmetic: `agent-shell-ui' groups only fragments that follow the
header CONTIGUOUSLY, and `✓ Resuming session' renders between
`Agent capabilities' and `Available config options'.  Leaving it out
would split the group in two."
  (should (decknix--agent-setup-group-block-p "resumed_session"))
  (should (decknix--agent-setup-group-block-p "forked_session")))

(ert-deftest decknix-agent-setup-group--excludes-progress-and-content ()
  "Blocks the user still wants to see at top level stay out."
  (dolist (id '("starting" "set-model" "set-session-mode" "plan" "Error"))
    (should-not (decknix--agent-setup-group-block-p id))))

;; -- argument injection ------------------------------------------

(ert-deftest decknix-agent-setup-group-args--injects-collapsed-group ()
  "A qualifying block gains the group keys, collapsed by default."
  (let ((out (decknix--agent-setup-group-args
              '(:block-id "available_models" :label-left "Available models"))))
    (should (equal "available_models" (plist-get out :block-id)))
    (should (equal "Agent shell setup" (plist-get out :group-label)))
    (should (plist-get out :group-id))
    (should (eq nil (plist-get out :group-expanded)))))

(ert-deftest decknix-agent-setup-group-args--leaves-other-blocks-alone ()
  "A non-setup block is returned untouched, not merely un-grouped."
  (let ((in '(:block-id "starting" :body "Ready")))
    (should (equal in (decknix--agent-setup-group-args in)))))

(ert-deftest decknix-agent-setup-group-args--does-not-clobber-an-existing-group ()
  "A caller that already chose a group keeps it."
  (let ((out (decknix--agent-setup-group-args
              '(:block-id "available_models" :group-id "mine"))))
    (should (equal "mine" (plist-get out :group-id)))))

(ert-deftest decknix-agent-setup-group-args--tolerates-a-blockless-call ()
  "No `:block-id' must not error out of the advice."
  (should (equal '(:body "x") (decknix--agent-setup-group-args '(:body "x")))))

(provide 'decknix-agent-welcome-test)
;;; decknix-agent-welcome-test.el ends here
