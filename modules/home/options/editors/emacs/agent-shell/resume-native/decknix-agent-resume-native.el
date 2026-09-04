;;; decknix-agent-resume-native.el --- Native ACP session resume -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, session, resume, acp

;;; Commentary:
;;
;; Native ACP `session/resume' on resume for separate-bridge providers
;; (#143 follow-up to the resume continuation primer).
;;
;; Auggie's own CLI is the ACP server and accepts `--resume <sid>' on the
;; command line, so its resume natively reloads the transcript into the
;; model's context.  The separate-bridge providers (Claude via
;; `claude-agent-acp', Pi via `pi-acp') cannot resume that way: their
;; bridge is a pure ACP server that ignores a resume flag in argv.
;; Historically that meant a resumed Claude session booted `session/new'
;; with an empty model context, and the only history the model saw was a
;; lightweight continuation *primer* (`decknix-agent-resume-primer.el')
;; pointing it at the transcript file to re-read.
;;
;; The bridges now advertise the ACP `session/resume' capability, which
;; restores the prior conversation into the model's context natively --
;; the same engine as `claude --resume', delivered over the wire because
;; our client speaks ACP rather than argv.  This module drives it.
;;
;; The seam is an `:around' advice on `agent-shell--initiate-session'
;; (added in the heredoc per AGENTS.md Rule 2).  When the shell buffer
;; carries a pending `decknix--agent-resume-target-sid' AND the connected
;; agent advertised `:supports-session-resume', we send a `session/resume'
;; request for that exact id (skipping upstream's `session/list' +
;; strategy selection, which only offers "latest"/"prompt" and cannot
;; target an arbitrary saved session).  On success we mirror the upstream
;; load path -- `agent-shell--set-session-from-response' +
;; `agent-shell--finalize-session-init' -- so the state machine then
;; applies the saved model + permission mode exactly as for a new
;; session.  On failure we fall back to the original (`session/new'), and
;; the primer fires as before, so we never regress below the old
;; behaviour.
;;
;; Two ACP calls can restore context, and we use whichever the bridge
;; offers, preferring `session/resume':
;;
;;   `session/resume' -- restores server-side and replays NOTHING to the
;;     client, so it composes with our own on-disk buffer prepopulation
;;     (`decknix--agent-session-prepopulate').  Claude advertises this.
;;
;;   `session/load'   -- restores context AND replays the whole
;;     transcript back as `session/update' notifications.  Pi advertises
;;     this and not resume.
;;
;; This module long gated on `:supports-session-resume' alone, on the
;; reasoning that `session/load' "would double-render against the
;; prepopulated buffer".  True as far as it went, but the conclusion drawn
;; from it was wrong: it excluded pi entirely rather than skipping the
;; prepopulation pi's own replay makes redundant.  So every pi resume fell
;; through to the continuation primer -- which costs a full model turn
;; re-reading the transcript -- to work around a capability pi already
;; had.  Confirmed in pi-acp 0.0.31: `loadSession' calls `restoreSession',
;; which spawns the pi CLI with `--session <path>' (real model context),
;; then replays each stored message as a `user_message_chunk' or
;; assistant chunk under the same session id.
;;
;; The double-render is therefore avoided by choosing who renders rather
;; than by declining to resume: `decknix--agent-resume-bridge-replays-p'
;; makes exactly one side responsible.

;;; Code:

(require 'map)

;; agent-shell / acp internals resolved at runtime (forward-declared to
;; keep the byte-compiler warning-clean; this module is loaded after
;; agent-shell in the heredoc).
(declare-function agent-shell--state "agent-shell")
(declare-function agent-shell--update-bootstrapping-fragment "agent-shell")
(declare-function agent-shell--make-status-kind-label "agent-shell")
(declare-function agent-shell--set-session-from-response "agent-shell")
(declare-function agent-shell--finalize-session-init "agent-shell")
(declare-function agent-shell--resolve-path "agent-shell")
(declare-function agent-shell-cwd "agent-shell")
(declare-function agent-shell--mcp-servers "agent-shell")
(declare-function agent-shell-subscribe-to "agent-shell")
(declare-function agent-shell-unsubscribe "agent-shell")
(declare-function acp-send-request "acp")
;; Tracked sender: registers the request in `:active-requests' for its
;; lifetime, which is what lets a `session/load' replay render.
(declare-function agent-shell--send-request "agent-shell")
(declare-function acp-make-session-resume-request "acp")
(declare-function acp-make-session-load-request "acp")
;; Transcript prepopulation lives in the history layer; needed here only
;; to restore what the `load' path skipped when the load fails.
(declare-function decknix--agent-session-prepopulate
                  "decknix-agent-context-history" (session-id n))
(defvar decknix-agent-session-history-count)

(defvar-local decknix--agent-resume-target-sid nil
  "ACP session id this buffer should resume natively over `session/resume'.
Set by the resume orchestration before session init, for providers
without a `:resume-cli-flag' (Claude, Pi).  When nil, the session is
created the normal way (`session/new').")

(defvar-local decknix--agent-resume-native-method nil
  "How this buffer's session is being restored: `resume', `load', or nil.

Set SYNCHRONOUSLY by the `:around' advice at session-init, before any
request goes out, because the resume orchestration reads it ~1.5s later
to decide whether to prepopulate the buffer from the transcript.  A
single source of truth for that decision: deriving it separately (from a
provider property, say) would let the two disagree the moment a bridge's
capabilities changed, and the failure would be a silently doubled or
silently empty transcript.

Cleared back to nil if the request fails, so the fallback path
prepopulates as it always did.")

(defvar-local decknix--agent-resume-native-done nil
  "Non-nil once this buffer's session was resumed natively over ACP.
Gates the continuation primer: when `session/resume' loaded real context
into the model there is nothing to prime, so the primer is suppressed
\(see `decknix--agent-resume-primer-on-ready').")

(defcustom decknix-agent-resume-load-full-context t
  "When non-nil (the default), resume restores prior context natively.
Resume then uses ACP `session/resume': the bridge reloads the
conversation into the model's context server-side, so the resumed agent
genuinely continues the thread.  Costs one request and NO model
generation, and degrades automatically to the nil path when the bridge
does not advertise the capability.

When nil, resume instead starts a fresh `session/new' and auto-sends the
lightweight continuation primer (`decknix-agent-resume-primer.el') as the
first user message.

The nil path was once labelled the \"fast\" one; that framing was wrong in
the way that matters.  Its session handshake does complete marginally
sooner, but the primer is submitted the instant the session reports
ready, so the shell flips straight from ready to busy — and the primer
instructs the model to go and read the prior transcript.  You therefore
wait out a full model turn, plus however many tool calls that re-read
costs, before you can type.  Native resume has no such turn.  It is also
lossy: the model reconstructs a summary of the conversation rather than
holding the conversation.

Keep nil only to deliberately resume with an empty context window (e.g.
a very long transcript you would rather the model did not carry).

Toggle from the sidebar session menu or via
`decknix-agent-toggle-resume-full-context'."
  :type 'boolean
  :group 'decknix)

(defun decknix-agent-toggle-resume-full-context ()
  "Toggle whether resume restores prior context natively or starts fresh."
  (interactive)
  (setq decknix-agent-resume-load-full-context
        (not decknix-agent-resume-load-full-context))
  (message "Resume: %s"
           (if decknix-agent-resume-load-full-context
               "native session/resume — context restored, no primer turn"
             "fresh session + continuation primer (empty context window)")))

(defun decknix--agent-resume-native-p (session-id supports-resume)
  "Return non-nil when SESSION-ID should be resumed natively over ACP.
True only when a resume target SESSION-ID is pending AND the connected
agent advertised the ACP `session/resume' capability (SUPPORTS-RESUME).

Pure predicate so it can be exercised without a live ACP session; the
orchestration (the advice below) supplies both arguments from buffer
state.  Requires the *resume* capability specifically.

Retained for the `session/resume' decision alone; the full choice now
lives in `decknix--agent-resume-native-method', which also knows about
`session/load'."
  (and (stringp session-id)
       (not (string-empty-p session-id))
       supports-resume
       t))

(defun decknix--agent-resume-native-method (session-id supports-resume
                                                       supports-load)
  "Return how to restore SESSION-ID natively: `resume', `load', or nil.

SUPPORTS-RESUME / SUPPORTS-LOAD are the bridge's advertised ACP
capabilities.  Pure, so the decision is testable without a live session.

`resume' is preferred when both are on offer.  Both restore real context
into the model, but they differ in what reaches the CLIENT:
`session/resume' restores server-side and replays nothing, whereas
`session/load' replays the whole transcript back as `session/update'
notifications.  Only one side may render the history, so the cheaper,
quieter call wins when there is a choice (see
`decknix--agent-resume-bridge-replays-p').

Accepting `load' at all is what fixes pi.  The old predicate asked only
about `session/resume', so pi -- which advertises `loadSession' and not
`sessionCapabilities.resume' -- was classed as incapable and fell
through to the continuation primer on every resume.  It was never
incapable: pi-acp's `loadSession' calls `restoreSession', which spawns
the pi CLI with `--session <path>', so the model genuinely gets its
conversation back.  We were paying for a full model turn of transcript
re-reading to work around a capability the bridge already had."
  (cond
   ((not (and (stringp session-id) (not (string-empty-p session-id)))) nil)
   (supports-resume 'resume)
   (supports-load 'load)
   (t nil)))

(defun decknix--agent-resume-bridge-replays-p (method)
  "Non-nil when METHOD makes the BRIDGE render the transcript, not us.

Exactly one side may render the history.  On the `load' path the bridge
replays every stored message as a `session/update', so our own
`decknix--agent-session-prepopulate' must be skipped or the buffer shows
the whole conversation twice.  On `resume' -- and when there is no native
restore at all -- nothing is replayed to the client, so we render.

Verified against pi-acp 0.0.31, whose `loadSession' walks
`proc.getMessages()' and emits a `user_message_chunk' (or assistant
chunk) per stored message under the SAME session id it was asked for, so
the updates route to this buffer normally."
  (eq method 'load))

(defun decknix--agent-resume-native-send (session-id args orig-fn &optional method)
  "Send an ACP session restore for SESSION-ID, falling back to ORIG-FN.
METHOD is `resume' (default) or `load'; see
`decknix--agent-resume-native-method'.
ARGS is the `&key' plist `agent-shell--initiate-session' was invoked
with (`:shell-buffer', `:on-session-init'); ORIG-FN is the advised
original, applied to ARGS if the request fails.

Runs in the shell buffer's context (its caller establishes it).  On
success mirrors the upstream session-load path -- populate session state
from the response, flag `decknix--agent-resume-native-done', and
finalize -- so `agent-shell--handle' proceeds to apply the saved model
and permission mode just as for a fresh session."
  (let* ((state (agent-shell--state))
         (shell-buffer (map-elt state :buffer))
         (on-session-init (plist-get args :on-session-init))
         (cwd (agent-shell--resolve-path (agent-shell-cwd)))
         (mcp-servers (agent-shell--mcp-servers)))
    (with-current-buffer shell-buffer
      ;; Every fragment this module writes MUST go through the
      ;; `bootstrapping' helper, which pins `:above-last-prompt t'.
      ;; Calling `agent-shell--update-fragment' directly (as this did)
      ;; defaults that to nil and lands the fragment inline at
      ;; `point-max' -- i.e. BELOW the live prompt, tagged `field
      ;; output'.  That one misplaced fragment makes
      ;; `agent-shell--live-input-prompt-p' false from then on, so every
      ;; later bootstrapping fragment cascades below the prompt too and
      ;; the buffer ends in read-only output with no prompt to type at.
      (agent-shell--update-bootstrapping-fragment
       :state (agent-shell--state)
       :block-id "starting"
       :body (format "\n\nResuming session %s..." session-id)
       :append t))
    ;; `session/load' MUST go through the request-tracking sender.  The
    ;; bridge replays the whole transcript as `session/update's WHILE the
    ;; request is in flight, and every handler that renders them gates on
    ;; `agent-shell--active-requests-p'.  Sent raw, the replay arrives
    ;; with nothing to attach to and each chunk is reported as
    ;; "Out of turn user_message_chunk - ACP server bug" instead of
    ;; rendering as conversation -- blaming the bridge for our own
    ;; bookkeeping.  Upstream's replay path fakes the same entry for the
    ;; same reason; here the request really is in flight, so tracking it
    ;; honestly is enough.
    ;;
    ;; `session/resume' deliberately keeps the raw sender: it replays
    ;; nothing, so it needs no tracking, and leaving a working path
    ;; untouched avoids shifting where its bootstrapping fragments land
    ;; (several handlers place output using `:above-last-prompt (not
    ;; active-requests)').
    (funcall
     (if (and (eq method 'load) (fboundp 'agent-shell--send-request))
         (lambda (&rest args) (apply #'agent-shell--send-request :state state args))
       (lambda (&rest args) (apply #'acp-send-request args)))
     :client (map-elt state :client)
     :request (if (eq method 'load)
                  (acp-make-session-load-request
                   :session-id session-id
                   :cwd cwd
                   :mcp-servers mcp-servers)
                (acp-make-session-resume-request
                 :session-id session-id
                 :cwd cwd
                 :mcp-servers mcp-servers))
     :buffer shell-buffer
     :on-success
     (lambda (acp-response)
       (agent-shell--set-session-from-response
        :acp-response acp-response
        :acp-session-id session-id)
       (when (buffer-live-p shell-buffer)
         (with-current-buffer shell-buffer
           (setq decknix--agent-resume-native-done t))
         ;; The transcript is already rendered, so the live prompt ends
         ;; up far below wherever point was left.  Follow it down once
         ;; the last bootstrapping fragment has been written.
         (decknix--agent-resume-focus-prompt-on-init shell-buffer))
       ;; Finalize FIRST, then write the marker.  `finalize-session-init'
       ;; is what emits the setup sections (config options, models,
       ;; modes, commands), and those fold into the collapsed
       ;; `Agent shell setup' group.  `agent-shell-ui' groups only a
       ;; CONTIGUOUS run, so writing the marker before finalize drops it
       ;; into the middle of that run -- where it must either join the
       ;; group or split it in two.  Written afterwards it lands below
       ;; the whole run and stays visible at top level, which is where a
       ;; "✓ Resuming session" confirmation belongs.
       (agent-shell--finalize-session-init :on-session-init on-session-init)
       (agent-shell--update-bootstrapping-fragment
        :state (agent-shell--state)
        :block-id "resumed_session"
        :label-left (format "%s %s"
                            (agent-shell--make-status-kind-label :status "completed")
                            (propertize "Resuming session" 'font-lock-face
                                        'font-lock-doc-markup-face))
        :expanded t
        :body ""))
     :on-failure
     (lambda (_error _raw-message)
       (with-current-buffer shell-buffer
         (agent-shell--update-bootstrapping-fragment
          :state (agent-shell--state)
          :block-id "starting"
          :body (concat "\n\nCould not resume session over ACP; "
                        "starting fresh with a continuation primer...")
          :append t)
         ;; The load path told the resume orchestration NOT to
         ;; prepopulate, because a successful `session/load' replays the
         ;; transcript itself.  A failed one replays nothing, so without
         ;; this the fallback session comes up with an empty buffer --
         ;; the primer would tell the model it is continuing a
         ;; conversation the user cannot see.  Restore the history we
         ;; deliberately skipped before handing back to `session/new'.
         (when (eq method 'load)
           (setq decknix--agent-resume-native-method nil)
           (ignore-errors
             (decknix--agent-session-prepopulate
              session-id (if (boundp 'decknix-agent-session-history-count)
                             decknix-agent-session-history-count
                           0)))))
       (apply orig-fn args)))))

(defun decknix--agent-resume-focus-prompt (shell-buf)
  "Put point on SHELL-BUF's live prompt at `point-max'.
No-op on a dead buffer.

Also moves the point of every window showing SHELL-BUF: a buffer's own
point is not what a displayed window scrolls to, so setting only the
former leaves the cursor visibly parked where it was.  Scrolling is
deliberately NOT forced -- redisplay moves a window to follow its point,
and setting `window-start' by hand only fights the display engine."
  (when (buffer-live-p shell-buf)
    (with-current-buffer shell-buf
      (goto-char (point-max))
      (dolist (window (get-buffer-window-list shell-buf nil t))
        (set-window-point window (point-max))))))

(defun decknix--agent-resume-focus-prompt-on-init (shell-buf)
  "Focus SHELL-BUF's prompt once ACP initialization has fully finished.

Upstream only moves point to the prompt when it had to CREATE one:

    (unless comint-last-prompt
      (shell-maker-finish-output ...)
      (goto-char (point-max)))

A resumed buffer already carries the early prompt emitted at shell
creation, so that branch is skipped and point is never moved.  On a fresh
session it makes no difference -- the buffer is one screenful.  On a
resumed session the replayed transcript and the whole bootstrap handshake
sit between them, so point stays parked at the stale
`<shell-maker-failed-command>' marker near the top while the live prompt
is tens of kB below.  The cursor is then sitting in read-only output:
typing raises \"Buffer is read-only\" and the session reads as ready but
with nowhere to type.

Waits for `init-finished' rather than `prompt-ready': the latter fires
with the set-model and set-session-mode fragments still to come, and each
of those writes more text above the prompt.

Fires exactly once, then unsubscribes, so a later `init-finished' cannot
yank point away from something the user has since typed."
  (let ((done nil)
        (token nil))
    (setq token
          (agent-shell-subscribe-to
           :shell-buffer shell-buf
           :event 'init-finished
           :on-event
           (lambda (_event)
             (unless done
               (setq done t)
               (when token
                 (agent-shell-unsubscribe :subscription token))
               (decknix--agent-resume-focus-prompt shell-buf)))))
    token))

(defun decknix--agent-resume-native-initiate-session (orig-fn &rest args)
  "Around-advice for `agent-shell--initiate-session': native ACP resume.
When the shell buffer carries a pending `decknix--agent-resume-target-sid'
and the agent advertised `:supports-session-resume', resume that exact
session over ACP instead of creating a new one.  Otherwise defer to
ORIG-FN unchanged.  ARGS is ORIG-FN's `&key' plist."
  (let* ((state (agent-shell--state))
         (buf (map-elt state :buffer))
         (sid (and (buffer-live-p buf)
                   (buffer-local-value 'decknix--agent-resume-target-sid buf)))
         (supports-resume (map-elt state :supports-session-resume))
         (supports-load (map-elt state :supports-session-load))
         (method (and decknix-agent-resume-load-full-context
                      (decknix--agent-resume-native-method
                       sid supports-resume supports-load))))
    ;; Restore context natively whenever the bridge can (the default).
    ;; Opting out, or a bridge advertising NEITHER capability, falls
    ;; through to `session/new' + the continuation primer — which costs a
    ;; whole model turn to re-read the transcript, so it is the
    ;; degradation path rather than the fast one.
    (if method
        (progn
          ;; Publish the decision before the request goes out: the
          ;; prepopulation site reads this to decide whether to render
          ;; the transcript, and on the `load' path the bridge does that
          ;; for us.  Synchronous so it cannot lose a race with the
          ;; resume orchestration's timer.
          (when (buffer-live-p buf)
            (with-current-buffer buf
              (setq decknix--agent-resume-native-method method)))
          (decknix--agent-resume-native-send sid args orig-fn method))
      (apply orig-fn args))))

(provide 'decknix-agent-resume-native)
;;; decknix-agent-resume-native.el ends here
