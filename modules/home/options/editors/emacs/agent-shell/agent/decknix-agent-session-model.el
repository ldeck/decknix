;;; decknix-agent-session-model.el --- Per-conversation auggie model overrides -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-tags-store "0.1"))
;; Keywords: agent, agent-shell, decknix, persistence, model

;;; Commentary:
;;
;; Per-conversation model override layer extracted from the
;; agent-shell heredoc (main-bulk).  The global default model for
;; new sessions lives in `~/.augment/settings.json' (declared via
;; `decknix.cli.auggie.settings.model').  Any per-conversation
;; override the user makes mid-session with `C-c C-v' is persisted
;; here against the conv-key inside the same
;; `~/.config/decknix/agent-sessions.json' store as tags / linked
;; PRs / saved workspaces, so resume-time we can pass `--model
;; <id>' to auggie and continue on the same agent.
;;
;; Two entry points:
;;
;;   `decknix--agent-session-model-for-conv-key'
;;       Return the saved model-id for CONV-KEY, or nil when no
;;       override has been recorded.  Read by the resume path in
;;       main-bulk to compute the `--model' arg.
;;   `decknix--agent-session-save-model-for-conv-key'
;;       Persist MODEL-ID for CONV-KEY.  Creates the conversation
;;       entry if it doesn't exist (with empty tags / sessions
;;       lists, matching the shape used by the other accessors).
;;       Called from the on-success callback of the interactive
;;       `decknix-agent-set-session-model' command -- which itself
;;       stays in the heredoc per AGENTS.md Rule 2 because it
;;       wraps the upstream `agent-shell-set-session-model' UI
;;       verb.

;;; Code:

(require 'decknix-agent-tags-store)

(defun decknix--agent-session-model-for-conv-key (conv-key)
  "Return saved auggie model-id for CONV-KEY, or nil."
  (when conv-key
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (gethash conv-key convs)))
      (when (hash-table-p entry)
        (gethash "model" entry)))))

(defun decknix--agent-session-save-model-for-conv-key
    (conv-key model-id)
  "Persist auggie MODEL-ID for CONV-KEY in agent-sessions.json."
  (when (and conv-key model-id)
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (or (gethash conv-key convs)
                      (let ((h (make-hash-table :test 'equal)))
                        (puthash "tags" nil h)
                        (puthash "sessions" nil h)
                        h))))
      (puthash "model" model-id entry)
      (puthash conv-key entry convs)
      (decknix--agent-tags-write store))))

(provide 'decknix-agent-session-model)
;;; decknix-agent-session-model.el ends here
