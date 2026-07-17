;;; decknix-agent-session-id.el --- Current/require session-id + conv-key accessors -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, session

;;; Commentary:
;;
;; Buffer-scoped accessors for the auggie CLI session ID +
;; derived conversation key carved out of `decknix-agent-shell-
;; main' (main-bulk) into the same `agent-shell/agent/' cluster
;; as the rest of the per-conversation persistence helpers.
;;
;; Three entry points -- one read-only and two error-raising
;; require helpers used at the top of every interactive command
;; that needs a known session:
;;
;;   `decknix--agent-current-session-id'
;;       Returns the buffer-local
;;       `decknix--agent-auggie-session-id' when the buffer is
;;       in `agent-shell-mode' (or a derived mode); nil
;;       otherwise.  Pure read; no side effects.
;;
;;   `decknix--agent-require-session-id'
;;       Returns `current-session-id' or signals `user-error'
;;       with the canonical "(is it a resumed session?)"
;;       hint.  Used as the first form in every interactive
;;       command that operates on the current session.
;;
;;   `decknix--agent-require-conv-key'
;;       Returns the conversation key for the current session
;;       via `decknix--agent-conversation-key-for-session'
;;       (carved earlier into `decknix-agent-conv-resolve');
;;       signals `user-error' with the truncated session ID
;;       when the lookup misses.
;;
;; The buffer-local `decknix--agent-auggie-session-id' defvar
;; itself stays in main-bulk -- it is initialised inside the
;; agent-shell startup hook, which is a side-effect that
;; belongs in the heredoc by Rule 2.

;;; Code:

;; Forward declarations.  `agent-shell-mode' is provided by the
;; upstream agent-shell package and does not need a `declare-
;; function' / `defvar', but `derived-mode-p' is a built-in.
(declare-function decknix--agent-conversation-key-for-session
                  "decknix-agent-conv-resolve" (session-id &optional no-block))

;; The buffer-local session-id var is defined in main-bulk; we
;; reference it via `defvar' so the byte-compiler sees a binding
;; at compile time without us shadowing the real one.
(defvar decknix--agent-auggie-session-id)

(defun decknix--agent-current-session-id ()
  "Get the auggie session ID for the current buffer, or nil."
  (when (derived-mode-p 'agent-shell-mode)
    decknix--agent-auggie-session-id))

(defun decknix--agent-require-session-id ()
  "Get the current session ID or error."
  (or (decknix--agent-current-session-id)
      (user-error "No auggie session ID for this buffer (is it a resumed session?)")))

(defun decknix--agent-require-conv-key ()
  "Get the conversation key for the current session, or error."
  (let* ((session-id (decknix--agent-require-session-id))
         (conv-key (decknix--agent-conversation-key-for-session session-id)))
    (unless conv-key
      (user-error "Cannot determine conversation for session %s"
                  (substring session-id 0 8)))
    conv-key))

(provide 'decknix-agent-session-id)
;;; decknix-agent-session-id.el ends here
