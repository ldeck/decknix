;;; decknix-agent-provider.el --- Agent backend provider registry -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix

;;; Commentary:
;;
;; This module provides an abstraction layer over multiple AI agent
;; backends (auggie, claude-code/anthropic, pi).  It allows the
;; rest of decknix to operate on a generic "provider" instead of
;; hardcoding auggie-specific variables and functions.

;;; Code:

(require 'map)

(defvar decknix-agent-provider-registry nil
  "Alist mapping provider IDs (symbols) to property lists of attributes.
Attributes include:
  :make-config-fn            Function returning the base agent-shell config.
  :acp-command-var           Variable symbol holding the command list.
  :auth-var                  Variable symbol holding authentication settings.
  :env-var                   Variable symbol holding environment variables.
  :sessions-dir              Directory for session persistence.
                             Default is ~/.augment/sessions.
  :session-file-extension    File extension for transcripts (e.g. \".json\").
  :session-jq-filter          JQ filter string for metadata extraction.
  :history-file              Global history log path (optional).
  :label                     Human-readable label for the provider.
  :glyph                     Single-character glyph for the header-line.
  :supports-workspace-root   Boolean; true if the ACP command supports
                             --workspace-root.
  :model-launch-flag         CLI flag string used to pin a model at
                             launch (e.g. \"--model\" for auggie).
                             When absent/nil the provider cannot pin a
                             model on the command line; the saved
                             per-conversation model is instead replayed
                             over ACP (session/set_model) after a
                             resumed session reports ready.")

(defvar decknix-agent-default-provider 'claude-code
  "The default AI agent provider to use for new sessions.
Used by QUICK new-session (`C-u C-c A n') and the session-resume
fallback when a session's provider cannot be determined.  Regular
`C-c A n' still prompts for a provider when more than one is
registered.")

(defun decknix-agent-register-provider (id props)
  "Register a provider ID with PROPS.
ID is a symbol (e.g. `auggie').  PROPS is a property list."
  (setf (alist-get id decknix-agent-provider-registry) props))

(defun decknix-agent-get-provider (id)
  "Return the property list for provider ID, or nil."
  (alist-get id decknix-agent-provider-registry))

(defun decknix-agent-require-provider (id)
  "Return the property list for provider ID, or signal an error."
  (or (decknix-agent-get-provider id)
      (error "Unknown agent provider: %s" id)))

(defun decknix-agent-provider-all-ids ()
  "Return a list of all registered provider IDs."
  (mapcar #'car decknix-agent-provider-registry))

(defun decknix-agent-provider-select ()
  "Prompt the user to select an agent provider and return its ID."
  (let* ((ids (decknix-agent-provider-all-ids))
         (choices (mapcar (lambda (id)
                            (cons (decknix-agent-provider-label id) id))
                          ids)))
    (if (= (length ids) 1)
        (car ids)
      (let ((choice (completing-read "Agent provider: " choices nil t)))
        (cdr (assoc choice choices))))))

;; -- Provider attribute accessors --------------------------------

(defun decknix-agent-provider-make-config-fn (id)
  "Return the :make-config-fn for provider ID."
  (plist-get (decknix-agent-require-provider id) :make-config-fn))

(defun decknix-agent-provider-acp-command (id)
  "Return the value of :acp-command-var for provider ID."
  (let ((var (plist-get (decknix-agent-require-provider id) :acp-command-var)))
    (and var (boundp var) (symbol-value var))))

(defun decknix-agent-provider-auth (id)
  "Return the value of :auth-var for provider ID."
  (let ((var (plist-get (decknix-agent-require-provider id) :auth-var)))
    (and var (boundp var) (symbol-value var))))

(defun decknix-agent-provider-env (id)
  "Return the value of :env-var for provider ID."
  (let ((var (plist-get (decknix-agent-require-provider id) :env-var)))
    (and var (boundp var) (symbol-value var))))

(defun decknix-agent-provider-sessions-dir (id)
  "Return the :sessions-dir for provider ID."
  (let ((dir (plist-get (decknix-agent-require-provider id) :sessions-dir)))
    (if dir (expand-file-name dir)
      (expand-file-name "~/.augment/sessions"))))

(defun decknix-agent-provider-session-file-extension (id)
  "Return the :session-file-extension for provider ID."
  (or (plist-get (decknix-agent-require-provider id) :session-file-extension)
      ".json"))


(defun decknix-agent-provider-session-jq-filter (id)
  "Return the :session-jq-filter for provider ID."
  (plist-get (decknix-agent-require-provider id) :session-jq-filter))

(defun decknix-agent-provider-history-file (id)
  "Return the :history-file for provider ID."
  (let ((file (plist-get (decknix-agent-require-provider id) :history-file)))
    (when file (expand-file-name file))))

(defun decknix-agent-provider-label (id)
  "Return the human-readable :label for provider ID.
Falls back to the symbol name when :label is absent."
  (or (plist-get (decknix-agent-require-provider id) :label)
      (symbol-name id)))

(defun decknix-agent-provider-glyph (id)
  "Return the :glyph for provider ID."
  (plist-get (decknix-agent-require-provider id) :glyph))

(defun decknix-agent-provider-supports-workspace-root (id)
  "Return whether provider ID supports the --workspace-root flag."
  (plist-get (decknix-agent-require-provider id) :supports-workspace-root))

(defun decknix-agent-provider-model-launch-flag (id)
  "Return the CLI flag provider ID uses to pin a model at launch, or nil.
When nil, the provider does not accept a model flag on the command
line; the saved per-conversation model is instead replayed over ACP
\(`session/set_model') after a resumed session reports ready."
  (plist-get (decknix-agent-require-provider id) :model-launch-flag))

;; -- Model persistence strategy ----------------------------------

(defun decknix--agent-model-replay-needed-p (provider-id model)
  "Return non-nil when MODEL must be replayed over ACP for PROVIDER-ID.
Replay (an ACP `session/set_model' after the resumed session
reports ready) is the fallback for providers that cannot pin a
model at launch -- i.e. those WITHOUT a `:model-launch-flag' (Claude,
Pi).  Auggie and any other provider that declares a launch flag pin
the model on the command line instead, so they never replay.  MODEL
must be a non-empty string for replay to apply."
  (and (stringp model)
       (not (string-empty-p model))
       (not (decknix-agent-provider-model-launch-flag provider-id))))

;; -- High-level builders -----------------------------------------

(declare-function agent-shell--make-acp-client "agent-shell")

(defun decknix--agent-command-build (provider-id workspace &optional model session-id)
  "Build the ACP command line for PROVIDER-ID.
WORKSPACE is the directory.  MODEL is optional override.
SESSION-ID is optional for resume.

MODEL is placed on the command line only when PROVIDER-ID declares a
`:model-launch-flag' (e.g. auggie's \"--model\"); the flag string is
used verbatim so a provider can use an equivalent switch.  Providers
without a launch flag (Claude, Pi) omit MODEL here -- it is replayed
over ACP after resume instead (see
`decknix--agent-model-replay-needed-p')."
  (let* ((base-cmd (decknix-agent-provider-acp-command provider-id))
         (ws-args  (when (and (stringp workspace)
                              (not (string-empty-p workspace))
                              (decknix-agent-provider-supports-workspace-root provider-id))
                     (list "--workspace-root" workspace)))
         (model-flag (decknix-agent-provider-model-launch-flag provider-id))
         (model-args (when (and model-flag
                                (stringp model)
                                (not (string-empty-p model)))
                       (list model-flag model)))
         (resume-args (when session-id
                        (list "--resume" session-id))))
    (append base-cmd ws-args model-args resume-args)))

(defun decknix--agent-make-config (provider-id augmented-cmd)
  "Return an agent-shell config for PROVIDER-ID with AUGMENTED-CMD.
The config includes a `:client-maker' closure that encapsulates the
command, parameters, and environment variables."
  (let* ((make-fn (decknix-agent-provider-make-config-fn provider-id))
         (base (funcall make-fn)))
    (setf (alist-get :client-maker base)
          (eval `(lambda (buffer)
                   (agent-shell--make-acp-client
                    :command ,(car augmented-cmd)
                    :command-params ',(cdr augmented-cmd)
                    :environment-variables
                    (let ((auth (decknix-agent-provider-auth ',provider-id))
                          (env  (decknix-agent-provider-env ',provider-id)))
                      ;; Current decknix logic: if auth exists and is not :none, use env.
                      ;; This matches auggie's :login pattern and handles nil env safely.
                      env)
                    :context-buffer buffer)) t))
    base))

;; -- Provider identity + glyph for pickers/filters ----------------
;;
;; The session/buffer switchers, saved-session picker and grep all
;; prefix a single-char provider glyph (A/C/P) and support hiding
;; providers.  These pure helpers resolve a provider id from a session
;; alist or a live buffer and map it to a glyph or a visibility test,
;; so the interactive pickers carry no provider-registry logic.

;; Buffer-local in every agent-shell buffer (owned by the session
;; layer / command-discover); declared here with a nil default so the
;; byte-compiler treats it as a special variable we read via
;; `buffer-local-value'.  Identical initialiser to the owning defvar
;; so the two can't drift.
(defvar decknix--agent-provider-id nil)

(defun decknix-agent-provider-glyph-safe (id)
  "Return the glyph string for provider ID, or \"?\" when unknown.
Unlike `decknix-agent-provider-glyph' this never signals on an
unregistered ID, so picker columns stay aligned for a session whose
recorded provider is no longer registered."
  (let ((props (and id (decknix-agent-get-provider id))))
    (or (and props (plist-get props :glyph)) "?")))

(defun decknix-agent-session-provider (session)
  "Return the provider id (symbol) that owns SESSION alist.
Uses the stamped `providerId', falling back to
`decknix-agent-default-provider' when absent."
  (or (alist-get 'providerId session) decknix-agent-default-provider))

(defun decknix-agent-buffer-provider (buf)
  "Return the provider id (symbol) for live agent-shell BUF.
Reads the buffer-local `decknix--agent-provider-id', falling back to
`decknix-agent-default-provider'."
  (or (and (buffer-live-p buf)
           (buffer-local-value 'decknix--agent-provider-id buf))
      decknix-agent-default-provider))

(defun decknix-agent-provider-glyph-for-session (session)
  "Return the provider glyph string for SESSION alist."
  (decknix-agent-provider-glyph-safe (decknix-agent-session-provider session)))

(defun decknix-agent-provider-glyph-for-buffer (buf)
  "Return the provider glyph string for live agent-shell BUF."
  (decknix-agent-provider-glyph-safe (decknix-agent-buffer-provider buf)))

(defun decknix-agent-session-visible-p (session hidden-ids)
  "Non-nil when SESSION's provider is not a member of HIDDEN-IDS."
  (not (memq (decknix-agent-session-provider session) hidden-ids)))

(defun decknix-agent-buffer-visible-p (buf hidden-ids)
  "Non-nil when live BUF's provider is not a member of HIDDEN-IDS."
  (not (memq (decknix-agent-buffer-provider buf) hidden-ids)))

(provide 'decknix-agent-provider)
;;; decknix-agent-provider.el ends here
