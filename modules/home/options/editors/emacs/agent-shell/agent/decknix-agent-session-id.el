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

;; -- Detach helper: terminal resume commands for live sessions -----
;;
;; The agent runs as an ACP subprocess of the Emacs daemon, so a full
;; `decknix switch' (daemon restart) can drop long-running sessions.
;; The conversation state itself lives in the provider's transcript
;; (e.g. ~/.claude/projects/*.jsonl), so a session can be picked back
;; up from a terminal with `<cli> --resume <session-id>' — independent
;; of Emacs.  `decknix-agent-live-sessions-terminal' lists the live
;; sessions and prints exactly those commands so important agents can
;; be carried across a switch (or moved out of Emacs entirely).

(defvar decknix--agent-provider-id)
(defvar decknix--agent-session-workspace)
(declare-function agent-shell-buffers "agent-shell" ())

(defconst decknix--agent-terminal-resume-clis
  '((claude-code . "claude")
    (auggie      . "auggie"))
  "Map of provider-id -> terminal CLI that accepts `--resume <id>'.
Providers absent here have no known interactive resume CLI; their
sessions can still be reopened via the picker (\\[decknix-agent-session-picker]).")

(defun decknix--agent-terminal-resume-command (provider-id session-id workspace)
  "Return a shell command that resumes SESSION-ID in a terminal, or nil.
PROVIDER-ID selects the CLI (see `decknix--agent-terminal-resume-clis');
the command cd's into WORKSPACE first so the provider resolves the
right project."
  (let ((cli (alist-get provider-id decknix--agent-terminal-resume-clis)))
    (when (and cli session-id (stringp session-id)
               (not (string-empty-p session-id)))
      (format "(cd %s && %s --resume %s)"
              (shell-quote-argument (or workspace
                                        (expand-file-name default-directory)))
              cli session-id))))

(defun decknix-agent-live-sessions-terminal ()
  "List live agent sessions with terminal commands to resume them.

Pops a *live-agent-sessions* buffer whose lines can be run in a
terminal to carry a session across a `decknix switch' (or to move it
out of Emacs).  Resume state lives in the provider transcript, so the
resumed terminal process continues the same conversation.

Run the resume command AFTER Emacs has released the session (e.g. post
switch) to avoid two live clients on one conversation."
  (interactive)
  (let ((rows nil)
        (buffers (if (fboundp 'agent-shell-buffers)
                     (agent-shell-buffers)
                   (buffer-list))))
    (dolist (buf buffers)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when (derived-mode-p 'agent-shell-mode)
            (let* ((provider (bound-and-true-p decknix--agent-provider-id))
                   (sid (bound-and-true-p decknix--agent-auggie-session-id))
                   (ws (bound-and-true-p decknix--agent-session-workspace))
                   (cmd (and provider
                             (decknix--agent-terminal-resume-command
                              provider sid ws))))
              (push (list (buffer-name) provider sid ws cmd) rows))))))
    (setq rows (nreverse rows))
    (let ((resumable 0))
      (dolist (r rows) (when (nth 4 r) (setq resumable (1+ resumable))))
      (with-current-buffer (get-buffer-create "*live-agent-sessions*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "# %d live agent session(s) — %d resumable from a terminal\n"
                          (length rows) resumable))
          (insert "# Run a block in a terminal AFTER a switch has released the session.\n\n")
          (dolist (r rows)
            (let ((name (nth 0 r)) (provider (nth 1 r))
                  (sid (nth 2 r)) (cmd (nth 4 r)))
              (insert (format "# %s  [%s]%s\n" name (or provider "?")
                              (if sid (format "  %s" (substring sid 0 (min 8 (length sid)))) "")))
              (if cmd
                  (insert cmd "\n\n")
                (insert (format "# no terminal CLI for provider %s%s — reopen via the picker\n\n"
                                (or provider "?")
                                (if sid "" " (no session id yet)"))))))
          (when (null rows) (insert "# (no live agent-shell sessions)\n"))
          (goto-char (point-min))
          (view-mode 1))
        (display-buffer (current-buffer))))))

(provide 'decknix-agent-session-id)
;;; decknix-agent-session-id.el ends here
