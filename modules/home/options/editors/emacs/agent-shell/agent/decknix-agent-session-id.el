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
(defvar decknix--agent-conv-key)
(declare-function agent-shell-buffers "agent-shell" ())
(declare-function decknix--agent-session-mode-for-conv-key
                  "decknix-agent-session-mode" (conv-key))
(declare-function decknix-agent-purpose-resolve "decknix-agent-purposes" (purpose))
(declare-function decknix--agent-workspace-for-conv-key
                  "decknix-agent-session-workspace" (conv-key))
;; Soft dependency: the state classifier decorates rows with a lifecycle
;; state + attention score when loaded; the list still works without it.
(require 'decknix-session-state nil t)
(declare-function decknix-session-classify-status "decknix-session-state" (status))
(declare-function decknix-session-state "decknix-session-state" (result))
(declare-function decknix-session-score "decknix-session-state" (result))
(declare-function decknix-session-state-glyph "decknix-session-state" (state))
(declare-function decknix-session-state-label "decknix-session-state" (state))
(declare-function decknix--header-detect-status "decknix-agent-header" ())

(defconst decknix--agent-terminal-resume-clis
  '((claude-code . "claude")
    (auggie      . "auggie"))
  "Map of provider-id -> terminal CLI that accepts `--resume <id>'.
Providers absent here have no known interactive resume CLI; their
sessions can still be reopened via the picker (\\[decknix-agent-session-picker]).")

(defconst decknix--agent-cli-permission-mode-map
  '(("default"           . "default")
    ("acceptEdits"       . "acceptEdits")
    ("dontAsk"           . "dontAsk")
    ("bypassPermissions" . "bypassPermissions")
    ("plan"              . "plan")
    ;; decknix's `auto' (model-classifier mode) has no `claude
    ;; --permission-mode' equivalent; the closest non-dangerous mapping
    ;; keeps edits flowing (Bash/MCP still prompt).  Bump to
    ;; bypassPermissions by hand for a fully unattended run.
    ("auto"              . "acceptEdits"))
  "Map a decknix session mode-id to a `claude --permission-mode' value.
Values are exactly the CLI's accepted choices; an unmapped mode-id
yields nil (no flag emitted).")

(defun decknix--agent-cli-permission-mode (mode-id)
  "Return the `claude --permission-mode' value for MODE-ID, or nil."
  (and mode-id (cdr (assoc mode-id decknix--agent-cli-permission-mode-map))))

(defconst decknix--agent-cli-permission-mode-choices
  '("acceptEdits" "bypassPermissions" "default" "dontAsk" "plan" "none")
  "The `--permission-mode' values offered when setting a session's mode
in the live-sessions buffer.  \"none\" drops the flag entirely.")

(defun decknix--agent-terminal-resume-command (provider-id session-id workspace
                                                           &optional mode-id)
  "Return a shell command that resumes SESSION-ID in a terminal, or nil.
PROVIDER-ID selects the CLI (see `decknix--agent-terminal-resume-clis');
the command cd's into WORKSPACE first so the provider resolves the
right project.  For the Claude CLI, MODE-ID is mapped to a
`--permission-mode' flag (see `decknix--agent-cli-permission-mode-map')
so the resumed session keeps the same permission posture."
  (let ((cli (alist-get provider-id decknix--agent-terminal-resume-clis)))
    (when (and cli session-id (stringp session-id)
               (not (string-empty-p session-id)))
      (let ((perm (and (equal cli "claude")
                       (decknix--agent-cli-permission-mode mode-id))))
        (format "(cd %s && %s%s --resume %s)"
                (shell-quote-argument (or workspace
                                          (expand-file-name default-directory)))
                cli
                (if perm (format " --permission-mode %s" perm) "")
                session-id)))))

(defvar decknix--agent-claude-cwd-cache (make-hash-table :test 'equal)
  "Memoised session-id -> transcript cwd.
A Claude session's project dir is immutable, so cwd is cached forever.
Only successful reads are stored, so a not-yet-written transcript is
re-read on the next call rather than cached as a permanent miss.")

(defun decknix--agent-claude-session-cwd (session-id)
  "Return the recorded cwd for a Claude SESSION-ID, or nil.
Claude scopes `claude --resume' to the project directory the session
was created in — recorded as `cwd' in the transcript under
~/.claude/projects/<encoded-cwd>/<session-id>.jsonl.  That cwd is the
only directory the resume works from, so it is the authoritative
workspace for the terminal command (the buffer-local workspace is not
tracked for Claude, whose provider is `:supports-workspace-root nil').
Result is memoised in `decknix--agent-claude-cwd-cache'."
  (when (and session-id (stringp session-id) (not (string-empty-p session-id)))
    (or (gethash session-id decknix--agent-claude-cwd-cache)
        (let ((files (file-expand-wildcards
                      (expand-file-name
                       (format "~/.claude/projects/*/%s.jsonl" session-id)))))
          (when files
            (with-temp-buffer
              (insert-file-contents (car files) nil 0 8192)
              (goto-char (point-min))
              (when (re-search-forward
                     "\"cwd\"[[:space:]]*:[[:space:]]*\"\\([^\"]+\\)\"" nil t)
                (puthash session-id (match-string 1)
                         decknix--agent-claude-cwd-cache))))))))

(defun decknix--live-sessions-collect ()
  "Return a list of live-session entry plists (:name :provider :sid
:ws :perm :marked), newest agent buffers first.  :perm is the CLI
`--permission-mode' resolved from the session's saved mode (nil = no
flag / non-Claude)."
  (let ((entries nil)
        (buffers (if (fboundp 'agent-shell-buffers)
                     (agent-shell-buffers)
                   (buffer-list))))
    (dolist (buf buffers)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when (derived-mode-p 'agent-shell-mode)
            (let* ((provider (bound-and-true-p decknix--agent-provider-id))
                   (sid (bound-and-true-p decknix--agent-auggie-session-id))
                   (conv-key (bound-and-true-p decknix--agent-conv-key))
                   ;; Claude resumes only from its transcript's recorded cwd,
                   ;; which the buffer-local workspace does not track (its
                   ;; provider is :supports-workspace-root nil) — prefer it.
                   (ws (or (and (eq provider 'claude-code)
                                (decknix--agent-claude-session-cwd sid))
                           (bound-and-true-p decknix--agent-session-workspace)
                           (and conv-key
                                (fboundp 'decknix--agent-workspace-for-conv-key)
                                (decknix--agent-workspace-for-conv-key conv-key))
                           (expand-file-name default-directory)))
                   (mode-id (or (and conv-key
                                     (fboundp 'decknix--agent-session-mode-for-conv-key)
                                     (decknix--agent-session-mode-for-conv-key conv-key))
                                (and (fboundp 'decknix-agent-purpose-resolve)
                                     (plist-get (decknix-agent-purpose-resolve 'new-session)
                                                :mode))))
                   ;; Lifecycle state + attention score from the existing
                   ;; per-buffer status detection (when the classifier is loaded).
                   (cls (when (and (fboundp 'decknix--header-detect-status)
                                   (fboundp 'decknix-session-classify-status))
                          (decknix-session-classify-status
                           (decknix--header-detect-status))))
                   (state (and cls (decknix-session-state cls)))
                   (score (and cls (decknix-session-score cls))))
              (push (list :name (buffer-name) :provider provider :sid sid
                          :ws ws :perm (decknix--agent-cli-permission-mode mode-id)
                          :state state :score score :marked nil)
                    entries))))))
    (setq entries (nreverse entries))
    ;; Attention-to-top: sort by score when any entry is classified.  Emacs
    ;; `sort' is stable, so newest-first order is preserved within a score.
    (if (seq-some (lambda (e) (plist-get e :score)) entries)
        (sort entries (lambda (a b)
                        (> (or (plist-get a :score) -1)
                           (or (plist-get b :score) -1))))
      entries)))

(defun decknix--live-sessions-entry-command (entry)
  "Return the terminal resume command for ENTRY, or nil."
  (decknix--agent-terminal-resume-command
   (plist-get entry :provider) (plist-get entry :sid)
   (plist-get entry :ws) (plist-get entry :perm)))

(defvar-local decknix--live-sessions-entries nil
  "Buffer-local list of live-session entry plists for the current view.")

(defun decknix--live-sessions-redraw ()
  "Redraw the *live-agent-sessions* buffer from `decknix--live-sessions-entries'."
  (let ((inhibit-read-only t)
        (idx 0)
        (line (line-number-at-pos)))
    (erase-buffer)
    (insert (propertize
             "Live agent sessions (attention-sorted) — RET/w copy · m/u mark · p perm-mode · g refresh · q quit\n\n"
             'face 'font-lock-comment-face))
    (dolist (entry decknix--live-sessions-entries)
      (let* ((sid (plist-get entry :sid))
             (provider (plist-get entry :provider))
             (perm (plist-get entry :perm))
             (state (plist-get entry :state))
             (glyph (if (and state (fboundp 'decknix-session-state-glyph))
                        (decknix-session-state-glyph state) " "))
             (state-str (if (and state (fboundp 'decknix-session-state-label))
                            (decknix-session-state-label state) ""))
             (has-cmd (decknix--live-sessions-entry-command entry))
             (start (point)))
        (insert (format "%s %s %-26s %-11s %-8s %-11s %s\n"
                        (if (plist-get entry :marked) "*" " ")
                        glyph
                        (truncate-string-to-width (or (plist-get entry :name) "?") 26)
                        (format "[%s]" (or provider "?"))
                        (if sid (substring sid 0 (min 8 (length sid))) "—")
                        state-str
                        (cond ((not has-cmd) "(no CLI — use picker)")
                              (perm (concat "--permission-mode " perm))
                              ((eq provider 'claude-code) "(default perms)")
                              (t ""))))
        (put-text-property start (point) 'decknix-idx idx))
      (setq idx (1+ idx)))
    (when (null decknix--live-sessions-entries)
      (insert "  (no live agent-shell sessions)\n"))
    (goto-char (point-min))
    (forward-line (1- (max line 3)))))

(defun decknix--live-sessions-current-entry ()
  "Return the entry on the current line, or nil."
  (let ((idx (get-text-property (point) 'decknix-idx)))
    (and idx (nth idx decknix--live-sessions-entries))))

(defun decknix--live-sessions-target-entries ()
  "Return marked entries, or the current-line entry when none are marked."
  (or (seq-filter (lambda (e) (plist-get e :marked)) decknix--live-sessions-entries)
      (let ((e (decknix--live-sessions-current-entry))) (and e (list e)))))

(defun decknix-live-sessions-mark ()
  "Mark the session on this line and move to the next."
  (interactive)
  (when-let ((e (decknix--live-sessions-current-entry)))
    (plist-put e :marked t) (decknix--live-sessions-redraw) (forward-line 1)))

(defun decknix-live-sessions-unmark ()
  "Unmark the session on this line and move to the next."
  (interactive)
  (when-let ((e (decknix--live-sessions-current-entry)))
    (plist-put e :marked nil) (decknix--live-sessions-redraw) (forward-line 1)))

(defun decknix-live-sessions-unmark-all ()
  "Unmark every session."
  (interactive)
  (dolist (e decknix--live-sessions-entries) (plist-put e :marked nil))
  (decknix--live-sessions-redraw))

(defun decknix-live-sessions-set-perm (mode)
  "Set the `--permission-mode' MODE on the marked sessions (or this line).
Only Claude sessions are affected; \"none\" drops the flag."
  (interactive
   (list (completing-read "Permission mode: "
                          decknix--agent-cli-permission-mode-choices nil t)))
  (let ((perm (unless (equal mode "none") mode))
        (n 0))
    (dolist (e (decknix--live-sessions-target-entries))
      (when (eq (plist-get e :provider) 'claude-code)
        (plist-put e :perm perm) (setq n (1+ n))))
    (decknix--live-sessions-redraw)
    (message "Set permission mode on %d Claude session(s)" n)))

(defun decknix-live-sessions-copy ()
  "Copy resume command(s) for the marked sessions (or this line) to the kill ring."
  (interactive)
  (let ((cmds (delq nil (mapcar #'decknix--live-sessions-entry-command
                                (decknix--live-sessions-target-entries)))))
    (if (null cmds)
        (message "No resumable session under point")
      (kill-new (mapconcat #'identity cmds "\n"))
      (message "Copied %d resume command(s) to the kill ring" (length cmds)))))

(defun decknix-live-sessions-refresh ()
  "Re-scan live agent buffers (discards marks and permission overrides)."
  (interactive)
  (setq decknix--live-sessions-entries (decknix--live-sessions-collect))
  (decknix--live-sessions-redraw))

(defvar decknix-live-sessions-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'decknix-live-sessions-copy)
    (define-key map (kbd "w")   #'decknix-live-sessions-copy)
    (define-key map (kbd "c")   #'decknix-live-sessions-copy)
    (define-key map (kbd "m")   #'decknix-live-sessions-mark)
    (define-key map (kbd "u")   #'decknix-live-sessions-unmark)
    (define-key map (kbd "U")   #'decknix-live-sessions-unmark-all)
    (define-key map (kbd "p")   #'decknix-live-sessions-set-perm)
    (define-key map (kbd "g")   #'decknix-live-sessions-refresh)
    (define-key map (kbd "n")   #'next-line)
    map)
  "Keymap for `decknix-live-sessions-mode'.")

(define-derived-mode decknix-live-sessions-mode special-mode "LiveSessions"
  "Major mode for the live agent-session resume list.
\\{decknix-live-sessions-mode-map}")

(defun decknix-agent-live-sessions-terminal ()
  "List live agent sessions with keyboard-driven terminal resume actions.

Pops an interactive *live-agent-sessions* buffer.  Each row is a live
session; resume state lives in the provider transcript, so the terminal
command carries the session across a `decknix switch' (or out of Emacs).
Run the copied command AFTER Emacs releases the session to avoid two
clients on one conversation.

Keys: RET/w copy · m/u mark · U unmark-all · p set permission mode (on
marked or current) · g refresh · q quit."
  (interactive)
  (with-current-buffer (get-buffer-create "*live-agent-sessions*")
    (decknix-live-sessions-mode)
    (setq decknix--live-sessions-entries (decknix--live-sessions-collect))
    (decknix--live-sessions-redraw)
    (display-buffer (current-buffer))))

(provide 'decknix-agent-session-id)
;;; decknix-agent-session-id.el ends here
