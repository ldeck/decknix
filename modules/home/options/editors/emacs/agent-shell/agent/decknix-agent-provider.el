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
  :sessions-dir              Directory for session persistence (default ~/.augment/sessions).
  :session-file-extension    File extension for session transcripts (e.g. \".json\").
  :session-jq-filter          JQ filter string for metadata extraction.
  :history-file              Global history log path (optional).
  :label                     Human-readable label for the provider.
  :glyph                     Single-character glyph for the header-line.
  :supports-workspace-root   Boolean; true if the ACP command supports --workspace-root.")

(defvar decknix-agent-default-provider 'auggie
  "The default AI agent provider to use for new sessions.")

(defun decknix-agent-register-provider (id props)
  "Register a provider ID with PROPS.
ID is a symbol (e.g. 'auggie).  PROPS is a property list."
  (setf (alist-get id decknix-agent-provider-registry) props))

(defun decknix-agent-get-provider (id)
  "Return the property list for provider ID, or nil."
  (alist-get id decknix-agent-provider-registry))

(defun decknix-agent-require-provider (id)
  "Return the property list for provider ID, or signal an error."
  (or (decknix-agent-get-provider id)
      (error "Unknown agent provider: %s" id)))

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

;; -- High-level builders -----------------------------------------

(declare-function agent-shell--make-acp-client "agent-shell")

(defun decknix--agent-command-build (provider-id workspace &optional model session-id)
  "Build the ACP command line for PROVIDER-ID.
WORKSPACE is the directory.  MODEL is optional override.
SESSION-ID is optional for resume."
  (let* ((base-cmd (decknix-agent-provider-acp-command provider-id))
         (ws-args  (when (and (stringp workspace)
                              (not (string-empty-p workspace))
                              (decknix-agent-provider-supports-workspace-root provider-id))
                     (list "--workspace-root" workspace)))
         (model-args (when (and (stringp model)
                                (not (string-empty-p model)))
                       (list "--model" model)))
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

(provide 'decknix-agent-provider)
;;; decknix-agent-provider.el ends here
