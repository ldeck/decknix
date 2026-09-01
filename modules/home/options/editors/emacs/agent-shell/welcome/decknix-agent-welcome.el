;;; decknix-agent-welcome.el --- Compact welcome + folded setup sections -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, welcome

;;; Commentary:
;;
;; Reclaims the top of every agent-shell buffer, which upstream spends on
;; two things that are only interesting once.
;;
;; 1. THE BANNER.  Each provider's `:welcome-function' prepends ~14 lines
;;    of ASCII art to `shell-maker-welcome-message' (for Claude, the
;;    oh-my-logo "CLAUDE CODE" block).  On a resumed session that art plus
;;    the greeting is the entire first screenful, so opening a session
;;    shows a logo rather than the conversation being resumed.
;;
;;    `decknix--agent-welcome-message' keeps the greeting -- including the
;;    help hint and the sponsor button, which are upstream's to offer --
;;    drops the art, and names the provider in the sentence instead:
;;
;;        Welcome to Claude agent shell
;;
;;    with the provider name bold and colourised, so the buffer still
;;    identifies its agent at a glance.
;;
;; 2. THE SETUP SECTIONS.  Capabilities, config options, models, modes and
;;    /commands each render as a separate top-level collapsible fragment.
;;    Folded into one collapsed group they cost a single line:
;;
;;        > Agent shell setup
;;
;;    `agent-shell--update-fragment' already supports grouping via
;;    `:group-id' / `:group-label' / `:group-expanded'; this module just
;;    decides which blocks belong to the group and injects those keys.
;;
;;    NOTE on membership: `agent-shell-ui' groups only the fragments that
;;    follow the group header CONTIGUOUSLY.  `resumed_session' (the
;;    "✓ Resuming session" line) and `forked_session' render in the middle
;;    of that run, so they are in the group too -- excluding them would
;;    split it into two headers with a stray line between.
;;
;; Both layers here are pure.  The advice installing them (an `:override'
;; on each provider `--welcome-message', and a `:filter-args' on
;; `agent-shell--update-bootstrapping-fragment') lives in the heredoc per
;; AGENTS.md Rule 2.

;;; Code:

(require 'map)

(declare-function shell-maker-config-name "ext:shell-maker" (config))

(defface decknix-agent-welcome-name
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the agent type in the agent-shell welcome line.
Bold and colourised so the buffer still says which agent it is at a
glance, now that the ASCII art no longer does."
  :group 'decknix)

(defconst decknix-agent-setup-group-id "agent_shell_setup"
  "Fragment `:group-id' the bootstrapping setup sections are folded under.")

(defconst decknix-agent-setup-group-label "Agent shell setup"
  "Header text for the folded setup group.")

(defconst decknix-agent-setup-group-blocks
  '("agent_capabilities"
    "forked_session"
    "available_config_options"
    "available_models"
    "available_modes"
    "available_commands_update")
  "Bootstrapping `:block-id's folded under `decknix-agent-setup-group-label'.

The five setup sections, plus `forked_session'.

`resumed_session' is deliberately absent: \"✓ Resuming session\" stays
visible at top level.  That is only safe because decknix owns that write
and defers it until after `agent-shell--finalize-session-init', so the
marker lands BELOW the setup run (see
`decknix--agent-resume-native-send').  `agent-shell-ui' groups only a
contiguous run, so excluding a block that still rendered mid-run would
split the group in two rather than move the block out of it.

`forked_session' stays IN for exactly that reason: upstream writes it
mid-run, before finalize, and we do not own the call site.  Folding one
extra line on the fork path beats splitting its group into two headers.")

(defun decknix--agent-welcome-name (agent-config)
  "Return the display name for AGENT-CONFIG, e.g. \"Claude\".

Prefers `:mode-line-name' (the short one that reads naturally mid
sentence), then `:buffer-name'.  Always returns a string: the greeting
is a sentence, so a missing name degrades to \"agent\" rather than
rendering nil."
  (or (and (listp agent-config)
           (or (map-elt agent-config :mode-line-name)
               (map-elt agent-config :buffer-name)))
      "agent"))

(defun decknix--agent-welcome-format (name key sponsor)
  "Build the compact welcome message for agent NAME.

KEY is the rendered submit-key binding, SPONSOR the sponsor button text;
both are passed in so this stays a pure formatter that tests can call
without a live shell.  NAME is propertized with
`decknix-agent-welcome-name'."
  (format
   "\n\n     Welcome to %s agent shell\n\n\n       Type %s and press %s for details.\n\n       Like this package? Consider ✨%s✨\n\n"
   (propertize name 'font-lock-face 'decknix-agent-welcome-name)
   (propertize "help" 'font-lock-face 'italic)
   key
   sponsor))

(defun decknix--agent-setup-group-block-p (block-id)
  "Non-nil when BLOCK-ID is one of the folded setup sections."
  (and (stringp block-id)
       (member block-id decknix-agent-setup-group-blocks)
       t))

(defun decknix--agent-setup-group-args (args)
  "Return ARGS with the setup-group keys injected, when they apply.

ARGS is the `&key' plist headed for `agent-shell--update-fragment'.
Returns ARGS unchanged -- the same object -- for any block outside the
group, and for a caller that already chose a `:group-id' of its own, so
this can sit on every bootstrapping fragment write without surprising
one that has its own grouping."
  (if (and (decknix--agent-setup-group-block-p (plist-get args :block-id))
           (not (plist-get args :group-id)))
      (append (list :group-id decknix-agent-setup-group-id
                    :group-label decknix-agent-setup-group-label
                    :group-expanded nil)
              args)
    args))

(defvar-local decknix--agent-shell-init-finished nil
  "Non-nil once this shell's ACP initialization has fully finished.
Set from the `init-finished' event.  Until then the prompt exists but
the agent cannot act on input, so its ` Me '/`❯' affordance is
suppressed -- see `decknix--agent-chat-blank-prompt-labels'.")

(defun decknix--agent-chat-live-prompt-overlay ()
  "Return the overlay for this buffer's LIVE input prompt, or nil.

The prompt is the LAST `agent-shell-chat-me' overlay: upstream keeps it
at the end of the buffer so there is always somewhere to type, while
every earlier overlay of that category is a user turn already sent.

Identified by position rather than by looking for the `❯' marker in the
`before-string', so the suppression still finds the prompt on a buffer
where the marker has already been blanked (it runs on every relabel)."
  (let ((prompt nil))
    (dolist (overlay (overlays-in (point-min) (point-max)))
      (when (and (eq (overlay-get overlay 'category) 'agent-shell-chat-me)
                 (or (null prompt)
                     (> (overlay-start overlay) (overlay-start prompt))))
        (setq prompt overlay)))
    prompt))

(defun decknix--agent-chat-blank-prompt-labels ()
  "Empty the ` Me '/`❯' affordance on this buffer's LIVE chat prompt.

Upstream shows the prompt at shell creation, deliberately, so the shell
always has somewhere to type.  Under `agent-shell-chat-mode' that prompt
renders as the ` Me ' badge and `❯' marker -- precisely the signal read
as \"the agent is ready\" -- while it is in fact still handshaking,
resuming and setting its session mode.

Only the live prompt (`decknix--agent-chat-live-prompt-overlay') is
touched.  This used to blank EVERY `agent-shell-chat-me' overlay in the
buffer, which is wrong twice over on a resumed session: the restored
history carries that same category, and one `before-string' encodes
three separate things --

    sent message   \"\\n Me \\n\\n\"        position + label
    live prompt    \"\\n Me \\n\\n  ❯ \"    position + label + marker

so emptying it stripped the leading newlines (the message lost its
spacing and rendered jammed against the preceding line) and the ` Me '
label that distinguishes a user turn from an agent turn, not just the
input marker.  Measured on the #453 review session: 19 restored turns
left permanently blank, and the just-sent message unlabelled.

Clears `before-string' ONLY.  The overlay's `display' property is what
hides the raw `Claude> ' text, so removing the overlay would replace a
premature badge with a bare prompt string: a worse lie, not a smaller
one.  Agent-side labels (`agent-shell-chat-agent') mark output that has
genuinely happened and are left untouched."
  (let ((prompt (decknix--agent-chat-live-prompt-overlay)))
    (when prompt
      (overlay-put prompt 'before-string ""))))

(provide 'decknix-agent-welcome)
;;; decknix-agent-welcome.el ends here
