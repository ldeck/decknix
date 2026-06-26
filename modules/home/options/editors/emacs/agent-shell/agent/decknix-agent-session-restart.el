;;; decknix-agent-session-restart.el --- Resilient in-place session restart -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, session, restart

;;; Commentary:
;;
;; `C-c s R' — restart the current agent-shell session in place.
;;
;; The upstream sidebar restart (`agent-shell-workspace-sidebar-restart')
;; only operates on a *live* buffer and starts a *blank* session, losing
;; the conversation.  That is the wrong tool when a resumed session has
;; gone `killed' (its agent process exited): the buffer corpse cannot be
;; restarted upstream, and even a healthy one loses its history.
;;
;; This command instead re-resumes the conversation from its latest
;; on-disk snapshot via `decknix--agent-session-resume', restoring the
;; workspace, provider, model, and history — so it revives even a
;; `killed' buffer.  The current buffer is killed first (which saves the
;; session and frees the buffer name) so resume does not dedupe back onto
;; the stuck buffer and the revived session reclaims its label.
;;
;; Two layers, per AGENTS.md Rule 2:
;;   - `decknix--agent-session-restart-name-from-buffer' (pure, tested)
;;     recovers the user-facing name from a `*<Provider>: <name>*' buffer.
;;   - `decknix-agent-session-restart' (interactive) orchestrates the
;;     kill + resume.  Its cross-package callees are forward-declared
;;     below and resolve at runtime (main-bulk loads first).

;;; Code:

(require 'subr-x)

;; Forward declarations -- live in `decknix-agent-shell-main' (main-bulk)
;; and sibling agent/ packages, all loaded before this file by the
;; heredoc, so they resolve at call time.
(declare-function decknix--agent-buffer-session-id
                  "decknix-agent-buffer-lookup" (&optional buf))
(declare-function decknix--agent-current-conv-key
                  "decknix-agent-buffer-lookup" ())
(declare-function decknix--agent-latest-session-id-for-conv-key
                  "decknix-agent-conv-resolve" (conv-key))
(declare-function decknix--agent-tags-for-conv-key
                  "decknix-agent-tags-read" (conv-key))
(declare-function decknix--agent-session-derive-name
                  "decknix-agent-session-format"
                  (tags &optional workspace branch first-message sid))
(declare-function decknix--agent-session-resume
                  "decknix-agent-shell-main"
                  (session-id history-count &optional display-name
                              workspace conv-key search-term))

;; Buffer-locals owned by `decknix-agent-shell-main'; declared so the
;; byte-compiler knows they are special variables we read here.
(defvar decknix--agent-conv-key)
(defvar decknix--agent-session-workspace)
(defvar decknix-agent-session-history-count)

(defun decknix--agent-session-restart-name-from-buffer (buffer-name)
  "Extract the user-facing session name from BUFFER-NAME.
Agent-shell session buffers are named `*<Provider>: <name>*' (e.g.
`*Auggie: my-feature*', `*Claude: pr-decknix-42*').  Returns <name>,
ignoring any `<N>' uniquifier Emacs appended after the closing `*'.

Returns nil when BUFFER-NAME is not in that form (e.g. the upstream
`<Provider> Agent @ <ws>' default), so callers can fall back to a
tag-derived name."
  (when (and buffer-name
             (string-match "\\`\\*[^:]+: \\(.+?\\)\\*" buffer-name))
    (match-string 1 buffer-name)))

(defun decknix-agent-session-restart ()
  "Restart the current agent-shell session in place.
Kills this buffer (which saves the session) and re-resumes the same
conversation, restoring its workspace, provider, model, and history.

Unlike the upstream sidebar restart — which starts a blank session and
works only on a live buffer — this resumes from the latest on-disk
snapshot, so it revives even a `killed' buffer whose agent process has
already exited."
  (interactive)
  (unless (derived-mode-p 'agent-shell-mode)
    (user-error "Not in an agent-shell buffer"))
  (let* ((buf (current-buffer))
         (stored-sid (decknix--agent-buffer-session-id buf))
         (conv-key (or (and (bound-and-true-p decknix--agent-conv-key)
                            decknix--agent-conv-key)
                       (decknix--agent-current-conv-key)))
         ;; Prefer the newest snapshot for this conversation (auggie
         ;; rewrites the session file on every interrupt/compose) and
         ;; fall back to the buffer's own id when no conv-key resolves.
         (sid (or (and conv-key
                       (decknix--agent-latest-session-id-for-conv-key conv-key))
                  stored-sid))
         (workspace (or (and (bound-and-true-p decknix--agent-session-workspace)
                             decknix--agent-session-workspace)
                        default-directory))
         (tags (and conv-key (decknix--agent-tags-for-conv-key conv-key)))
         ;; Preserve the label: tags drive the canonical name (matching
         ;; the render path); otherwise reuse the current buffer's name.
         (display-name (if tags
                           (decknix--agent-session-derive-name tags)
                         (decknix--agent-session-restart-name-from-buffer
                          (buffer-name buf))))
         (history-count (if (boundp 'decknix-agent-session-history-count)
                            decknix-agent-session-history-count
                          20)))
    (unless sid
      (user-error "Cannot restart: no session ID for this buffer"))
    (when (y-or-n-p "Restart this agent session? ")
      ;; Kill BEFORE resume: a stuck/dead buffer shares the conv-key we
      ;; are reviving, so leaving it alive would make resume dedupe
      ;; straight back onto it; killing also frees the name so the
      ;; revived session reclaims it instead of getting a `<2>' suffix.
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf))
      (decknix--agent-session-resume sid history-count
                                     display-name workspace conv-key)
      (message "Restarting session…"))))

(provide 'decknix-agent-session-restart)
;;; decknix-agent-session-restart.el ends here
