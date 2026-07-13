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
;; Why `session/resume' and never `session/load': the bridge's
;; `resumeSession' restores context WITHOUT replaying the transcript back
;; to the client, so it composes with our own on-disk buffer
;; prepopulation (`decknix--agent-session-prepopulate').  `session/load'
;; replays history as `session/update's, which would double-render
;; against the prepopulated buffer.  Hence the capability gate is
;; `:supports-session-resume', not `:supports-session-load'.

;;; Code:

(require 'map)

;; agent-shell / acp internals resolved at runtime (forward-declared to
;; keep the byte-compiler warning-clean; this module is loaded after
;; agent-shell in the heredoc).
(declare-function agent-shell--state "agent-shell")
(declare-function agent-shell--update-fragment "agent-shell")
(declare-function agent-shell--make-status-kind-label "agent-shell")
(declare-function agent-shell--set-session-from-response "agent-shell")
(declare-function agent-shell--finalize-session-init "agent-shell")
(declare-function agent-shell--resolve-path "agent-shell")
(declare-function agent-shell-cwd "agent-shell")
(declare-function agent-shell--mcp-servers "agent-shell")
(declare-function acp-send-request "acp")
(declare-function acp-make-session-resume-request "acp")

(defvar-local decknix--agent-resume-target-sid nil
  "ACP session id this buffer should resume natively over `session/resume'.
Set by the resume orchestration before session init, for providers
without a `:resume-cli-flag' (Claude, Pi).  When nil, the session is
created the normal way (`session/new').")

(defvar-local decknix--agent-resume-native-done nil
  "Non-nil once this buffer's session was resumed natively over ACP.
Gates the continuation primer: when `session/resume' loaded real context
into the model there is nothing to prime, so the primer is suppressed
\(see `decknix--agent-resume-primer-on-ready').")

(defun decknix--agent-resume-native-p (session-id supports-resume)
  "Return non-nil when SESSION-ID should be resumed natively over ACP.
True only when a resume target SESSION-ID is pending AND the connected
agent advertised the ACP `session/resume' capability (SUPPORTS-RESUME).

Pure predicate so it can be exercised without a live ACP session; the
orchestration (the advice below) supplies both arguments from buffer
state.  Requires the *resume* capability specifically -- `session/resume'
restores context without replaying the transcript, so it composes with
our buffer prepopulation, whereas `session/load' would double-render."
  (and (stringp session-id)
       (not (string-empty-p session-id))
       supports-resume
       t))

(defun decknix--agent-resume-native-send (session-id args orig-fn)
  "Send an ACP `session/resume' for SESSION-ID, falling back to ORIG-FN.
ARGS is the `&key' plist `agent-shell--initiate-session' was invoked
with (`:shell-buffer', `:on-session-init'); ORIG-FN is the advised
original, applied to ARGS if the resume request fails.

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
      (agent-shell--update-fragment
       :state (agent-shell--state)
       :namespace-id "bootstrapping"
       :block-id "starting"
       :body (format "\n\nResuming session %s..." session-id)
       :append t))
    (acp-send-request
     :client (map-elt state :client)
     :request (acp-make-session-resume-request
               :session-id session-id
               :cwd cwd
               :mcp-servers mcp-servers)
     :buffer shell-buffer
     :on-success
     (lambda (acp-response)
       (agent-shell--set-session-from-response
        :acp-response acp-response
        :acp-session-id session-id)
       (when (buffer-live-p shell-buffer)
         (with-current-buffer shell-buffer
           (setq decknix--agent-resume-native-done t)))
       (agent-shell--update-fragment
        :state (agent-shell--state)
        :namespace-id "bootstrapping"
        :block-id "resumed_session"
        :label-left (format "%s %s"
                            (agent-shell--make-status-kind-label :status "completed")
                            (propertize "Resuming session" 'font-lock-face
                                        'font-lock-doc-markup-face))
        :expanded t
        :body "")
       (agent-shell--finalize-session-init :on-session-init on-session-init))
     :on-failure
     (lambda (_error _raw-message)
       (with-current-buffer shell-buffer
         (agent-shell--update-fragment
          :state (agent-shell--state)
          :namespace-id "bootstrapping"
          :block-id "starting"
          :body (concat "\n\nCould not resume session over ACP; "
                        "starting fresh with a continuation primer...")
          :append t))
       (apply orig-fn args)))))

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
         (supports-resume (map-elt state :supports-session-resume)))
    (if (decknix--agent-resume-native-p sid supports-resume)
        (decknix--agent-resume-native-send sid args orig-fn)
      (apply orig-fn args))))

(provide 'decknix-agent-resume-native)
;;; decknix-agent-resume-native.el ends here
