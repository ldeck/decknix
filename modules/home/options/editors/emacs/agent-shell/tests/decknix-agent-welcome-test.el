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

(ert-deftest decknix-agent-setup-group--excludes-resumed-session ()
  "`✓ Resuming session' stays visible at top level, outside the group.

Possible only because decknix owns that write and defers it until after
`agent-shell--finalize-session-init', so the marker lands BELOW the
setup run instead of splitting it -- see
`decknix--agent-resume-native-send'.  `agent-shell-ui' groups only a
contiguous run, so excluding a block that still renders mid-run would
break the group in half rather than move the block out of it."
  (should-not (decknix--agent-setup-group-block-p "resumed_session")))

(ert-deftest decknix-agent-setup-group--keeps-forked-session ()
  "`forked_session' stays IN the group, unlike `resumed_session'.

Not an inconsistency: upstream writes that fragment mid-run, before
`agent-shell--finalize-session-init', and we do not own the call site.
Excluding it would split the fork flow's group into two headers, which
is worse than folding one extra line."
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

;; -- no input affordance until the agent can accept input ----------
;;
;; Upstream shows the prompt at shell creation, deliberately, "so shell
;; always has a prompt to type into regardless of strategy".  With
;; `agent-shell-chat-mode' that prompt is drawn as the ` Me ' badge and
;; `❯' marker -- the exact signal the user reads as "ready" -- while the
;; agent is still handshaking, resuming and setting its session mode.
;;
;; Blanking the label is not the same as removing the overlay.  The
;; overlay's `display' property is what hides the raw `Claude> ' text; drop
;; the overlay and the bare prompt string appears instead, which is worse
;; than the badge.  So the suppression clears `before-string' only, and
;; leaves `display' alone.

(ert-deftest decknix-chat-blank-labels--clears-the-me-badge ()
  "The ` Me '/`❯' before-string is emptied."
  (with-temp-buffer
    (insert "Claude> ")
    (let ((o (make-overlay 1 (point-max))))
      (overlay-put o 'category 'agent-shell-chat-me)
      (overlay-put o 'display "")
      (overlay-put o 'before-string "\n Me \n\n  ❯ ")
      (decknix--agent-chat-blank-prompt-labels)
      (should (equal "" (overlay-get o 'before-string))))))

(ert-deftest decknix-chat-blank-labels--keeps-the-prompt-text-hidden ()
  "`display' survives, so the raw `Claude> ' does not become visible.
Dropping the overlay outright would show the bare prompt string, which
is a worse regression than the premature badge."
  (with-temp-buffer
    (insert "Claude> ")
    (let ((o (make-overlay 1 (point-max))))
      (overlay-put o 'category 'agent-shell-chat-me)
      (overlay-put o 'display "")
      (overlay-put o 'before-string "\n Me \n\n  ❯ ")
      (decknix--agent-chat-blank-prompt-labels)
      (should (equal "" (overlay-get o 'display)))
      (should (overlay-buffer o)))))

(ert-deftest decknix-chat-blank-labels--leaves-the-agent-label-alone ()
  "Only the user-side prompt label is suppressed.
The agent's own ` Claude ' label marks output that has genuinely
happened, so it stays."
  (with-temp-buffer
    (insert "response")
    (let ((o (make-overlay 1 (point-max))))
      (overlay-put o 'category 'agent-shell-chat-agent)
      (overlay-put o 'before-string "\n Claude \n")
      (decknix--agent-chat-blank-prompt-labels)
      (should (equal "\n Claude \n" (overlay-get o 'before-string))))))

(ert-deftest decknix-chat-blank-labels--tolerates-a-bare-buffer ()
  "No overlays at all must not error -- this runs on every relabel."
  (with-temp-buffer
    (insert "nothing here")
    (should (progn (decknix--agent-chat-blank-prompt-labels) t))))

;; -- scope: only the LIVE prompt, never a sent message ----------------
;;
;; The suppression blanked EVERY `agent-shell-chat-me' overlay in the
;; buffer.  A resumed session restores its history, so the buffer is full
;; of past user messages carrying that same category -- measured on the
;; #453 review session: 19 of them left permanently `before=""'.
;;
;; The damage is wider than a missing badge because one `before-string'
;; carries three things at once:
;;
;;   sent message   "\n Me \n\n"        position + label
;;   live prompt    "\n Me \n\n  ❯ "    position + label + input marker
;;
;; Blanking it destroys the leading newlines (so the message loses its
;; spacing and renders jammed against whatever precedes it), the ` Me '
;; label that distinguishes a user turn from an agent turn, AND the
;; marker.  Only the marker is meant to go.

(ert-deftest decknix-chat-blank-labels--spares-sent-messages ()
  "A sent user message keeps its label and spacing; only the prompt is blanked.

Observed: after submitting, the message rendered with no ` Me ' badge and
jammed against the preceding line, because its `before-string' had been
emptied along with the prompt's."
  (with-temp-buffer
    (insert "Please re-review\n\nClaude> ")
    (let ((sent (make-overlay 1 17))
          (prompt (make-overlay 19 (point-max))))
      (overlay-put sent 'category 'agent-shell-chat-me)
      (overlay-put sent 'before-string "\n Me \n\n")
      (overlay-put prompt 'category 'agent-shell-chat-me)
      (overlay-put prompt 'before-string "\n Me \n\n  ❯ ")
      (decknix--agent-chat-blank-prompt-labels)
      ;; The sent turn is history: untouched.
      (should (equal "\n Me \n\n" (overlay-get sent 'before-string)))
      ;; The live prompt is the input affordance: suppressed.
      (should (equal "" (overlay-get prompt 'before-string))))))

(ert-deftest decknix-chat-blank-labels--spares-restored-history ()
  "A resumed session's restored history is never touched.
Every past turn keeps its label, however many there are."
  (with-temp-buffer
    (insert "aaaa bbbb cccc dddd")
    (let ((history (list (make-overlay 1 5) (make-overlay 6 10) (make-overlay 11 15)))
          (prompt (make-overlay 16 (point-max))))
      (dolist (o history)
        (overlay-put o 'category 'agent-shell-chat-me)
        (overlay-put o 'before-string "\n Me \n\n"))
      (overlay-put prompt 'category 'agent-shell-chat-me)
      (overlay-put prompt 'before-string "\n Me \n\n  ❯ ")
      (decknix--agent-chat-blank-prompt-labels)
      (dolist (o history)
        (should (equal "\n Me \n\n" (overlay-get o 'before-string))))
      (should (equal "" (overlay-get prompt 'before-string))))))

(ert-deftest decknix-chat-blank-labels--single-overlay-is-the-prompt ()
  "With only one chat-me overlay it IS the prompt, so it is blanked.
This is the fresh-session case the suppression was written for."
  (with-temp-buffer
    (insert "Claude> ")
    (let ((o (make-overlay 1 (point-max))))
      (overlay-put o 'category 'agent-shell-chat-me)
      (overlay-put o 'before-string "\n Me \n\n  ❯ ")
      (decknix--agent-chat-blank-prompt-labels)
      (should (equal "" (overlay-get o 'before-string))))))


(ert-deftest decknix-chat-blank-labels--spares-a-just-sent-message ()
  "A sent turn is never blanked, even when it is the ONLY overlay.

Measured on a resumed session at the moment of the first prompt:

    [blank] init-finished=nil overlays=1 last=5904..5913 point-max=5913

`agent-shell-chat--label-prompts' runs after submission but BEFORE the
next prompt's overlay exists, so the sole candidate is the message just
sent.  Picking \"the last overlay\" then blanked the user's own message,
taking its ` Me ' badge and leading newlines with it -- the reported
symptom, on both new and resumed sessions.

The overlay must reach the process mark to count as the input prompt."
  (with-temp-buffer
    (insert "Where are we up to?\n\nClaude> ")
    (let ((sent (make-overlay 1 20)))
      (overlay-put sent 'category 'agent-shell-chat-me)
      (overlay-put sent 'before-string "\n Me \n\n")
      ;; A live process whose mark sits AFTER the sent overlay.
      (cl-letf (((symbol-function 'get-buffer-process) (lambda (&rest _) 'proc))
                ((symbol-function 'process-live-p) (lambda (&rest _) t))
                ((symbol-function 'process-mark) (lambda (&rest _) (copy-marker 22))))
        (should-not (decknix--agent-chat-live-prompt-overlay))
        (decknix--agent-chat-blank-prompt-labels)
        (should (equal "\n Me \n\n" (overlay-get sent 'before-string)))))))

(ert-deftest decknix-chat-blank-labels--prompt-at-the-mark-is-blanked ()
  "An overlay reaching the process mark IS the prompt and is suppressed."
  (with-temp-buffer
    (insert "Claude> ")
    (let ((prompt (make-overlay 1 (point-max))))
      (overlay-put prompt 'category 'agent-shell-chat-me)
      (overlay-put prompt 'before-string "\n Me \n\n  \u276f ")
      (cl-letf (((symbol-function 'get-buffer-process) (lambda (&rest _) 'proc))
                ((symbol-function 'process-live-p) (lambda (&rest _) t))
                ((symbol-function 'process-mark)
                 (lambda (&rest _) (copy-marker (point-max)))))
        (decknix--agent-chat-blank-prompt-labels)
        (should (equal "" (overlay-get prompt 'before-string)))))))

(ert-deftest decknix-chat-blank-labels--no-process-falls-back ()
  "With no live process nothing has been sent, so the last overlay is the prompt."
  (with-temp-buffer
    (insert "Claude> ")
    (let ((o (make-overlay 1 (point-max))))
      (overlay-put o 'category 'agent-shell-chat-me)
      (overlay-put o 'before-string "\n Me \n\n")
      (cl-letf (((symbol-function 'get-buffer-process) (lambda (&rest _) nil)))
        (decknix--agent-chat-blank-prompt-labels)
        (should (equal "" (overlay-get o 'before-string)))))))

(provide 'decknix-agent-welcome-test)
;;; decknix-agent-welcome-test.el ends here
