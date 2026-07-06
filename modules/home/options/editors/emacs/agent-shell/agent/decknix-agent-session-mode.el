;;; decknix-agent-session-mode.el --- Per-conversation session/permission mode overrides -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-tags-store "0.1"))
;; Keywords: agent, agent-shell, decknix, persistence, mode

;;; Commentary:
;;
;; Per-conversation session/permission-mode override layer, a sibling
;; of `decknix-agent-session-model'.  The default mode for user-created
;; sessions comes from the `new-session' purpose (e.g. Claude "auto",
;; see `decknix-agent-purpose-resolve').  Any per-conversation override
;; the user makes mid-session with `C-c C-m' (`agent-shell-set-session-
;; mode', wrapped by `decknix-agent-set-session-mode') is persisted here
;; against the conv-key inside the same `~/.config/decknix/agent-
;; sessions.json' store as tags / linked PRs / saved workspaces / model
;; overrides, so at resume/fork time we can re-apply the exact mode the
;; session was left in instead of falling back to the provider default
;; (which would silently re-enable per-command permission prompts).
;;
;; Two entry points, mirroring the model store:
;;
;;   `decknix--agent-session-mode-for-conv-key'
;;       Return the saved mode-id for CONV-KEY, or nil when no
;;       override has been recorded.  Read by the resume and fork
;;       paths in main-bulk, which fall back to the `new-session'
;;       purpose default when this returns nil.
;;   `decknix--agent-session-save-mode-for-conv-key'
;;       Persist MODE-ID for CONV-KEY.  Creates the conversation
;;       entry if it doesn't exist (with empty tags / sessions
;;       lists, matching the shape used by the other accessors).
;;       Called from the on-success callback of the interactive
;;       `decknix-agent-set-session-mode' command -- which itself
;;       stays in the heredoc per AGENTS.md Rule 2 because it wraps
;;       the upstream `agent-shell-set-session-mode' UI verb.

;;; Code:

(require 'decknix-agent-tags-store)

(defun decknix--agent-session-mode-for-conv-key (conv-key)
  "Return saved session/permission mode-id for CONV-KEY, or nil."
  (when conv-key
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (gethash conv-key convs)))
      (when (hash-table-p entry)
        (gethash "mode" entry)))))

(defun decknix--agent-session-save-mode-for-conv-key
    (conv-key mode-id)
  "Persist session/permission MODE-ID for CONV-KEY in agent-sessions.json."
  (when (and conv-key mode-id)
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (or (gethash conv-key convs)
                      (let ((h (make-hash-table :test 'equal)))
                        (puthash "tags" nil h)
                        (puthash "sessions" nil h)
                        h))))
      (puthash "mode" mode-id entry)
      (puthash conv-key entry convs)
      (decknix--agent-tags-write store))))

(provide 'decknix-agent-session-mode)
;;; decknix-agent-session-mode.el ends here
