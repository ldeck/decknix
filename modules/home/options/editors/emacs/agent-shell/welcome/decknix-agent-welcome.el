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

The prompt is the last `agent-shell-chat-me' overlay AND it must reach
the process mark -- the boundary past which text is unsent input.  An
overlay that ends before that mark is a turn already SENT, whatever its
ordinal position.

\"Last overlay\" alone was not enough, and blanked the user's message.
Measured with a probe on a resumed session at the moment of the first
prompt:

    [blank] init-finished=nil overlays=1 last=5904..5913 point-max=5913

Exactly ONE chat-me overlay existed: `agent-shell-chat--label-prompts'
runs after submission but before the next prompt's overlay is created,
so the only candidate at that instant is the message just sent -- and
being last, it was blanked, taking its ` Me ' badge and its leading
newlines with it.

Requiring the overlay to reach the process mark distinguishes the two
cases without depending on relabel ordering.  When there is no process
\(a dead or not-yet-started shell) fall back to the last overlay, which
is the historical behaviour and safe: nothing has been sent yet."
  (let ((prompt nil)
        (proc (get-buffer-process (current-buffer))))
    (dolist (overlay (overlays-in (point-min) (point-max)))
      (when (and (eq (overlay-get overlay 'category) 'agent-shell-chat-me)
                 (or (null prompt)
                     (> (overlay-start overlay) (overlay-start prompt))))
        (setq prompt overlay)))
    (cond
     ((null prompt) nil)
     ((not (and proc (process-live-p proc))) prompt)
     ((>= (overlay-end prompt) (marker-position (process-mark proc))) prompt)
     ;; Last overlay ends before the input boundary: it is a SENT turn,
     ;; not the prompt.  Suppress nothing rather than blank the user's
     ;; own message.
     (t nil))))

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


;; ---------------------------------------------------------------------------
;; Agents-tab isolation: decknix buffers that BELONG on the Agents tab
;; ---------------------------------------------------------------------------

(defcustom decknix-agent-tab-resident-regexps
  '("\\`\\*Agent Context: ")
  "Buffer-name patterns that must stay on the Agents tab.

agent-shell isolates that tab: `agent-shell-workspace--redirect-display'
sits in `display-buffer-alist' and switches to the previous tab for any
buffer `agent-shell-workspace--agent-buffer-p' does not recognise.  Since
`display-buffer-alist' is consulted BEFORE the action argument, no
`display-buffer' action a caller passes can prevent it -- measured during
a real `C-c s c':

    tab 1 -> 0   frame unchanged   action-fns=(display-buffer-below-selected)

The context viewer shows one session's own history and belongs beside
it, so being ejected to another tab is wrong; the user loses the sidebar
and has to navigate back.  Listing it here states that it IS an agent
buffer rather than suppressing the isolation mechanism, which stays
intact for genuinely foreign buffers.

Add patterns for any other per-session surface that should stay put."
  :type '(repeat regexp) :group 'decknix)

(defun decknix--agent-tab-resident-p (buffer)
  "Return non-nil when BUFFER should be exempt from Agents-tab isolation."
  (when (and buffer (buffer-live-p buffer))
    (let ((name (buffer-name buffer)))
      (and name
           (seq-some (lambda (re) (string-match-p re name))
                     decknix-agent-tab-resident-regexps)
           t))))

(defun decknix--agent-tab-resident-advice (orig buffer)
  "Treat decknix per-session buffers as agent buffers.
`:around' advice for `agent-shell-workspace--agent-buffer-p'."
  (or (funcall orig buffer)
      (decknix--agent-tab-resident-p buffer)))


;; ---------------------------------------------------------------------------
;; Never blank a label that is already there
;; ---------------------------------------------------------------------------

(defun decknix--agent-chat-preserve-label (existing props)
  "Return PROPS with a label-destroying `before-string' entry removed.

EXISTING is the overlay's current `before-string'.  When PROPS would set
that to the empty string while EXISTING holds a real label, the entry is
dropped so the label survives; PROPS is returned unchanged otherwise.

`agent-shell-chat--label-prompts' classifies each prompt run and, for one
it judges BLANK, emits `before-string' the empty string:

    ;; An empty submission (blank but not the live prompt)
    ;; is not labeled: only the live prompt shows an empty `Me'.
    (blank <empty string>)

On a RESUMED session that misfires.  The replay rebuilds every overlay in
the restored region, and runs whose text does not reproduce the structure
`agent-shell-chat--prompt-runs' expects come back classified blank -- so
turns that had a ` Me ' badge lose it.  Caught with a probe on
`overlay-put' during a real resume + `/show-context':

    [blanked] buf=*Claude: test/create/session* ov=25156..25157
              init=t was=<a real ` Me ' label>

`init=t' proves this is not decknix's own bootstrap suppression (which
only runs while init is unfinished, and writes via `overlay-put'
directly rather than through the upsert path this guards).

Deliberately one-directional: a label may be SET or CHANGED, never
emptied.  A run that legitimately becomes blank keeps a stale badge,
which is a far smaller cost than silently losing the marker that
distinguishes your turn from the agent's."
  (if (and (equal "" (alist-get 'before-string props))
           existing
           (stringp existing)
           (not (string-empty-p existing)))
      (assq-delete-all 'before-string (copy-sequence props))
    props))

(defun decknix--agent-chat-upsert-advice (orig category anchor-beg anchor-end beg end props)
  "Around-advice for `agent-shell-chat--upsert-overlay': keep real labels.
Only `agent-shell-chat-me' overlays are guarded; agent-side labels and
every other category pass through untouched."
  (let ((props
         (if (eq category 'agent-shell-chat-me)
             (let* ((existing
                     (car (seq-filter
                           (lambda (o) (eq (overlay-get o 'category) category))
                           (overlays-in anchor-beg (max anchor-end (1+ anchor-beg))))))
                    (before (and existing (overlay-get existing 'before-string))))
               (decknix--agent-chat-preserve-label before props))
           props)))
    (funcall orig category anchor-beg anchor-end beg end props)))

(provide 'decknix-agent-welcome)
;;; decknix-agent-welcome.el ends here
