;;; decknix-agent-shell-main.el --- Always-loaded agent-shell core -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix

;;; Commentary:
;;
;; Always-loaded agent-shell core extracted from agent-shell.nix as
;; part of PR B-Bulk.3.  Concatenates two source regions in heredoc
;; order:
;;
;;   always-1 region: 241 declarations (4,646 lines of forms +
;;     commentary) covering session management, conversation
;;     identity, compose, picker, custom commands, link-PR/repo,
;;     review-mode, batch-compose, history, MCP, attention helpers,
;;     header-line, etc.
;;
;;   always-tail region: 13 declarations (167 lines) covering the
;;     header-line refresh + per-buffer setup wired in via
;;     `agent-shell-mode-hook' (the hook itself stays in the heredoc
;;     because its lambda body binds many heredoc-resident symbols).
;;
;; This module is loaded unconditionally — there is no feature gate
;; for the core agent-shell setup.  Side-effects that depend on
;; heredoc-resident runtime state (every `(define-key
;; decknix-agent-prefix-map ...)`, `add-hook', `advice-add',
;; `with-eval-after-load', etc.) stay in the heredoc immediately
;; before / after the matching `(require ...)' calls so symbols
;; resolve at byte-compile time.

;; FIXME(arch-debt): this module is a verbatim 254-form bulk
;; extraction.  Follow-up PRs (B.22+) should slice it into
;; individually-tested sub-modules (sessions, picker, compose,
;; review, batch, header-line, MCP) using the standard
;; `mkEmacsTestedPackage' pattern.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'comint)
(require 'transient)

;; Forward declarations for symbols defined in the heredoc, in
;; agent-shell upstream, in helper modules, or in the per-feature
;; bulk modules (hub, workspace, context).  The byte-compiler resolves
;; these as `(declare-function)`; runtime resolution depends on the
;; corresponding `(require ...)' in the heredoc and on the
;; `optionalString cfg.X.enable' gates.
(declare-function agent-shell--update-header-and-mode-line "ext:agent-shell")
(declare-function agent-shell--send-command "ext:agent-shell")
(declare-function agent-shell--on-request "ext:agent-shell")
(declare-function agent-shell-rename-buffer "ext:agent-shell")
(declare-function shell-maker-submit "ext:shell-maker")
(declare-function shell-maker--busy "ext:shell-maker")
(declare-function decknix--hub-write-linked-prs "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-pr-fetch-async "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-repo-fetch-async "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-has-data-p "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-pr-status "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-render-requests "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-render-wip "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-render-status-hint "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-render-tasks "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-tc-build-for-branch "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-deploy-indicator "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-repo-status "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-org-filter-summary "decknix-hub-org-filter")
(declare-function decknix--hub-org-filter-dispatch "ext:decknix-agent-shell-hub")
(declare-function decknix--sidebar-render-previous-sessions "ext:decknix-agent-shell-workspace")
(declare-function decknix-context-toggle-or-panel "ext:decknix-agent-shell-context")
(declare-function decknix-context-panel "ext:decknix-agent-shell-context")
(declare-function decknix--context-full-refresh "ext:decknix-agent-shell-context")
(declare-function decknix--context-header-string "ext:decknix-agent-shell-context")
(declare-function decknix-progress "ext:decknix-progress")
(declare-function decknix--agent-pr-parse-url "decknix-agent-url-parse")
(declare-function decknix--agent-parse-pr-url "decknix-agent-url-parse")
(declare-function decknix--agent-repo-parse-url "decknix-agent-url-parse")
(declare-function decknix--agent-pr-url-accessor "decknix-agent-url-parse")
(declare-function decknix--hub-repo-cache-key "decknix-agent-url-parse")
(declare-function decknix--agent-session-parse "decknix-agent-parse")
(declare-function decknix--prompt-search-parse "decknix-agent-parse")
(declare-function decknix--agent-conversation-key-raw "decknix-agent-parse")
(declare-function decknix--agent-session-time-ago "decknix-agent-format")
(declare-function decknix--agent-session-time-compact "decknix-agent-format")
(declare-function decknix--prompt-truncate-for-display "decknix-agent-format")
(declare-function decknix--vcs-kind "decknix-agent-vcs")
(declare-function decknix--agent-review-quote "decknix-agent-review-format")
(declare-function decknix--agent-review-format-exchanges "decknix-agent-review-format")
(declare-function decknix--agent-review-strip-meta "decknix-agent-review-format")
(declare-function which-key-add-key-based-replacements "ext:which-key")
(declare-function which-key-add-keymap-based-replacements "ext:which-key")
(declare-function consult--multi "ext:consult")
(declare-function consult-line "ext:consult")
(declare-function consult-grep "ext:consult")
(declare-function consult--read "ext:consult")
(declare-function consult--dynamic-collection "ext:consult")
(declare-function project-current "project")
(declare-function project-root "project")
(declare-function vc-call-backend "vc")
(declare-function agent-shell-start "ext:agent-shell")
(declare-function agent-shell-buffers "ext:agent-shell")
(declare-function agent-shell-subscribe-to "ext:agent-shell")
(declare-function agent-shell-set-session-model "ext:agent-shell")
(declare-function agent-shell--state "ext:agent-shell")
(declare-function agent-shell--indent-string "ext:agent-shell")
(declare-function agent-shell-auggie--ascii-art "ext:agent-shell-auggie")
(declare-function agent-shell-auggie-make-agent-config "ext:agent-shell-auggie")
(declare-function agent-shell-workspace-sidebar-refresh "ext:agent-shell-workspace")
(declare-function shell-maker-welcome-message "ext:shell-maker")
(declare-function yas-activate-extra-mode "ext:yasnippet")
(declare-function yas-expand "ext:yasnippet")
(declare-function yas-next-field-or-maybe-expand "ext:yasnippet")
(declare-function yas--snippets-at-point "ext:yasnippet")
(declare-function corfu-complete "ext:corfu")
(declare-function markdown-mode "ext:markdown-mode")
(declare-function decknix--sidebar-restore-previous-session "ext:decknix-agent-shell-workspace")
(declare-function decknix--sidebar-previous-dedupe "decknix-sidebar-previous")
(declare-function decknix--session-conv-id "ext:decknix-agent-shell")

;; Forward defvars for heredoc-resident state and external configs.
(defvar decknix-agent-prefix-map)
(defvar decknix-agent-help-map)
(defvar decknix-agent-context-map)
(defvar decknix-agent-template-map)
(defvar decknix-agent-command-map)
(defvar decknix-agent-compose-interrupt-map)
(defvar decknix--agent-context-toggled)
(defvar yas-snippet-dirs)
(defvar comint-input-ring)
(defvar comint-scroll-to-bottom-on-input)
(defvar comint-scroll-to-bottom-on-output)
(defvar comint-scroll-show-maximum-output)
(defvar agent-shell-auggie-acp-command)
(defvar agent-shell-display-action)
(defvar decknix--sidebar-previous-sessions)
(defvar agent-shell-confirm-interrupt)
(defvar agent-shell-header-style)



;; == Tutorial: welcome message + help buffer ==

(defun decknix--agent-welcome-message (config)
  "Custom welcome message with a help hint.
Reproduces the auggie welcome (ASCII art + shell-maker message)
and appends a brief hint for discovering keybindings."
  (let* ((art (agent-shell--indent-string 4 (agent-shell-auggie--ascii-art)))
         (base-msg (string-trim-left (shell-maker-welcome-message config) "\n"))
         (original (concat "\n\n" art "\n\n" base-msg))
         (hint (concat "  "
                       (propertize "C-c ? k" 'font-lock-face 'font-lock-keyword-face)
                       " keybindings  "
                       (propertize "C-c ? t" 'font-lock-face 'font-lock-keyword-face)
                       " tutorial  "
                       (propertize "C-c e" 'font-lock-face 'font-lock-keyword-face)
                       " compose")))
    (concat original "\n" hint "\n")))

(defun decknix--agent-help-show (name content)
  "Display CONTENT in a help buffer called NAME.
Press q to dismiss."
  (let ((buf (get-buffer-create name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert content)
        (goto-char (point-min))
        (special-mode)))
    (display-buffer buf '(display-buffer-at-bottom
                          (window-height . fit-window-to-buffer)))))

(defun decknix-agent-help-keys ()
  "Show keybinding reference. Press q to dismiss."
  (interactive)
  (decknix--agent-help-show
   "*Agent Keys*"
   (concat
    (propertize "Agent Shell — Keybinding Reference\n"
                'font-lock-face '(:weight bold :height 1.2))
    (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face)
    "\n\n"

    (propertize "Sessions  (C-c s …)\n" 'font-lock-face '(:weight bold))
    (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
    "  C-c s s     Session picker (live + saved)\n"
    "  C-c s n     New session (guided)\n"
    "  C-c s q     Quit session (saves automatically)\n"
    "  C-c s g     Grep all session content (consult + ripgrep)\n"
    "  C-c s h     View history (C-u to pick any session)\n"
    "  C-c s c     Toggle Context history section (▶/▼)\n"
    "  C-c s y     Copy session ID (C-u for full ID)\n"
    "  C-c s d     Toggle short/full ID in header\n"
    "\n"

    (propertize "Input & Editing\n" 'font-lock-face '(:weight bold))
    (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
    "  C-c e       Compose buffer (multi-line editor)\n"
    "  C-c E       Interrupt agent + open compose\n"
    "              In compose: C-c C-s toggle sticky/transient\n"
    "              In compose: C-c k k interrupt, C-c k C-c interrupt+submit\n"
    "  C-c r       Rename buffer\n"
    "  RET         Send prompt (at end of input)\n"
    "  S-RET       Insert newline in prompt\n"
    "  C-c C-c     Interrupt running agent\n"
    "  TAB         Expand yasnippet template\n"
    "\n"

    (propertize "Templates  (C-c t …)\n" 'font-lock-face '(:weight bold))
    (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
    "  C-c t t     Insert a prompt template\n"
    "  C-c t n     Create new template\n"
    "  C-c t e     Edit existing template\n"
    "\n"

    (propertize "Commands  (C-c c …)\n" 'font-lock-face '(:weight bold))
    (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
    "  C-c c c     Pick & insert a slash command\n"
    "  C-c c n     Create new command\n"
    "  C-c c e     Edit existing command\n"
    "\n"

    (propertize "Tags — session  (C-c T …)\n" 'font-lock-face '(:weight bold))
    (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
    "  C-c T l     Show this session's tags\n"
    "  C-c T a     Add tag (select or create new)\n"
    "  C-c T r     Remove tag from this session\n"
    "\n"
    (propertize "Tags — global  (C-c A T …)\n" 'font-lock-face '(:weight bold))
    (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
    "  C-c A T l   List / filter sessions by tag\n"
    "  C-c A T e   Rename a tag across all sessions\n"
    "  C-c A T d   Delete tag globally\n"
    "  C-c A T c   Cleanup orphaned tags\n"
    "\n"

    (propertize "Model & Mode\n" 'font-lock-face '(:weight bold))
    (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
    "  C-c C-v     Pick model (persisted for this conversation)\n"
    "  C-c C-m     Pick mode\n"
    "\n"

    (propertize "Context  (C-c i …)\n" 'font-lock-face '(:weight bold))
    (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
    "  C-c I       Toggle context in header\n"
    "  C-u C-c I   Full context side panel\n"
    "  C-c i i     List tracked issues\n"
    "  C-c i p     List tracked PRs\n"
    "  C-c i c     Show CI status\n"
    "  C-c i r     Show review threads\n"
    "  C-c i a     Pin issue/PR to context\n"
    "  C-c i d     Unpin from context\n"
    "  C-c i g     Open in browser\n"
    "  C-c i f     Visit in forge\n"
    "\n"

    (propertize "Extensions\n" 'font-lock-face '(:weight bold))
    (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
    "  C-c b       Switch agent buffer (live only)\n"
    "  C-c m       Manager dashboard\n"
    "  C-c w       Workspace tab toggle\n"
    "  C-c j       Jump to session needing attention\n"
    "  C-c A S     MCP server list\n"
    "\n"

    (propertize "Global  (C-c A …)\n" 'font-lock-face '(:weight bold))
    (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
    "  C-c A a     Start / switch to agent\n"
    "  C-c A b     Switch agent buffer (live only)\n"
    "  C-c A n     Force new session\n"
    "  C-c A s     Session picker\n"
    "  C-c A h     View history (C-u to pick)\n"
    "  C-c A e     Compose buffer\n"
    "  C-c A c r   Review PR (quick action)\n"
    "  C-c A c B   Batch process (multi-session)\n"
    "  C-c A ? k   This keybinding reference\n"
    "\n"

    (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face) "\n"
    (propertize "Press q to close this buffer.\n"
                'font-lock-face 'font-lock-comment-face))))

(defun decknix-agent-help-tutorial ()
  "Show a tutorial with step-by-step guidance. Press q to dismiss."
  (interactive)
  (decknix--agent-help-show
   "*Agent Tutorial*"
   (concat
    (propertize "Agent Shell — Tutorial\n"
                'font-lock-face '(:weight bold :height 1.2))
    (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face)
    "\n\n"

    (propertize "1. Getting Started\n" 'font-lock-face '(:weight bold))
    (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
    "  Type a prompt at the bottom and press RET to send.\n"
    "  Use S-RET to insert a newline without sending.\n"
    "  For longer prompts, press C-c e to open the compose buffer.\n"
    "  In compose: C-c C-c submit (or queue if agent busy), C-c C-k clear/close.\n"
    "  In compose: C-c C-s toggles sticky (stays open) / transient.\n"
    "  In compose: C-c k k interrupts the agent, C-c k C-c interrupts & submits.\n"
    "  In compose: M-p / M-n cycle session prompts; M-P / M-N cycle all sessions.\n"
    "  In compose: M-r search all prompts (consult fuzzy match).\n"
    "  Press C-c C-c to interrupt a running response.\n"
    "  Press C-c E to interrupt and open the compose buffer.\n"
    "\n"

    (propertize "2. Sessions\n" 'font-lock-face '(:weight bold))
    (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
    "  Each buffer is a separate agent session.\n"
    "  C-c s s opens the session picker to switch or resume.\n"
    "  C-c s q saves and quits the current session.\n"
    "  C-c s h opens the conversation history in a browser.\n"
    "  Sessions are saved automatically by auggie.\n"
    "\n"

    (propertize "3. Templates & Commands\n" 'font-lock-face '(:weight bold))
    (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
    "  C-c t t inserts a yasnippet prompt template.\n"
    "  C-c c c inserts a custom slash command.\n"
    "  Both support tab-stop fields for filling in parameters.\n"
    "  Create your own with C-c t n (template) or C-c c n (command).\n"
    "\n"

    (propertize "4. Tags & Organisation\n" 'font-lock-face '(:weight bold))
    (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
    "  C-c T l shows this conversation's tags.\n"
    "  C-c T a adds a tag (select existing or type new).\n"
    "  C-c T r removes a tag from this conversation.\n"
    "  C-c A T l filters conversations by tag (global).\n"
    "  Tags apply to the conversation (all sessions sharing the same start).\n"
    "\n"

    (propertize "5. Context Awareness\n" 'font-lock-face '(:weight bold))
    (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
    "  The agent auto-detects issue/PR references in conversation.\n"
    "  C-c I toggles context in the header (collapsed by default).\n"
    "  C-u C-c I opens the full context side panel.\n"
    "  C-c i a pins an issue/PR; C-c i d unpins it.\n"
    "  C-c i g opens the item in your browser.\n"
    "\n"

    (propertize "6. Multi-Session Workflow\n" 'font-lock-face '(:weight bold))
    (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
    "  C-c A n starts a new session from anywhere.\n"
    "  C-c A g greps all session content (ripgrep).\n"
    "  C-c m opens the manager dashboard.\n"
    "  C-c j jumps to a session needing attention.\n"
    "  C-c w toggles the workspace tab.\n"
    "\n"

    (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face) "\n"
    (propertize "Press q to close this buffer.\n"
                'font-lock-face 'font-lock-comment-face))))

(defun decknix-agent-help-functions ()
  "Show available slash commands and templates. Press q to dismiss."
  (interactive)
  (let* ((cmd-files (when (fboundp 'decknix--agent-command-files)
                      (decknix--agent-command-files)))
         (cmd-text (if cmd-files
                       (mapconcat
                        (lambda (file)
                          (format "  /%s  %s"
                                  (propertize (file-name-sans-extension
                                               (file-name-nondirectory file))
                                              'font-lock-face 'font-lock-function-name-face)
                                  (or (decknix--agent-command-description file) "")))
                        cmd-files "\n")
                     "  (none defined)"))
         (tmpl-text (if (and (boundp 'yas-snippet-dirs) yas-snippet-dirs)
                        (let ((snippets nil))
                          (dolist (dir yas-snippet-dirs)
                            (let ((mode-dir (expand-file-name "agent-shell-mode" dir)))
                              (when (file-directory-p mode-dir)
                                (dolist (f (directory-files mode-dir nil "^[^.]"))
                                  (push f snippets)))))
                          (if snippets
                              (mapconcat
                               (lambda (s)
                                 (format "  %s" (propertize s 'font-lock-face 'font-lock-function-name-face)))
                               (sort (delete-dups snippets) #'string<) "\n")
                            "  (none found)"))
                      "  (yasnippet not loaded)")))
    (decknix--agent-help-show
     "*Agent Functions*"
     (concat
      (propertize "Agent Shell — Functions & Templates\n"
                  'font-lock-face '(:weight bold :height 1.2))
      (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face)
      "\n\n"

      (propertize "Slash Commands  (C-c c c to insert)\n" 'font-lock-face '(:weight bold))
      (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
      cmd-text "\n\n"

      (propertize "Prompt Templates  (C-c t t to insert)\n" 'font-lock-face '(:weight bold))
      (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
      tmpl-text "\n\n"

      (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face) "\n"
      (propertize "Press q to close this buffer.\n"
                  'font-lock-face 'font-lock-comment-face)))))       ; Functions/commands

;; == Session management: unified picker + clean quit ==

;; Buffer-local var to track the auggie CLI session ID
;; (distinct from ACP session ID in agent-shell--state)
(defvar-local decknix--agent-auggie-session-id nil
  "The auggie CLI session ID for this buffer, if known.")

;; Buffer-local var to track the conversation key for this session.
;; Set early in post-create (quickactions) so the header-line can
;; look up tags without going through the session-list cache.
(defvar-local decknix--agent-conv-key nil
  "The conversation key for this buffer's session, if known.")

;; Buffer-local var to track the workspace root for this session
(defvar-local decknix--agent-session-workspace nil
  "The workspace root directory for this agent session, if set.")

(defvar-local decknix--agent-workspace-persisted nil
  "Non-nil when this buffer's workspace has been persisted to agent-sessions.json.
Prevents the auto-persist hook from firing repeatedly.")

;; Buffer-local stash for metadata that cannot be persisted at
;; session-creation time because the conversation key is not yet
;; derivable (guided new sessions: first-message is unknown until
;; the user types it).  Flushed by
;; `decknix--agent-flush-pending-metadata' on the first comint
;; input event.
(defvar-local decknix--agent-pending-tags nil
  "Tags awaiting persistence under this buffer's conversation key.")

(defvar-local decknix--agent-pending-workspace nil
  "Workspace awaiting persistence under this buffer's conversation key.")

;; Time formatters (`decknix--agent-session-time-ago' and
;; `decknix--agent-session-time-compact') live in
;; agent-shell/agent/decknix-agent-format.el — required at the
;; top of this heredoc.

;; == Session history pre-population ==
;; When resuming a session via --resume, the buffer is empty.
;; This reads the local session JSON and inserts recent exchanges
;; so the user has context of what happened before.

(defun decknix--agent-session-file (session-id)
  "Return the path to the local session JSON for SESSION-ID."
  (expand-file-name (concat session-id ".json")
                    (expand-file-name "sessions" "~/.augment")))

(defun decknix--agent-session-extract-history (session-id n)
  "Extract the last N user-visible exchanges from SESSION-ID's local JSON.
Returns a list of (USER-MSG . ASSISTANT-RESP) cons cells, oldest first.

The auggie session JSON's `chatHistory' splits each user→assistant turn
across many entries: one entry carries the user text in `request_message'
(with `response_text' typically empty), and the assistant's reply is
spread across the *following* entries as response chunks (their
`request_message' is empty -— those entries are tool results / streaming
fragments attributed to the same turn).  A new turn starts when
`request_message' becomes non-empty again.

Single forward pass: accumulate `response_text' chunks under the current
user message; close the turn when the next user message arrives or the
history ends; finally take the last N turns.  This pairs each user
message with its real assistant response (the most recent interaction
included) instead of the same entry's almost-always-empty
`response_text', which the previous backward-walk picked up."
  (let ((file (decknix--agent-session-file session-id)))
    (when (file-exists-p file)
      (condition-case err
          (let* ((json-array-type 'list)
                 (json-object-type 'alist)
                 (json-key-type 'symbol)
                 (data (json-read-file file))
                 (history (alist-get 'chatHistory data))
                 (turns nil)
                 (cur-user nil)
                 (cur-resp nil))
            (dolist (entry history)
              (let* ((ex (alist-get 'exchange entry))
                     (req (alist-get 'request_message ex ""))
                     (resp (alist-get 'response_text ex "")))
                (when (and (stringp req)
                           (not (string-empty-p (string-trim req))))
                  ;; Close out the previous turn (if any).
                  (when cur-user
                    (push (cons cur-user
                                (mapconcat #'identity
                                           (nreverse cur-resp) "\n"))
                          turns))
                  (setq cur-user req
                        cur-resp nil))
                (when (and cur-user
                           (stringp resp)
                           (not (string-empty-p resp)))
                  (push resp cur-resp))))
            ;; Close out the final turn so the most recent interaction
            ;; is always included.
            (when cur-user
              (push (cons cur-user
                          (mapconcat #'identity (nreverse cur-resp) "\n"))
                    turns))
            (let* ((all (nreverse turns))
                   (len (length all)))
              (if (> len n) (nthcdr (- len n) all) all)))
        (error
         (message "Failed to read session history: %s"
                  (error-message-string err))
         nil)))))

(defun decknix--agent-context-toggle ()
  "Toggle the visibility of the Context history section.
Switches between ▶ (collapsed) and ▼ (expanded).  When no Context
section is present (e.g., fresh session with no restored history),
reports that fact instead of silently no-opping."
  (interactive)
  (let* ((inhibit-read-only t)
         ;; Find the body region tagged with our symbol
         (body-start (next-single-property-change
                      (point-min) 'decknix-context-body))
         (body-end (when body-start
                     (next-single-property-change
                      body-start 'decknix-context-body))))
    (if (and body-start body-end)
        (let ((currently-hidden (get-text-property body-start 'invisible)))
          ;; Toggle invisible
          (put-text-property body-start body-end
                            'invisible (not currently-hidden))
          ;; Swap the arrow in the header
          (save-excursion
            (goto-char (point-min))
            (when (re-search-forward "[▼▶]" body-start t)
              (replace-match (if currently-hidden "▼" "▶"))))
          (when (called-interactively-p 'interactive)
            (message "Context history: %s"
                     (if currently-hidden "expanded" "collapsed"))))
      (when (called-interactively-p 'interactive)
        (message "No Context history section in this buffer.")))))

(defvar decknix--agent-context-header-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'decknix--agent-context-toggle)
    ;; GUI Emacs sends `<tab>' / `<return>' when the keys are
    ;; pressed; the agent-shell-mode-hook (default.el) binds
    ;; `<tab>' globally to `decknix--agent-tab-dwim', so the
    ;; text-property keymap MUST bind the bracketed forms first
    ;; or the local map's `<tab>' binding is found before the
    ;; fallback translation to `TAB' even gets a chance.  Bind
    ;; both forms so the toggle fires in tty AND GUI frames.
    (define-key map (kbd "TAB") #'decknix--agent-context-toggle)
    (define-key map (kbd "<tab>") #'decknix--agent-context-toggle)
    (define-key map (kbd "RET") #'decknix--agent-context-toggle)
    (define-key map (kbd "<return>") #'decknix--agent-context-toggle)
    map)
  "Keymap for the Context section header toggle.")

(defun decknix--agent-session-prepopulate (session-id n)
  "Insert a collapsible Context section with the last N exchanges.
Inserts just before the prompt, matching the ▶/▼ toggle style of
agent-shell's built-in sections (Notices, Agent capabilities, etc.).
User messages shown in `font-lock-keyword-face', assistant responses
in `font-lock-doc-face'.  Section is collapsed by default so the
prompt is immediately visible.  Click or TAB the header to expand."
  (let ((exchanges (decknix--agent-session-extract-history session-id n)))
    (when exchanges
      (let ((inhibit-read-only t))
        (save-excursion
          ;; Find the prompt — search backwards from end
          (goto-char (point-max))
          (let ((prompt-pos
                 (when (bound-and-true-p comint-prompt-regexp)
                   (re-search-backward comint-prompt-regexp nil t))))
            (if prompt-pos
                (goto-char prompt-pos)
              ;; Fallback: insert before point-max
              (goto-char (point-max))))
          ;; Move to start of the prompt line
          (beginning-of-line)
          (progn
            ;; Header: ▶ Context (N exchanges) — clickable/TAB-able
            ;; Starts collapsed (▶); user clicks to expand (▼)
            (insert (propertize
                     (format "▶ %s\n"
                             (propertize
                              (format "Context (%d exchange%s)"
                                      (length exchanges)
                                      (if (= (length exchanges) 1) "" "s"))
                              'font-lock-face 'font-lock-doc-markup-face))
                     'read-only t
                     'rear-nonsticky t
                     'keymap decknix--agent-context-header-map))
            ;; Body: exchanges with invisible toggling
            (let ((body-start (point)))
              (dolist (ex exchanges)
                (let ((user (car ex))
                      (resp (cdr ex)))
                  ;; User message
                  (insert (propertize
                           (format "\n❯ %s\n"
                                   (truncate-string-to-width
                                    user 500 nil nil "..."))
                           'font-lock-face 'font-lock-keyword-face
                           'read-only t
                           'rear-nonsticky t))
                  ;; Assistant response
                  (when (and resp (not (string-empty-p resp)))
                    (insert (propertize
                             (format "\n%s\n"
                                     (truncate-string-to-width
                                      resp 2000 nil nil
                                      "\n[...truncated]"))
                             'font-lock-face 'font-lock-doc-face
                             'read-only t
                             'rear-nonsticky t)))))
              (insert (propertize "\n" 'read-only t 'rear-nonsticky t))
              ;; Tag the body region for toggling
              (put-text-property body-start (point)
                                 'decknix-context-body t)
              ;; Start collapsed — hide the body
              (put-text-property body-start (point)
                                 'invisible t)))))
      ;; Move cursor to the prompt (end of buffer) so it's
      ;; immediately ready for input, not stuck at the context header
      (goto-char (point-max)))))

(defun decknix--agent-unsorted-table (candidates)
  "Wrap CANDIDATES in a completion table that preserves list order.
Prevents vertico/orderless from re-sorting alphabetically.
Uses eval with lexical-binding to create a proper closure
since default.el is evaluated under dynamic binding."
  (eval
   `(let ((cands ',candidates))
      (lambda (string pred action)
        (if (eq action 'metadata)
            '(metadata (display-sort-function . identity)
                       (cycle-sort-function . identity))
          (complete-with-action action cands string pred))))
   t))

;; -- Session list caching --
;; Carved out into `agent-shell/agent/decknix-agent-session-cache.el'
;; as PR B.22.  The state vars (cache, ttl, refresh-proc, sessions-dir)
;; and 5 functions (session-list, ensure-jq-filter, jq-cmd,
;; refresh-sync, refresh-async) live in `decknix-agent-session-cache'
;; with ERT tests in `decknix-agent-session-cache-test'.  The heredoc
;; loads it immediately after `decknix-agent-parse' (which it depends
;; on) and exposes the same public symbols.  Forward declarations
;; below keep this file's byte-compile clean.

(declare-function decknix--agent-session-list "decknix-agent-session-cache")
(declare-function decknix--agent-session-refresh-sync "decknix-agent-session-cache")
(declare-function decknix--agent-session-refresh-async "decknix-agent-session-cache")
(declare-function decknix--agent-session-jq-cmd "decknix-agent-session-cache")
(declare-function decknix--agent-session-ensure-jq-filter "decknix-agent-session-cache")
(defvar decknix--agent-session-cache)
(defvar decknix--agent-session-cache-time)
(defvar decknix--agent-session-cache-ttl)
(defvar decknix--agent-session-refresh-proc)
(defvar decknix--agent-sessions-dir)
(defvar decknix--agent-session-jq-filter-file)

(defun decknix--agent-buffer-session-id (&optional buf)
  "Return the auggie CLI session ID for BUF (default: current buffer).
Reads the buffer-local `decknix--agent-auggie-session-id' first (this is
the ID needed for --resume).  Falls back to the ACP session ID from
`agent-shell--state' if the auggie ID is not yet set."
  (with-current-buffer (or buf (current-buffer))
    (or (and (boundp 'decknix--agent-auggie-session-id)
             decknix--agent-auggie-session-id)
        (ignore-errors
          (and (boundp 'agent-shell--state)
               agent-shell--state
               (map-nested-elt agent-shell--state '(:session :id)))))))

(defun decknix--agent-session-preview (session)
  "Format a one-line preview for a saved SESSION, including tags."
  (let* ((id (alist-get 'sessionId session))
         (modified (alist-get 'modified session))
         (exchanges (alist-get 'exchangeCount session 0))
         (first-msg (alist-get 'firstUserMessage session ""))
         (preview (car (split-string first-msg "\n" t)))
         (tags (decknix--agent-tags-for-session id))
         (tag-str (if tags (format " [%s]" (string-join tags ", ")) ""))
         (truncated (truncate-string-to-width (or preview "") 50 nil nil "...")))
    (format "%-8s  %-8s  %3dx  %s%s"
            (substring id 0 (min 8 (length id)))
            (if modified (decknix--agent-session-time-ago modified) "?")
            exchanges
            truncated
            tag-str)))

(defvar decknix-agent-session-history-count 2
  "Default number of recent exchanges to show when resuming a session.
Use C-u prefix with the session picker to override.")

(defvar decknix--agent-grep-last-input nil
  "Most recent input typed into `decknix-agent-session-grep'.
Captured by the dynamic collection lambda so the post-selection
handler can pass the search term through to
`decknix--agent-session-resume' for jump-to-match.")

(defun decknix--agent-find-new-shell-buffer (before-buffers)
  "Find the agent-shell buffer that was created after BEFORE-BUFFERS snapshot.
Returns the new buffer, or nil if not found."
  (seq-find (lambda (buf)
              (and (buffer-live-p buf)
                   (not (memq buf before-buffers))
                   (with-current-buffer buf
                     (derived-mode-p 'agent-shell-mode))))
            (buffer-list)))

(defun decknix--agent-session-display-name (session)
  "Derive a short buffer display name from SESSION data.
Uses tags if available, otherwise truncates the first user message."
  (let* ((sid (alist-get 'sessionId session ""))
         (first-msg (alist-get 'firstUserMessage session ""))
         (conv-key (decknix--agent-conversation-key first-msg))
         (tags (when conv-key (decknix--agent-tags-for-conv-key conv-key)))
         (preview (car (split-string first-msg "\n" t))))
    (cond
     ;; If there are tags, use them as the name
     (tags (string-join tags "/"))
     ;; Otherwise use a truncated preview of the first message
     ((and preview (not (string-empty-p preview)))
      (truncate-string-to-width preview 40 nil nil "..."))
     ;; Fallback to session ID prefix
     (t (substring sid 0 (min 8 (length sid)))))))

(defun decknix--agent-find-live-buffer-for-conv-key (conv-key)
  "Return the first live agent-shell buffer whose conv-key matches CONV-KEY.
Returns nil when CONV-KEY is nil or no live buffer is bound to it.
Used by `decknix--agent-session-resume' to dedupe: spawning a second
buffer for a conversation that is already live produces a confusing
`*Auggie: ...*<2>' pair where one buffer holds stale context.

A buffer only qualifies when its underlying auggie process is also
alive — a process-less buffer corpse (Emacs buffer alive, auggie
process dead) would otherwise short-circuit resume and leave the
user staring at a dead shell."
  (when conv-key
    (seq-find
     (lambda (buf)
       (and (buffer-live-p buf)
            (process-live-p (get-buffer-process buf))
            (with-current-buffer buf
              (and (derived-mode-p 'agent-shell-mode)
                   (bound-and-true-p decknix--agent-conv-key)
                   (equal decknix--agent-conv-key conv-key)))))
     (when (fboundp 'agent-shell-buffers)
       (agent-shell-buffers)))))

(defun decknix--agent-session-resume (session-id history-count
                                      &optional display-name workspace
                                      conv-key search-term)
  "Resume SESSION-ID and pre-populate buffer with HISTORY-COUNT exchanges.
DISPLAY-NAME, if provided, is used to rename the buffer to *Auggie: NAME*.
WORKSPACE, if provided, sets --workspace-root and default-directory so the
agent operates in the original project directory.
CONV-KEY, if provided, is used to register the new session-id under the
existing conversation entry in the tag store.
SEARCH-TERM, if provided, is searched for case-insensitively in the
loaded buffer after prepopulate; the window point is moved to the
first match (and recentered).  Used by `decknix-agent-session-grep'
to land on the matched message instead of the prompt.

When CONV-KEY is non-nil and a live agent-shell buffer already holds
that conversation, this function switches to that buffer in the
target window rather than spawning a duplicate.  The live buffer is
the authoritative in-memory state of the conversation; creating a
second buffer from an on-disk snapshot would produce `*Auggie: ...*'
and `*Auggie: ...*<2>' side by side and confuse the user about which
one is current."
  ;; Invalidate cache so next picker invocation fetches fresh data
  (setq decknix--agent-session-cache-time 0)
  ;; Dedupe: if this conversation is already live, return the
  ;; existing buffer (and reuse the target window) instead of
  ;; starting a second agent-shell.
  (let ((existing (decknix--agent-find-live-buffer-for-conv-key conv-key)))
    (if existing
        (let ((target-win (selected-window)))
          (when (window-live-p target-win)
            (set-window-buffer target-win existing))
          (decknix--agent-session-jump-to-match existing search-term)
          (message "Already live: switched to %s%s"
                   (buffer-name existing)
                   (if search-term
                       (format " (search: %s)" search-term)
                     ""))
          existing)
      (decknix--agent-session-resume--new
       session-id history-count display-name workspace conv-key
       search-term))))

(defun decknix--agent-session-jump-to-match (buf term)
  "Search BUF for TERM (case-insensitive); move window point on hit.
Searches forward from `point-min'.  On a hit, sets the window point
to the match end and recenters.  On a miss (or when TERM is nil),
leaves point at `point-max' so the prompt remains visible.
Returns t when a match was found, nil otherwise."
  (when (and term (buffer-live-p buf))
    (with-current-buffer buf
      (let ((case-fold-search t)
            (win (get-buffer-window buf))
            (hit (save-excursion
                   (goto-char (point-min))
                   (search-forward term nil t))))
        (cond
         ((and hit (window-live-p win))
          (set-window-point win hit)
          (with-selected-window win
            (goto-char hit)
            (recenter))
          t)
         (t
          (when (window-live-p win)
            (set-window-point win (point-max)))
          (when term
            (message
             "Term %S not in loaded history (only %d exchanges shown)"
             term decknix-agent-session-history-count))
          nil))))))

(defun decknix--agent-session-resume--new (session-id history-count
                                           &optional display-name
                                           workspace conv-key
                                           search-term)
  "Internal: start a fresh agent-shell for SESSION-ID.
See `decknix--agent-session-resume' for argument semantics.  This
helper carries the original resume logic; the public entry point
dedupes against live buffers before calling here."
  ;; Capture the target window NOW — before agent-shell-start runs.
  ;; agent-shell--display-buffer calls (display-buffer buf action)
  ;; internally.  Without this override, display-buffer-same-window
  ;; can fail (e.g. after minibuffer exit, or from the sidebar),
  ;; causing Emacs to split and create an additional window.
  ;; We pin the display to whichever window the caller intended
  ;; (typically the selected window, or main window from sidebar).
  (let* ((target-win (selected-window))
         (resume-args (list "--resume" session-id))
         (ws-args (when (and workspace (file-directory-p workspace))
                    (list "--workspace-root" workspace)))
         ;; Per-conversation model override (set mid-session
         ;; via C-c C-v).  When absent, omit --model so auggie
         ;; falls back to the global default in settings.json.
         (saved-model (decknix--agent-session-model-for-conv-key
                       conv-key))
         (model-args (when saved-model
                       (list "--model" saved-model)))
         ;; Augment the auggie ACP command for this resume.  We
         ;; MUST capture the augmented command in an explicit
         ;; `:client-maker' closure rather than via a dynamic
         ;; let-binding of `agent-shell-auggie-acp-command':
         ;; the upstream client-maker reads the variable lazily
         ;; (when the first ACP client is created), by which
         ;; point a dynamic let would have unwound — silently
         ;; dropping `--resume <sid>' so auggie spawns a fresh
         ;; conversation instead of restoring the saved one.
         ;; The buffer's prepopulated history then disagrees
         ;; with the running session and the resume looks
         ;; "wedged".  See `decknix-agent-session-new' (where
         ;; this lesson was first paid for) for the same
         ;; pattern.  `eval`+backquote is required because
         ;; default.el is dynamic-bound.
         (augmented-cmd
          (append agent-shell-auggie-acp-command
                  ws-args model-args resume-args))
         (config
          (let ((base (agent-shell-auggie-make-agent-config)))
            (setf (alist-get :client-maker base)
                  (eval `(lambda (buffer)
                           (agent-shell--make-acp-client
                            :command ,(car augmented-cmd)
                            :command-params ',(cdr augmented-cmd)
                            :environment-variables
                            (cond ((map-elt agent-shell-auggie-authentication :none)
                                   agent-shell-auggie-environment)
                                  ((map-elt agent-shell-auggie-authentication :login)
                                   agent-shell-auggie-environment)
                                  (t
                                   (error "Invalid Auggie authentication")))
                            :context-buffer buffer)) t))
            base))
         (agent-shell-display-action
          (eval `(cons (lambda (buffer alist)
                         (let ((win ,target-win))
                           (if (window-live-p win)
                               (window--display-buffer
                                buffer win 'reuse alist)
                             ;; Fallback: use same-window
                             (display-buffer-same-window buffer alist))))
                       nil)
                t))
         ;; agent-shell-start returns the new buffer synchronously
         ;; (only the process setup is async).  Capturing it directly
         ;; avoids the race in `find-new-shell-buffer' when multiple
         ;; sessions are restored in quick succession.
         (shell-buf
          (let ((default-directory (if (and workspace
                                            (file-directory-p workspace))
                                       workspace
                                     default-directory)))
            (agent-shell-start :config config))))
    ;; Use a timer to rename and prepopulate once the process is ready.
    (let ((sid session-id)
          (n history-count)
          (buf shell-buf)
          (bname display-name)
          (ws workspace)
          (ck conv-key)
          (term search-term))
      ;; Stamp conv-key synchronously on the new buffer so a
      ;; same-tick resume for the same conversation (e.g. batch
      ;; restore, grep-then-select) can see it and dedupe via
      ;; `decknix--agent-find-live-buffer-for-conv-key'.  The
      ;; async timer below still re-sets it for defensive reasons.
      (when (and ck (buffer-live-p shell-buf))
        (with-current-buffer shell-buf
          (setq-local decknix--agent-conv-key ck)))
      ;; Register new session-id under the conversation immediately
      ;; so it appears in the session picker even before the buffer
      ;; is fully set up.
      (when ck
        (decknix--agent-register-session-id ck sid)
        ;; Bump recency so the conversation sorts to the top
        (decknix--agent-conv-touch ck))
      (run-at-time
       1.5 nil
       (eval
        `(lambda ()
           (let ((shell-buf ,buf))
             (if (and shell-buf (buffer-live-p shell-buf))
                 (with-current-buffer shell-buf
                   (setq-local decknix--agent-auggie-session-id ,sid)
                   ;; Store conv-key for fast tag lookup in header-line
                   (when ,ck
                     (setq-local decknix--agent-conv-key ,ck))
                   ;; Restore workspace for the session picker display
                   (when ,ws
                     (setq-local decknix--agent-session-workspace ,ws))
                   ;; Rename buffer to match conversation identity
                   (when ,bname
                     (rename-buffer
                      (generate-new-buffer-name
                       (format "*Auggie: %s*" ,bname)))
                     (setq-local shell-maker--buffer-name-override
                                 (buffer-name)))
                   (decknix--agent-session-prepopulate ,sid ,n)
                   ;; If a search term was provided (grep flow),
                   ;; jump to the first match; otherwise keep the
                   ;; default behaviour of showing the prompt.
                   (if ,term
                       (decknix--agent-session-jump-to-match
                        shell-buf ,term)
                     (let ((win (get-buffer-window shell-buf)))
                       (when (and win (window-live-p win))
                         (set-window-point win (point-max))))))
               (message "Could not find agent-shell buffer for session %s"
                        (substring ,sid 0 8)))))
        t))
      ;; Return the buffer so callers can use it directly
      shell-buf)))

(defun decknix--agent-conversation-hidden-p (conv-key)
  "Return non-nil if CONV-KEY is marked as hidden in agent-sessions.json.
Hidden conversations are background/automated sessions (e.g., git hook
commit reviews) that should not appear in user-facing session lists."
  (condition-case nil
      (let* ((store (decknix--agent-tags-read))
             (convs (decknix--agent-tags-conversations store))
             (entry (gethash conv-key convs)))
        (and entry (eq (gethash "hidden" entry) t)))
    (error nil)))

(defun decknix--agent-conversation-set-hidden (conv-key hidden)
  "Set the hidden flag for CONV-KEY to HIDDEN (t or nil)."
  (let* ((store (decknix--agent-tags-read))
         (convs (decknix--agent-tags-conversations store))
         (entry (gethash conv-key convs)))
    (unless entry
      (setq entry (make-hash-table :test 'equal))
      (puthash conv-key entry convs))
    (puthash "hidden" (if hidden t :json-false) entry)
    (decknix--agent-tags-write store)))

(defun decknix--agent-session-group-by-conversation
    (sessions &optional include-hidden)
  "Group SESSIONS by conversation (shared firstUserMessage).
Returns a list of (CONV-KEY LATEST-SESSION ALL-SESSIONS) triples,
sorted by most recently interacted first.

Hidden conversations (marked with hidden=true in agent-sessions.json)
are excluded unless INCLUDE-HIDDEN is non-nil.  Hidden sessions are
typically background/automated sessions like git hook commit reviews.

Inter-group sort uses max(session.modified, conversation.lastAccessed)
so that tag/rename/resume operations bump a conversation to the top,
not just augment writing to the session file."
  (let ((groups (make-hash-table :test 'equal)))
    (dolist (s sessions)
      (let* ((first-msg (alist-get 'firstUserMessage s ""))
             (conv-key (decknix--agent-conversation-key first-msg)))
        (when (and conv-key
                   (or include-hidden
                       (not (decknix--agent-conversation-hidden-p conv-key))))
          (let ((existing (gethash conv-key groups)))
            (puthash conv-key (cons s existing) groups)))))
    ;; Build result: (conv-key latest-session all-sessions)
    (let (result)
      (maphash (lambda (key sessions-list)
                 (let ((sorted (sort (copy-sequence sessions-list)
                                    (lambda (a b)
                                      (string> (or (alist-get 'modified a) "")
                                               (or (alist-get 'modified b) ""))))))
                   (push (list key (car sorted) sorted) result)))
               groups)
      ;; Sort by max(session.modified, lastAccessed) — any interaction
      ;; with a conversation (tagging, renaming, resuming) counts.
      (sort result (lambda (a b)
                     (let* ((mod-a (or (alist-get 'modified (cadr a)) ""))
                            (mod-b (or (alist-get 'modified (cadr b)) ""))
                            (acc-a (or (decknix--agent-conv-last-accessed (car a)) ""))
                            (acc-b (or (decknix--agent-conv-last-accessed (car b)) ""))
                            (eff-a (if (string> acc-a mod-a) acc-a mod-a))
                            (eff-b (if (string> acc-b mod-b) acc-b mod-b)))
                       (string> eff-a eff-b)))))))

(defun decknix--agent-conversation-preview (conv-group)
  "Format a one-line preview for a conversation CONV-GROUP.
CONV-GROUP is (CONV-KEY LATEST-SESSION ALL-SESSIONS).
Shows: id  age  exchanges  preview [tags] (N sessions) @workspace"
  (let* ((conv-key (car conv-group))
         (latest (cadr conv-group))
         (all (caddr conv-group))
         (session-count (length all))
         (id (alist-get 'sessionId latest))
         (modified (alist-get 'modified latest))
         (exchanges (alist-get 'exchangeCount latest 0))
         (first-msg (alist-get 'firstUserMessage latest ""))
         (preview (car (split-string first-msg "\n" t)))
         (tags (decknix--agent-tags-for-conv-key conv-key))
         (tag-str (if tags (format " [%s]" (string-join tags ", ")) ""))
         (count-str (if (> session-count 1)
                        (format " (%d sessions)" session-count)
                      ""))
         (workspace (when conv-key
                      (decknix--agent-workspace-for-conv-key conv-key)))
         (ws-str (if workspace
                     (let ((abbr (abbreviate-file-name workspace)))
                       (format " @%s"
                               (if (string-match "/\\([^/]+\\)/?$" abbr)
                                   (match-string 1 abbr)
                                 abbr)))
                   ""))
         (truncated (truncate-string-to-width (or preview "") 50 nil nil "...")))
    (format "%-8s  %-8s  %4dx  %s%s%s%s"
            (substring id 0 (min 8 (length id)))
            (if modified (decknix--agent-session-time-ago modified) "?")
            exchanges
            truncated
            tag-str
            count-str
            ws-str)))

;; ── Session picker (consult--multi) ──────────────────────────
;; Modelled after C-x b (consult-buffer): sectioned groups with
;; horizontal dividers — Live Sessions → Saved Sessions → New.

(defun decknix--agent-session-live-label (buf)
  "Build a display label for live agent-shell buffer BUF."
  (let* ((ws (buffer-local-value
              'decknix--agent-session-workspace buf))
         (ws-short (when ws
                     (file-name-nondirectory
                      (directory-file-name ws))))
         (tags (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (when (and (boundp 'decknix--agent-auggie-session-id)
                              decknix--agent-auggie-session-id)
                     (decknix--agent-tags-for-session
                      decknix--agent-auggie-session-id)))))
         (tag-str (when tags
                    (mapconcat (lambda (tg) (format "#%s" tg))
                               tags " ")))
         (detail (string-join (delq nil (list ws-short tag-str)) "  ")))
    (format "%s%s"
            (buffer-name buf)
            (if (string-empty-p detail) ""
              (format "  — %s" detail)))))

;; We store a hash-table mapping candidate strings → payloads so that
;; each source's :action can look up the data for the selected string.
(defvar decknix--session-picker-live-map nil
  "Candidate-string → buffer map for live source.")
(defvar decknix--session-picker-saved-map nil
  "Candidate-string → session alist for saved source.")
(defvar decknix--session-picker-expand nil
  "Non-nil shows all snapshots instead of collapsed conversations.")

(defvar decknix--session-source-live
  (list :name     "Live Sessions"
        :narrow   ?l
        :category 'agent-session-live
        :face     'consult-buffer
        :items
        (lambda ()
          (let* ((bufs (when (fboundp 'agent-shell-buffers)
                         (agent-shell-buffers)))
                 ;; Exclude the current buffer — you're already in it.
                 ;; Most-recently-used ordering is preserved from
                 ;; agent-shell-buffers (which follows buffer-list order).
                 (cur (current-buffer))
                 (others (remq cur bufs))
                 (ht (make-hash-table :test 'equal))
                 (ordered nil))
            (dolist (buf others)
              (let ((key (decknix--agent-session-live-label buf)))
                (puthash key buf ht)
                (push key ordered)))
            (setq decknix--session-picker-live-map ht)
            ;; Preserve MRU buffer-list order (push reverses, nreverse restores)
            (nreverse ordered)))
        :action
        (lambda (cand)
          (when cand
            (let ((buf (gethash cand decknix--session-picker-live-map)))
              (when (and buf (buffer-live-p buf))
                ;; Select main window first so the buffer doesn't
                ;; try to display in the dedicated sidebar window.
                (let ((main (window-main-window (selected-frame))))
                  (when (and main (window-live-p main))
                    (select-window main)))
                (switch-to-buffer buf))))))
  "Consult multi-source for live agent-shell buffers.")

(defvar decknix--session-source-saved
  (list :name     "Saved Sessions"
        :narrow   ?s
        :category 'agent-session-saved
        :face     'consult-file
        :items
        (lambda ()
          (let* ((sessions (decknix--agent-session-list))
                 (ht (make-hash-table :test 'equal))
                 (ordered nil))
            (if decknix--session-picker-expand
                ;; Expanded: all individual sessions (already newest-first)
                ;; Pre-resolve workspace so :action doesn't need to
                ;; re-derive conv-key (which can fail on large files).
                (dolist (session sessions)
                  (let* ((first-msg (alist-get 'firstUserMessage session ""))
                         (conv-key (decknix--agent-conversation-key first-msg))
                         (workspace (when conv-key
                                      (decknix--agent-workspace-for-conv-key
                                       conv-key)))
                         (entry (if workspace
                                    (cons (cons '__workspace workspace)
                                          session)
                                  session))
                         (key (decknix--agent-session-preview session)))
                    (puthash key entry ht)
                    (push key ordered)))
              ;; Collapsed: one entry per conversation (default).
              ;; group-by-conversation already computes conv-keys
              ;; for grouping — reuse them to pre-resolve workspace.
              (let ((groups (decknix--agent-session-group-by-conversation
                            sessions)))
                (dolist (group groups)
                  (let* ((conv-key (car group))
                         (latest (cadr group))
                         (workspace (when conv-key
                                      (decknix--agent-workspace-for-conv-key
                                       conv-key)))
                         (entry (if workspace
                                    (cons (cons '__workspace workspace)
                                          latest)
                                  latest))
                         (key (decknix--agent-conversation-preview group)))
                    (puthash key entry ht)
                    (push key ordered)))))
            (setq decknix--session-picker-saved-map ht)
            ;; Return in newest-first order (push reverses, so nreverse)
            (nreverse ordered)))
        :action
        (lambda (cand)
          (when cand
            (let* ((session (gethash cand decknix--session-picker-saved-map))
                   ;; Workspace was pre-resolved during :items
                   (workspace (alist-get '__workspace session)))
              (when session
                (let ((conv-key (decknix--agent-conversation-key
                                (alist-get 'firstUserMessage
                                           session ""))))
                  ;; If no stored workspace, prompt the user so the
                  ;; session opens in the right directory.
                  (unless workspace
                    (setq workspace
                          (read-directory-name
                           "Workspace for this session: "
                           nil nil t))
                    ;; Persist for future resumes (best-effort)
                    (when (and conv-key workspace)
                      (decknix--agent-session-save-workspace-for-conv-key
                       conv-key workspace)))
                  ;; Select main window and override display-action
                  ;; so the buffer displays there (not in the sidebar).
                  (let ((main (window-main-window (selected-frame))))
                    (when (and main (window-live-p main))
                      (select-window main))
                    (let ((agent-shell-display-action
                           (if (and main (window-live-p main))
                               (eval `(cons (lambda (buffer alist)
                                              (let ((win ,main))
                                                (when (window-live-p win)
                                                  (window--display-buffer
                                                   buffer win 'reuse alist))))
                                            nil)
                                     t)
                             agent-shell-display-action)))
                      (decknix--agent-session-resume
                       (alist-get 'sessionId session)
                       decknix-agent-session-history-count
                       (decknix--agent-session-display-name session)
                       workspace conv-key)))))))))
  "Consult multi-source for saved auggie sessions.")

(defvar decknix--session-picker-previous-map nil
  "Hash table mapping display strings to previous-session entries.")

(defvar decknix--session-source-previous
  (list :name     "Previous"
        :narrow   ?p
        :category 'agent-session-previous
        :face     'shadow
        :items
        (lambda ()
          (let* ((live-bufs (seq-filter #'buffer-live-p
                                       (when (fboundp 'agent-shell-buffers)
                                         (agent-shell-buffers))))
                 (live-sids (mapcar #'decknix--agent-buffer-session-id
                                    live-bufs))
                 (live-conv-keys
                  (delq nil
                        (mapcar (lambda (b)
                                  (with-current-buffer b
                                    (and (bound-and-true-p decknix--agent-conv-key)
                                         decknix--agent-conv-key)))
                                live-bufs)))
                 ;; Same filter as the sidebar renderer.  Collapse
                 ;; by conv-key so the picker never shows two rows
                 ;; for the same conversation (identical labels
                 ;; confuse completing-read / assoc lookup).
                 (prev (decknix--sidebar-previous-dedupe
                        (seq-filter
                         (lambda (e)
                           (let ((sid (alist-get 'session-id e))
                                 (ck (alist-get 'conv-key e)))
                             (and (not (member sid live-sids))
                                  (not (and ck (member ck live-conv-keys))))))
                         (or decknix--sidebar-previous-sessions '()))))
                 (ht (make-hash-table :test 'equal))
                 (ordered nil))
            (dolist (entry prev)
              (let* ((name (or (alist-get 'name entry) "unknown"))
                     (short (if (string-match "\\*Auggie: \\(.*\\)\\*" name)
                                (match-string 1 name) name))
                     (ws (alist-get 'workspace entry))
                     (tags (alist-get 'tags entry))
                     (ws-str (if ws
                                 (let ((abbr (abbreviate-file-name ws)))
                                   (if (string-match "/\\([^/]+\\)/?$" abbr)
                                       (match-string 1 abbr) abbr))
                               "?"))
                     (tag-str (if tags
                                 (mapconcat
                                  (lambda (tg) (concat "#" tg)) tags " ")
                               ""))
                     (label (format "%s  @%s %s" short ws-str tag-str)))
                (puthash label entry ht)
                (push label ordered)))
            (setq decknix--session-picker-previous-map ht)
            (nreverse ordered)))
        :action
        (lambda (cand)
          (when cand
            (let ((entry (gethash cand decknix--session-picker-previous-map)))
              (when entry
                (decknix--sidebar-restore-previous-session entry t))))))
  "Consult multi-source for previous (restorable) sessions.")

(defvar decknix--session-source-new
  (list :name     "New"
        :narrow   ?n
        :category 'agent-session-new
        :face     'consult-bookmark
        :items    (lambda () (list "Start a new auggie session…"))
        :action   (lambda (_cand)
                    (decknix-agent-session-new)))
  "Consult multi-source for starting a new session.")

(defun decknix-agent-session-picker (arg)
  "Pick from live agent-shell buffers and saved auggie sessions.
Sections are separated by dividers (like `consult-buffer' / C-x b):
  Live Sessions     — currently running agent buffers (most recent first)
  Previous          — sessions that were live before last restart (greyed)
  Saved Sessions    — past conversations from ~/.augment/sessions
  New               — start a new session (fallback)

By default, saved sessions are collapsed by conversation.
With \\[universal-argument], shows all individual session snapshots."
  (interactive "P")
  (require 'consult)
  (setq decknix--session-picker-expand arg)
  (consult--multi (list decknix--session-source-live
                       decknix--session-source-previous
                       decknix--session-source-saved
                       decknix--session-source-new)
                  :prompt (format "Agent session%s: "
                                  (if arg " (all snapshots)" ""))
                  :sort nil))

;; == Agent buffer switch: C-c b (in-buffer) / C-c A b (global) ==
;; Like C-x b but scoped to live agent-shell buffers only.
;; Uses consult for live narrowing when available, else completing-read.
;; Excludes the current buffer; sorted by MRU. (#96)

(defun decknix-agent-switch-buffer ()
  "Switch to another live agent-shell buffer.
Like \\[switch-to-buffer] but showing only agent-shell buffers.
Excludes the current buffer. MRU ordering."
  (interactive)
  (let* ((bufs (when (fboundp 'agent-shell-buffers)
                 (agent-shell-buffers)))
         (cur (current-buffer))
         (others (remq cur bufs)))
    (cond
     ((null others)
      (message "No other agent buffers"))
     ((= (length others) 1)
      (switch-to-buffer (car others)))
     (t
      (let ((ht (make-hash-table :test 'equal))
            (candidates nil))
        (dolist (buf others)
          (let ((label (decknix--agent-session-live-label buf)))
            (puthash label buf ht)
            (push label candidates)))
        (setq candidates (nreverse candidates))
        (let* ((chosen (completing-read "Agent buffer: " candidates nil t))
               (buf (gethash chosen ht)))
          (when (and buf (buffer-live-p buf))
            (switch-to-buffer buf))))))))

;; == Session grep: consult + ripgrep full-text search ==
;; Searches ALL content (user messages, agent responses, code blocks)
;; across every session JSON file using ripgrep.
;; C-c A g — type a search term, results narrow live.

(defun decknix--agent-session-rg-search-fast (term)
  "Find sessions matching TERM via rg + the in-memory metadata cache.
Runs `rg -l0' to list files containing TERM (~0.5s for hundreds of
sessions), extracts the sessionId from each filename
(`<uuid>.json'), and looks the IDs up in
`decknix--agent-session-cache'.

This is the default path because parsing the matching JSON files
with jq is the real bottleneck — some sessions weigh 40MB+ and
the per-keystroke pipeline used to hit ~35s, well past consult's
`while-no-input' timeout.

Sessions written *since* the last cache refresh (every 2 minutes)
are silently skipped here.  Use `\\[universal-argument]
\\[universal-argument]' on `decknix-agent-session-grep' to fall
back to the slower but exhaustive `*-thorough' variant when
hunting for a brand-new session."
  (let* ((rg (or (executable-find "rg") "rg"))
         (sessions-dir (expand-file-name "sessions" "~/.augment"))
         (cmd (format "%s -l0 %s %s 2>/dev/null"
                      (shell-quote-argument rg)
                      (shell-quote-argument term)
                      (shell-quote-argument sessions-dir)))
         (output "")
         (proc (make-process
                :name "agent-grep-rg-fast"
                :buffer nil
                :command (list "sh" "-c" cmd)
                :noquery t
                :connection-type 'pipe
                :filter (lambda (_p o)
                          (setq output (concat output o))))))
    ;; Yield so consult's while-no-input can interrupt on
    ;; subsequent keystrokes — same pattern as the thorough
    ;; variant below.
    (while (process-live-p proc)
      (accept-process-output proc 0.03))
    (accept-process-output proc 0)
    ;; rg -l0 is NUL-delimited; split, derive the sessionId from
    ;; each path's basename, then filter the cached metadata.
    (let* ((paths (split-string output "\0" t))
           (id-set (let ((h (make-hash-table :test 'equal)))
                     (dolist (p paths)
                       (puthash (file-name-base p) t h))
                     h))
           (cache (or decknix--agent-session-cache
                      (progn (decknix--agent-session-list)
                             decknix--agent-session-cache)))
           (matched (seq-filter
                     (lambda (s)
                       (gethash (alist-get 'sessionId s) id-set))
                     cache)))
      (sort (copy-sequence matched)
            (lambda (a b)
              (string> (or (alist-get 'modified a) "")
                       (or (alist-get 'modified b) "")))))))

(defun decknix--agent-session-rg-search-thorough (term)
  "Search session files for TERM using ripgrep + parallel jq.
Slower but exhaustive complement to
`decknix--agent-session-rg-search-fast': re-parses every matching
file with jq instead of relying on the in-memory cache, so it
finds sessions written since the last cache refresh.

Uses `xargs -0 -P8' to parallelise the per-file jq calls — even
across hundreds of large session files this completes in a few
seconds, where the previous serial pipeline could take 30+s.

Uses `make-process' + `accept-process-output' so Emacs stays
responsive and consult's `while-no-input' can interrupt mid-flight
when the user types more characters."
  (let* ((jqf (decknix--agent-session-ensure-jq-filter))
         (sessions-dir (shell-quote-argument
                        (expand-file-name "sessions" "~/.augment")))
         (cmd (format "%s -l0 %s %s 2>/dev/null | xargs -0 -P8 -I{} jq -Mc -f %s {} 2>/dev/null | jq -Msc 'sort_by(.modified) | reverse'"
                      (or (executable-find "rg") "rg")
                      (shell-quote-argument term)
                      sessions-dir
                      (shell-quote-argument jqf)))
         (output "")
         (proc (make-process
                :name "agent-grep-rg-thorough"
                :buffer nil
                :command (list "sh" "-c" cmd)
                :noquery t
                :connection-type 'pipe
                :filter (lambda (_p o)
                          (setq output (concat output o))))))
    (while (process-live-p proc)
      (accept-process-output proc 0.03))
    (accept-process-output proc 0)
    (decknix--agent-session-parse output)))

(defun decknix--agent-session-grep-candidate (session)
  "Build a candidate string for SESSION in grep results."
  (let* ((id (alist-get 'sessionId session))
         (modified (alist-get 'modified session))
         (exchanges (alist-get 'exchangeCount session 0))
         (first-msg (alist-get 'firstUserMessage session ""))
         (preview (car (split-string first-msg "\n" t)))
         (tags (decknix--agent-tags-for-session id))
         (tag-str (if tags (format " [%s]" (string-join tags ", ")) ""))
         (time-ago (if modified
                       (decknix--agent-session-time-ago modified)
                     "?"))
         (msg-preview (truncate-string-to-width
                       (or preview "") 80 nil nil "...")))
    (format "%-8s  %-8s  %4dx%s  %s"
            (substring id 0 (min 8 (length id)))
            time-ago exchanges tag-str msg-preview)))

(defun decknix--agent-session-grep-build-entries (sessions expand)
  "Build candidate entries from SESSIONS for grep results.
If EXPAND is non-nil, show all individual sessions.
Otherwise collapse by conversation."
  (if expand
      (mapcar (lambda (session)
                (cons (decknix--agent-session-grep-candidate session)
                      (cons 'session session)))
              sessions)
    (let ((conv-groups
           (decknix--agent-session-group-by-conversation sessions)))
      (mapcar (lambda (group)
                (let* ((conv-key (car group))
                       (latest (cadr group))
                       (all (caddr group))
                       (session-count (length all))
                       (id (alist-get 'sessionId latest))
                       (modified (alist-get 'modified latest))
                       (exchanges (alist-get 'exchangeCount latest 0))
                       (first-msg (alist-get 'firstUserMessage latest ""))
                       (preview (car (split-string first-msg "\n" t)))
                       (tags (decknix--agent-tags-for-conv-key conv-key))
                       (tag-str (if tags (format " [%s]" (string-join tags ", ")) ""))
                       (count-str (if (> session-count 1)
                                      (format " (%d sessions)" session-count)
                                    ""))
                       (time-ago (if modified
                                     (decknix--agent-session-time-ago modified)
                                   "?"))
                       (msg-preview (truncate-string-to-width
                                     (or preview "") 80 nil nil "...")))
                  (cons (format "%-8s  %-8s  %4dx%s%s  %s"
                                (substring id 0 (min 8 (length id)))
                                time-ago exchanges tag-str count-str
                                msg-preview)
                        (cons 'session latest))))
              conv-groups))))

(defun decknix-agent-session-grep (arg)
  "Full-text grep across all session content using consult + ripgrep.
Type a search term and ripgrep searches ALL user messages, agent
responses, and code blocks in every session file.  Results narrow
live as you type.

The default fast path uses ripgrep to find matching files (~0.5s)
then maps each filename to the in-memory session metadata cache —
this avoids re-parsing 40MB+ JSON files on every keystroke, which
previously starved consult's `while-no-input' and dropped results.

Prefix arguments:
- no prefix:         conversation-collapsed, fast (cache).
- \\[universal-argument]:               expanded snapshots, fast (cache).
- \\[universal-argument] \\[universal-argument]:           conversation-collapsed, thorough
             (re-parses every match with parallel jq —
             finds sessions written since the last cache
             refresh ~2 minutes ago).
- \\[universal-argument] \\[universal-argument] \\[universal-argument]:       expanded snapshots, thorough."
  (interactive "P")
  (require 'consult)
  (setq decknix--agent-grep-last-input nil)
  (let* ((arg-num (prefix-numeric-value arg))
         (thorough (>= arg-num 16))
         ;; Expand on `C-u' (4) or `C-u C-u C-u' (64); collapse
         ;; on no prefix (1) or `C-u C-u' (16).
         (expand (or (= arg-num 4) (>= arg-num 64)))
         (search-fn (if thorough
                        'decknix--agent-session-rg-search-thorough
                      'decknix--agent-session-rg-search-fast))
         ;; entries-cache: alist mapping candidate-string → (session . session-data)
         ;; Rebuilt on each rg invocation; used for lookup after selection.
         ;; Plain lambda below under `lexical-binding: t' is a real
         ;; closure over `entries-cache', `search-fn' and `expand'.
         ;; Do NOT wrap in `(eval `(lambda ...) t)' — that evaluates
         ;; the form under an empty lexical environment, so
         ;; `(setq entries-cache ...)' would mutate a stray global
         ;; instead of this binding.  After `consult--read' returns,
         ;; `entries-cache' would still be nil and the
         ;; `(cdr (assoc selected entries-cache))' lookup below would
         ;; silently yield nil → RET on a candidate would do nothing.
         ;; Same regression class as commit 7e67928 (picker toggles).
         (entries-cache nil)
         (selected
          (consult--read
           (consult--dynamic-collection
             (lambda (input)
               ;; Capture the typed input so the post-selection
               ;; handler can pass it as a search term to the
               ;; resume function (two-stage flow: pick session,
               ;; then jump to the match inside it).
               (setq decknix--agent-grep-last-input
                     (and input (string-trim input)))
               (cond
                ((or (null input) (< (length (string-trim input)) 2))
                 nil)
                (t
                 (condition-case nil
                     (let* ((matches (funcall search-fn input))
                            (entries (when matches
                                       (decknix--agent-session-grep-build-entries
                                        matches expand))))
                       (setq entries-cache entries)
                       (mapcar #'car entries))
                   (error nil)))))
             :min-input 2)
           :prompt (if thorough
                       "Grep sessions (thorough): "
                     "Grep sessions: ")
           :sort nil
           :require-match t))
         (chosen (cdr (assoc selected entries-cache)))
         (term (and decknix--agent-grep-last-input
                    (not (string-empty-p
                          decknix--agent-grep-last-input))
                    decknix--agent-grep-last-input)))
    (when chosen
      (let* ((s (cdr chosen))
             (first-msg (alist-get 'firstUserMessage s ""))
             (conv-key (decknix--agent-conversation-key first-msg))
             (workspace (when conv-key
                          (decknix--agent-workspace-for-conv-key
                           conv-key))))
        (unless workspace
          (setq workspace
                (read-directory-name
                 "Workspace for this session: " nil nil t))
          (when (and conv-key workspace)
            (decknix--agent-session-save-workspace-for-conv-key
             conv-key workspace)))
        (decknix--agent-session-resume
         (alist-get 'sessionId s)
         decknix-agent-session-history-count
         (decknix--agent-session-display-name s)
         workspace conv-key term)))))

;; -- Workspace + branch detection (PR B.45) --
;; Moved out of this file into
;; agent-shell/agent/decknix-agent-workspace-detect.el, packaged
;; as `decknix-agent-workspace-detect-el'.  Owns the three pure
;; detectors plus the `decknix-agent-workspace-roots' defvar
;; that seeds the third lookup tier.  Two cross-bulk call sites
;; in workspace-bulk (~lines 1330 / 1579, both inside `fboundp'
;; guards in the PR review quick-action picker) reach
;; `decknix--agent-pr-detect-workspace' through the heredoc.
(declare-function decknix--agent-detect-workspace
                  "decknix-agent-workspace-detect")
(declare-function decknix--agent-pr-detect-workspace
                  "decknix-agent-workspace-detect" (owner repo))
(declare-function decknix--agent-detect-branch
                  "decknix-agent-workspace-detect" (dir))
(defvar decknix-agent-workspace-roots)

(defun decknix--agent-flush-pending-metadata (input)
  "Persist pending metadata for the current buffer using INPUT.

Designed for `comint-input-filter-functions': fires on the first
non-empty user input, derives the conversation key directly from
the input text (sidestepping the session-list cache), and writes
any pending tags + workspace under that key in v2 format.

Removes itself from `comint-input-filter-functions' after a
successful flush so the work runs at most once per buffer.  Empty
or whitespace-only input leaves the hook in place for the next
submission."
  (when (and input (stringp input)
             (not (string-empty-p (string-trim input))))
    (let ((conv-key (decknix--agent-conversation-key input)))
      (when conv-key
        ;; Stash conv-key buffer-locally for header-line lookups.
        (unless decknix--agent-conv-key
          (setq-local decknix--agent-conv-key conv-key))
        ;; Register the session id under the conv-key when known.
        (when (and (boundp 'decknix--agent-auggie-session-id)
                   decknix--agent-auggie-session-id)
          (decknix--agent-register-session-id
           conv-key decknix--agent-auggie-session-id))
        ;; Persist pending tags + workspace.
        (when (or decknix--agent-pending-tags
                  decknix--agent-pending-workspace)
          (decknix--agent-store-metadata-by-conv-key
           conv-key
           decknix--agent-pending-tags
           decknix--agent-pending-workspace)
          (when decknix--agent-pending-workspace
            (setq-local decknix--agent-workspace-persisted t))
          (when decknix--agent-pending-tags
            (message "Tags applied: [%s]"
                     (string-join decknix--agent-pending-tags
                                  ", ")))
          (setq-local decknix--agent-pending-tags nil)
          (setq-local decknix--agent-pending-workspace nil))
        ;; One-shot: remove ourselves from the buffer-local hook.
        (remove-hook 'comint-input-filter-functions
                     #'decknix--agent-flush-pending-metadata
                     t)))))

(defun decknix--agent-store-metadata-by-conv-key (conv-key tags workspace)
  "Store TAGS and WORKSPACE directly under CONV-KEY in the tag store.
Use this when the conversation key is known at creation time (e.g., quickactions
where the first message is the command itself)."
  (when conv-key
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (or (gethash conv-key convs)
                      (let ((h (make-hash-table :test 'equal)))
                        (puthash "sessions" nil h)
                        h))))
      (when tags
        (let ((existing (gethash "tags" entry)))
          (dolist (tag tags)
            (cl-pushnew tag existing :test #'string=))
          (puthash "tags" existing entry)))
      (when workspace
        (puthash "workspace" workspace entry))
      ;; Bump recency
      (puthash "lastAccessed"
               (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t) entry)
      (puthash conv-key entry convs)
      (decknix--agent-tags-write store))))

(defun decknix--agent-register-session-id (conv-key session-id)
  "Ensure SESSION-ID is in the sessions list for CONV-KEY.
This keeps all session snapshots (original + resumed) linked to
the same conversation."
  (when (and conv-key session-id)
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (gethash conv-key convs)))
      (when entry
        (let ((sids (gethash "sessions" entry)))
          (unless (and sids (member session-id sids))
            (puthash "sessions"
                     (cons session-id (or sids '()))
                     entry)
            (decknix--agent-tags-write store)))))))


(defun decknix--agent-auto-persist-workspace ()
  "Auto-persist workspace for the current buffer.

Safety net for sessions created via any path (upstream `c', guided
`n', quickaction, resumed, etc.) so they never show as
\"unknown-ws\".  Two persistence paths converge on
`decknix--agent-flush-pending-metadata':

1. Comint input-filter hook — fires on the first user input and
   derives the conversation key directly from the typed text.
   Handles new sessions where the input ring is empty at
   prompt-ready.

2. `prompt-ready' subscription — for resumed sessions, the input
   ring already carries history, so the conv-key can be derived
   from the oldest entry without waiting for fresh input.

Whichever fires first wins; the other no-ops via the
`decknix--agent-workspace-persisted' guard."
  (let ((buf (current-buffer)))
    ;; Stash workspace + install comint hook (covers new sessions).
    (with-current-buffer buf
      (let ((ws (or decknix--agent-session-workspace
                    default-directory)))
        (when (and ws (stringp ws) (not (string-empty-p ws))
                   (not decknix--agent-workspace-persisted))
          ;; Don't override a workspace already stashed by
          ;; the guided post-create path.
          (unless decknix--agent-pending-workspace
            (setq-local decknix--agent-pending-workspace ws))
          (add-hook 'comint-input-filter-functions
                    #'decknix--agent-flush-pending-metadata
                    nil t))))
    ;; Resume-time safety net: if the ring already has history
    ;; when prompt-ready fires, flush immediately using the
    ;; oldest ring entry as the first message.
    (agent-shell-subscribe-to
     :shell-buffer buf
     :event 'prompt-ready
     :on-event
     (eval `(lambda (_event)
              (when (and (buffer-live-p ,buf)
                         (not (buffer-local-value
                               'decknix--agent-workspace-persisted ,buf)))
                (condition-case nil
                    (with-current-buffer ,buf
                      (let* ((ring (and (boundp 'comint-input-ring)
                                        comint-input-ring))
                             (first-msg
                              (when (and ring (ring-p ring)
                                         (> (ring-length ring) 0))
                                (ring-ref ring
                                          (1- (ring-length ring))))))
                        (when (and first-msg
                                   (not (string-empty-p first-msg)))
                          (decknix--agent-flush-pending-metadata
                           first-msg))))
                  (error nil))))
           t))))
(defun decknix-agent-session-new (&optional quick)
  "Start a new agent session with guided setup.
Prompts for workspace directory, session name, and initial tags.

With prefix argument QUICK, skip prompts and use defaults:
workspace = project root, name = auto-generated, no tags."
  (interactive "P")
  (let* ((default-ws (decknix--agent-detect-workspace))
         (workspace (if quick default-ws
                      (read-directory-name "Workspace: " default-ws nil t)))
         (workspace (expand-file-name workspace))
         (dir-name (file-name-nondirectory
                    (directory-file-name workspace)))
         (branch (decknix--agent-detect-branch workspace))
         (default-name (if branch
                           (format "%s/%s" dir-name branch)
                         dir-name))
         (name (if quick default-name
                 (read-string (format "Session name [%s]: " default-name)
                              nil nil default-name)))
         (tags (unless quick
                 (let ((input (completing-read-multiple
                               "Tags (comma-separated): "
                               (decknix--agent-tags-all)
                               nil nil)))
                   (mapcar #'string-trim
                           (seq-remove #'string-empty-p input)))))
         (before-buffers (buffer-list))
         ;; Build an augmented command with --workspace-root.
         ;; We must capture this in a closure rather than using a let-binding
         ;; of agent-shell-auggie-acp-command, because the :client-maker
         ;; lambda is stored in agent-shell--state and called later
         ;; (when the first message is sent) — by which time a dynamic
         ;; let-binding would have expired.
         (augmented-cmd
          (append agent-shell-auggie-acp-command
                  (list "--workspace-root" workspace)))
         ;; Create config with a client-maker that closes over augmented-cmd.
         ;; eval+backquote is needed because default.el uses dynamic binding.
         (config
          (let ((base (agent-shell-auggie-make-agent-config)))
            (setf (alist-get :client-maker base)
                  (eval `(lambda (buffer)
                           (agent-shell--make-acp-client
                            :command ,(car augmented-cmd)
                            :command-params ',(cdr augmented-cmd)
                            :environment-variables
                            (cond ((map-elt agent-shell-auggie-authentication :none)
                                   agent-shell-auggie-environment)
                                  ((map-elt agent-shell-auggie-authentication :login)
                                   agent-shell-auggie-environment)
                                  (t
                                   (error "Invalid Auggie authentication")))
                            :context-buffer buffer)) t))
            base)))
    ;; Set default-directory so agent-shell-cwd picks up the chosen
    ;; workspace instead of inheriting the calling buffer's directory
    ;; (which may be ~/ when invoked from the welcome screen).
    (let ((default-directory workspace))
      (agent-shell-start :config config))
    ;; Invalidate session cache so next picker is fresh
    (setq decknix--agent-session-cache-time 0)
    ;; Post-creation: rename buffer immediately, subscribe to prompt-ready for metadata
    (decknix--agent-session-new-post-create
     before-buffers name tags workspace)
    (message "Starting agent session \"%s\" in %s…" name workspace)))

(defun decknix--agent-session-new-post-create
    (before-buffers name tags workspace &optional first-message)
  "Post-creation setup: rename buffer to NAME, apply TAGS, record WORKSPACE.
BEFORE-BUFFERS is the buffer snapshot taken before agent-shell-start.
Finds the new buffer immediately (agent-shell-start creates it synchronously),
renames it, and persists metadata.

FIRST-MESSAGE, if provided, is the text that will be sent as the first user
message (e.g., the quickaction command).  When available, metadata (tags +
workspace) is stored immediately using a conversation key derived from it.
Otherwise, metadata is deferred to the `prompt-ready' event and stored
once the first exchange completes.  All state is per-buffer — safe for
batch launches."
  (let ((shell-buf (decknix--agent-find-new-shell-buffer before-buffers)))
    (when shell-buf
      ;; Rename immediately — the buffer exists now
      (with-current-buffer shell-buf
        (rename-buffer
         (generate-new-buffer-name
          (format "*Auggie: %s*" name)))
        (setq-local shell-maker--buffer-name-override
                    (buffer-name))
        (when workspace
          (setq-local decknix--agent-session-workspace workspace)))
      ;; Persist metadata.
      ;; When first-message is known (quickactions), we can derive the
      ;; conversation key NOW and store tags + workspace immediately.
      ;; Otherwise, stash them as pending buffer-locals and let the
      ;; comint input filter flush them once the user submits the
      ;; first message — the conversation key is derived directly
      ;; from that text, which sidesteps the prompt-ready race
      ;; (empty input ring, stale session cache).
      (let ((conv-key (when first-message
                        (decknix--agent-conversation-key first-message))))
        (if (and conv-key (or tags workspace))
            ;; Immediate storage — we know the conversation key
            (progn
              (decknix--agent-store-metadata-by-conv-key
               conv-key tags workspace)
              ;; Store conv-key buffer-locally so header-line can
              ;; look up tags immediately without waiting for the
              ;; session-list cache to refresh.
              (with-current-buffer shell-buf
                (setq-local decknix--agent-conv-key conv-key)
                (when workspace
                  (setq-local decknix--agent-workspace-persisted t)))
              (when tags
                (message "Tags applied: [%s]"
                         (string-join tags ", "))))
          ;; Deferred — stash pending metadata and wire the
          ;; one-shot input-filter hook that will flush it once
          ;; the user types their first message.
          (when (or tags workspace)
            (with-current-buffer shell-buf
              (setq-local decknix--agent-pending-tags tags)
              (setq-local decknix--agent-pending-workspace workspace)
              (add-hook 'comint-input-filter-functions
                        #'decknix--agent-flush-pending-metadata
                        nil t))))
        ;; ALWAYS subscribe to prompt-ready to set session-id.
        ;; The session-id is only available after ACP bootstrapping,
        ;; which is async.  We also opportunistically register the
        ;; session-id under a conv-key derived from the comint input
        ;; ring — useful for resumed sessions where the ring already
        ;; carries history at prompt-ready time.  For new guided
        ;; sessions the ring is empty here; the comint input-filter
        ;; hook installed above handles that case.
        (agent-shell-subscribe-to
         :shell-buffer shell-buf
         :event 'prompt-ready
         :on-event
         (eval `(lambda (_event)
                  (when (buffer-live-p ,shell-buf)
                    (condition-case nil
                        (with-current-buffer ,shell-buf
                          (let ((sid (or decknix--agent-auggie-session-id
                                         (when (and (boundp 'shell-maker--config)
                                                    shell-maker--config)
                                           (map-nested-elt (agent-shell--state)
                                                           '(:session :id))))))
                            (when (and sid (stringp sid)
                                      (not (string-empty-p sid)))
                              (setq-local decknix--agent-auggie-session-id sid)
                              (let* ((ring (and (boundp 'comint-input-ring)
                                               comint-input-ring))
                                     (first-msg (when (and ring
                                                           (ring-p ring)
                                                           (> (ring-length ring) 0))
                                                  (ring-ref ring
                                                            (1- (ring-length ring)))))
                                     (conv-key (when (and first-msg
                                                          (not (string-empty-p first-msg)))
                                                 (decknix--agent-conversation-key
                                                  first-msg))))
                                (unless decknix--agent-conv-key
                                  (when conv-key
                                    (setq-local decknix--agent-conv-key conv-key)))
                                (when conv-key
                                  (decknix--agent-register-session-id
                                   conv-key sid))))))
                      (error nil))))
               t))))))

(defun decknix-agent-session-quit ()
  "Cleanly quit the current agent-shell session.
Kills the buffer (which sends SIGHUP to auggie, saving the session).

If other live agent-shell sessions exist, switches to the most
recently used one (no prompt).  Use `C-c A s' afterwards to pick a
different session.  If this was the last session, returns to the
welcome screen or *scratch*."
  (interactive)
  (unless (derived-mode-p 'agent-shell-mode)
    (user-error "Not in an agent-shell buffer"))
  (when (y-or-n-p "Quit this agent session? ")
    (let* ((buf (current-buffer))
           ;; agent-shell-buffers is MRU-first; after removing the
           ;; current buffer, (car other-bufs) is the most recently
           ;; used remaining live agent-shell buffer.
           (other-bufs (remq buf
                             (when (fboundp 'agent-shell-buffers)
                               (agent-shell-buffers)))))
      (kill-buffer buf)
      (cond
       ;; Switch to MRU agent-shell buffer — natural "next session"
       ;; flow, no picker prompt.  User can hit `C-c A s' to choose.
       (other-bufs
        (switch-to-buffer (car other-bufs)))
       ;; Last session — return to welcome or scratch
       ((fboundp 'decknix-welcome)
        (decknix-welcome))
       (t
        (switch-to-buffer (get-buffer-create "*scratch*")))))))

(defun decknix-agent-session-recent ()
  "Quickly pick from recently used conversations.
Like `recentf' but for agent sessions — shows the most recent
conversations (newest first), annotated with workspace and tags."
  (interactive)
  (let* ((sessions (decknix--agent-session-list))
         (groups (when sessions
                   (decknix--agent-session-group-by-conversation sessions)))
         (live-conv-keys
          (seq-filter
           #'identity
           (mapcar (lambda (buf)
                     (when (buffer-live-p buf)
                       (with-current-buffer buf
                         (when (derived-mode-p 'agent-shell-mode)
                           (ignore-errors (decknix--session-conv-id))))))
                   (if (fboundp 'agent-shell-buffers)
                       (agent-shell-buffers) nil))))
         (candidates nil))
    ;; Build candidate list from conversation groups (already sorted newest first)
    (dolist (group groups)
      (let* ((conv-key (car group))
             (latest (cadr group))
             (name (decknix--agent-session-display-name latest))
             (workspace (when conv-key
                          (decknix--agent-workspace-for-conv-key conv-key)))
             (ws-short (if workspace
                           (if (string-match "/\\([^/]+\\)/?$"
                                             (abbreviate-file-name workspace))
                               (match-string 1 (abbreviate-file-name workspace))
                             (abbreviate-file-name workspace))
                         "?"))
             (tags (when conv-key
                     (decknix--agent-tags-for-conv-key conv-key)))
             (tag-str (if tags
                          (mapconcat (lambda (tg) (concat "#" tg)) tags " ")
                        ""))
             (live-p (member conv-key live-conv-keys))
             (label (format "%s%s"
                            (if live-p "● " "  ")
                            name)))
        (push (list label ws-short conv-key latest workspace live-p tag-str)
              candidates)))
    (setq candidates (nreverse candidates))
    (unless candidates
      (user-error "No saved sessions found"))
    ;; Build completion table with annotations (workspace + tags)
    (let* ((max-name (apply #'max (mapcar (lambda (c) (length (car c))) candidates)))
           (annotator
            (eval
             `(lambda (cand)
                (when-let ((entry (assoc cand ',candidates)))
                  (let ((ws (nth 1 entry))
                        (tags (nth 6 entry)))
                    (format "%s @%-12s %s"
                            (make-string (- ,(+ max-name 2) (length cand)) ?\s)
                            ws
                            tags))))
             t))
           (table (decknix--agent-unsorted-table
                   (mapcar #'car candidates)))
           (selection
            (let ((completion-extra-properties
                   (list :annotation-function annotator)))
              (completing-read "Recent session: " table nil t))))
      (when-let ((entry (assoc selection candidates)))
        (let ((conv-key (nth 2 entry))
              (session (nth 3 entry))
              (workspace (nth 4 entry))
              (live-p (nth 5 entry)))
          (if live-p
              ;; Already live — find and switch to the buffer
              (let ((buf (seq-find
                          (lambda (b)
                            (when (buffer-live-p b)
                              (with-current-buffer b
                                (when (derived-mode-p 'agent-shell-mode)
                                  (equal conv-key
                                         (ignore-errors
                                           (decknix--session-conv-id)))))))
                          (agent-shell-buffers))))
                (if buf (switch-to-buffer buf)
                  (user-error "Live buffer not found")))
            ;; Saved — resume
            (let ((session-id (alist-get 'sessionId session))
                  (name (decknix--agent-session-display-name session)))
              (unless workspace
                (setq workspace
                      (read-directory-name "Workspace: " nil nil t)))
              (decknix--agent-session-resume
               session-id
               decknix-agent-session-history-count
               name workspace conv-key))))))))

(defun decknix--agent-session-open-share (session-id)
  "Generate a share link for SESSION-ID and open it in Emacs.
Uses xwidget-webkit if available, otherwise falls back to eww."
  (message "Generating share link for %s..." (substring session-id 0 8))
  (let* ((output (shell-command-to-string
                  (format "auggie session share %s 2>&1"
                          (shell-quote-argument session-id))))
         (url (when (string-match "https://[^ \t\n]+" output)
                (match-string 0 output))))
    (if url
        (progn
          (message "Opening %s" url)
          (if (fboundp 'xwidget-webkit-browse-url)
              (xwidget-webkit-browse-url url t)
            (eww url t)))
      (user-error "Failed to generate share link: %s"
                  (string-trim output)))))

(defun decknix--agent-session-pick-for-history ()
  "Prompt to pick a saved session and return its full ID."
  (let* ((sessions (decknix--agent-session-list))
         (entries (mapcar (lambda (session)
                           (cons (decknix--agent-session-preview session)
                                 (alist-get 'sessionId session)))
                         sessions))
         (selection (completing-read "View history for session: "
                                    (decknix--agent-unsorted-table
                                     (mapcar #'car entries))
                                    nil t)))
    (or (cdr (assoc selection entries))
        (user-error "No session selected"))))

(defun decknix-agent-session-history (&optional pick)
  "View conversation history for a session.
Without prefix argument PICK, shows history for the current session
if in an agent-shell buffer with a known session ID, otherwise
prompts to pick a session.
With \\[universal-argument], always prompts to pick a session.
Opens in xwidget-webkit (q to quit) or eww as fallback."
  (interactive "P")
  (let ((session-id
         (if (and (not pick)
                  (derived-mode-p 'agent-shell-mode)
                  decknix--agent-auggie-session-id)
             decknix--agent-auggie-session-id
           (decknix--agent-session-pick-for-history))))
    (decknix--agent-session-open-share session-id)))       ; View history (C-u to pick)

;; == Session tagging: metadata layer for session organisation ==
;; Tags are conversation-scoped, keyed by a conversation hash
;; derived from firstUserMessage (shared across all session snapshots).
;; Format v2:
;; {"conversations": {"conv-hash": {"tags": [...], "sessions": [...]}},
;;  "bookmarks": {"session-id": {"label": "...", "created": "..."}}}

;; `decknix--agent-tags-file' (path to ~/.config/decknix/agent-sessions.json)
;; moved out of this heredoc into agent-shell/agent/decknix-agent-tags-store.el
;; alongside the cache state and the read/write/conversations triple.
;; Required by the heredoc immediately after the conversation-key /
;; session-cache modules so callers in this file resolve at load time.
(defvar decknix--agent-tags-file)

;; Conversation-key derivation + mergedInto resolution (PR B.34) —
;; moved out of this heredoc into
;; agent-shell/agent/decknix-agent-conv-resolve.el, packaged as
;; `decknix-agent-conv-resolve-el'.  Owns the canonical
;; `decknix--agent-conversation-key' (raw hash → mergedInto
;; resolution), the redirect-walker `decknix--agent-conv-resolve-key',
;; and the two session-aware lookups
;; (`decknix--agent-conversation-key-for-session' /
;; `decknix--agent-latest-session-id-for-conv-key').
;;
;; The module is required from the heredoc immediately after the
;; tags-store + session-cache modules so callers in this file
;; (~30 sites that hash a first-message to a conv-key) resolve
;; cleanly at load time.  Forward-declared here so that the rest
;; of this file byte-compiles clean.
(declare-function decknix--agent-conversation-key
                  "decknix-agent-conv-resolve" (first-message))
(declare-function decknix--agent-conv-resolve-key
                  "decknix-agent-conv-resolve" (conv-key))
(declare-function decknix--agent-conversation-key-for-session
                  "decknix-agent-conv-resolve" (session-id))
(declare-function decknix--agent-latest-session-id-for-conv-key
                  "decknix-agent-conv-resolve" (conv-key))

;; Tag store storage layer (PR B.28) — moved out of this heredoc into
;; agent-shell/agent/decknix-agent-tags-store.el, packaged as
;; `decknix-agent-tags-store-el'.  Owns the file path, the in-memory
;; cache (hash + mtime + checked-at + TTL), the v1->v2 auto-migration
;; in `decknix--agent-tags-read', and the persistence pair
;; (`decknix--agent-tags-write' + `decknix--agent-tags-conversations').
;;
;; The migration walk inside `decknix--agent-tags-read' calls back
;; into `decknix--agent-session-list' (now in
;; `decknix-agent-session-cache') and `decknix--agent-conversation-key'
;; (still in this heredoc, since it threads mergedInto-redirect
;; resolution through this very store and so cannot live in the
;; lower-level package).  Both are forward-declared in the module.
;;
;; Forward declarations here so the rest of this file (which
;; references the cache hash + the read/write pair from many call
;; sites) byte-compiles clean.
(defvar decknix--agent-tags-cache)
(defvar decknix--agent-tags-cache-mtime)
(defvar decknix--agent-tags-cache-checked-at)
(defvar decknix--agent-tags-cache-ttl)
(declare-function decknix--agent-tags-read
                  "decknix-agent-tags-store" ())
(declare-function decknix--agent-tags-write
                  "decknix-agent-tags-store" (store))
(declare-function decknix--agent-tags-conversations
                  "decknix-agent-tags-store" (store))

;; -- Per-conversation lastAccessed stamp (PR B.42) --
;; Moved out of this file into
;; agent-shell/agent/decknix-agent-conv-recency.el, packaged as
;; `decknix-agent-conv-recency-el'.  Owns the touch (writer)
;; and last-accessed (reader) pair that mediates the
;; `lastAccessed' field of `~/.config/decknix/agent-sessions.json'.
;; The two call sites in this file (the touch invocation in the
;; conv-tag flow at ~line 895, and the last-accessed lookup in
;; the conversation-group sort comparator at ~lines 991-992)
;; reach the symbols through the heredoc's `(require ...)' chain.
(declare-function decknix--agent-conv-touch
                  "decknix-agent-conv-recency" (conv-key))
(declare-function decknix--agent-conv-last-accessed
                  "decknix-agent-conv-recency" (conv-key))

;; -- Tags read accessors (PR B.43) --
;; Moved out of this file into
;; agent-shell/agent/decknix-agent-tags-read.el, packaged as
;; `decknix-agent-tags-read-el'.  Owns the two pure readers
;; (`decknix--agent-tags-for-session' /
;; `decknix--agent-tags-for-conv-key') consumed by many call
;; sites here, in workspace-bulk, in the progress modules, and
;; in the heredoc.  The interactive tag *writers* stay in this
;; file per AGENTS.md Rule 2.
(declare-function decknix--agent-tags-for-session
                  "decknix-agent-tags-read" (session-id))
(declare-function decknix--agent-tags-for-conv-key
                  "decknix-agent-tags-read" (conv-key))

;; -- Per-conversation workspace persistence (PR B.40) --
;; Moved out of this file into
;; agent-shell/agent/decknix-agent-session-workspace.el,
;; packaged as `decknix-agent-session-workspace-el'.  Owns the
;; reader (`decknix--agent-workspace-for-conv-key') and the two
;; writers (`-session-save-workspace' resolving via session-id;
;; `-session-save-workspace-for-conv-key' direct).  The eight
;; call sites in this file (resume / picker / quick-action paths
;; at lines ~1016 / 1123 / 1141 / 1172 / 1550 / 1557 / 2023 /
;; 4663) reach the symbols through the heredoc's `(require ...)'
;; chain.  The two call sites in workspace-bulk (lines 1071 /
;; 3545) similarly come through the heredoc.
(declare-function decknix--agent-workspace-for-conv-key
                  "decknix-agent-session-workspace" (conv-key))
(declare-function decknix--agent-session-save-workspace
                  "decknix-agent-session-workspace" (session-id workspace))
(declare-function decknix--agent-session-save-workspace-for-conv-key
                  "decknix-agent-session-workspace" (conv-key workspace))

;; -- Per-session model persistence --
;;
;; The global default model lives in ~/.augment/settings.json
;; (declared via decknix.cli.auggie.settings.model).  Any
;; per-session override the user makes with C-c C-v is stored
;; here so that resume-time we can pass --model <id> and get
;; back the same agent the user was working with.
;;
;; The two storage primitives (`decknix--agent-session-model-
;; for-conv-key' and `-save-model-for-conv-key') were carved
;; out into agent-shell/agent/decknix-agent-session-model.el
;; (PR B.37), packaged as `decknix-agent-session-model-el'.
;; The interactive `decknix-agent-set-session-model' command
;; below stays here per AGENTS.md Rule 2 -- it wraps the
;; upstream `agent-shell-set-session-model' UI verb whose
;; on-success callback simply calls into the module's `save'
;; primitive.  Forward declarations here so the call sites in
;; this file (line ~815 in the resume path and the `set-session-
;; model' wrapper below) byte-compile clean.
(declare-function decknix--agent-session-model-for-conv-key
                  "decknix-agent-session-model" (conv-key))
(declare-function decknix--agent-session-save-model-for-conv-key
                  "decknix-agent-session-model" (conv-key model-id))

(defun decknix-agent-set-session-model ()
  "Change the model for the current agent-shell session and persist it.
Wraps `agent-shell-set-session-model' with an on-success callback
that records the new model-id against the current conversation in
agent-sessions.json so subsequent resumes pass `--model <id>' to
auggie."
  (interactive)
  (agent-shell-set-session-model
   (eval `(lambda ()
            (let ((model-id (map-nested-elt
                             (agent-shell--state)
                             '(:session :model-id)))
                  (conv-key (bound-and-true-p
                             decknix--agent-conv-key)))
              (when (and conv-key model-id)
                (decknix--agent-session-save-model-for-conv-key
                 conv-key model-id)
                (message "Model %s saved for this conversation"
                         model-id))))
         t)))

;; -- PR / repo linking: store/retrieve linked items per conversation --
;;
;; Source moved out of this heredoc into
;; agent-shell/agent/decknix-agent-link-store.el, packaged as
;; `decknix-agent-link-store-el'.  Provides the seven entry points
;; that mutate the per-conversation `linked_prs' record set:
;;
;;   `decknix--agent-linked-items' / `-prs' / `-repos'
;;   `decknix--agent-link-pr'   / `-unlink-pr'
;;   `decknix--agent-link-repo' / `-unlink-repo'
;;
;; The module loads the storage layer (`decknix-agent-tags-store')
;; and the URL parsers (`decknix-agent-url-parse') itself, so the
;; heredoc only needs the existing top-level (require) lines.  Hub-
;; side post-mutation callbacks (write-linked-prs / pr-fetch-async /
;; repo-fetch-async) are gated through `fboundp' inside the module.
(declare-function decknix--agent-linked-items "decknix-agent-link-store" (conv-key))
(declare-function decknix--agent-linked-prs   "decknix-agent-link-store" (conv-key))
(declare-function decknix--agent-linked-repos "decknix-agent-link-store" (conv-key))
(declare-function decknix--agent-link-pr      "decknix-agent-link-store"
                  (conv-key url &optional pr-type added))
(declare-function decknix--agent-unlink-pr    "decknix-agent-link-store" (conv-key url))
(declare-function decknix--agent-link-repo    "decknix-agent-link-store"
                  (conv-key url branch &optional added))
(declare-function decknix--agent-unlink-repo  "decknix-agent-link-store"
                  (conv-key url branch))

;; `decknix--agent-pr-url-accessor' lives in
;; agent-shell/agent/decknix-agent-url-parse.el — required at
;; the top of this heredoc.

;; -- VCS detection helpers (used by repo-linking commands) --
;;
;; `decknix--vcs-kind', `decknix--git-remote-url' and
;; `decknix--detect-default-branch' all live in
;; agent-shell/agent/decknix-agent-vcs.el (PR B.25 carved the
;; latter two out alongside the original `decknix--vcs-kind').
;; Required at the top of this heredoc.

(declare-function decknix--git-remote-url "decknix-agent-vcs")
(declare-function decknix--detect-default-branch "decknix-agent-vcs")

;; -- Tags aggregation (PR B.44) --
;; `decknix--agent-tags-all' moved into the existing
;; `decknix-agent-tags-read' module alongside the two read
;; accessors carved in B.43.  The four call sites in this file
;; (~lines 1820 / 2390 / 2480 / 2532 / 2561) reach the symbol
;; through the heredoc's `(require ...)' chain.
(declare-function decknix--agent-tags-all
                  "decknix-agent-tags-read")

;; -- Session-id + conv-key accessors (PR B.48) --
;; Moved into agent-shell/agent/decknix-agent-session-id.el.
;; The buffer-local `decknix--agent-auggie-session-id' defvar
;; itself stays in this file (initialised by the agent-shell
;; startup hook -- a side-effect that belongs in the heredoc by
;; Rule 2).  Many call sites in this file (~lines 2301 / 2314 /
;; 2315 / 2384 / 2545 / 2554 / 2555 / ...) and one in the
;; workspace heredoc (~line 1608) reach the moved symbols
;; through the heredoc's `(require ...)' chain.
(declare-function decknix--agent-current-session-id
                  "decknix-agent-session-id")
(declare-function decknix--agent-require-session-id
                  "decknix-agent-session-id")
(declare-function decknix--agent-require-conv-key
                  "decknix-agent-session-id")

(defun decknix-agent-tag-show ()
  "Show the tags for the current conversation."
  (interactive)
  (let* ((session-id (decknix--agent-require-session-id))
         (tags (decknix--agent-tags-for-session session-id)))
    (if tags
        (message "Conversation tags: [%s]" (string-join tags ", "))
      (message "No tags on this conversation"))))

(defun decknix-agent-tag-add ()
  "Add tags to the current conversation.
Accepts comma-separated input for multiple tags at once — completion
re-fires after each comma so subsequent tags can be picked from the
same set.  Shows all existing tags for completion; type new names to
create them.  Already-applied tags are annotated `(applied)'."
  (interactive)
  (let* ((conv-key (decknix--agent-require-conv-key))
         (session-id (decknix--agent-require-session-id))
         (existing (decknix--agent-tags-all))
         (current (decknix--agent-tags-for-conv-key conv-key))
         ;; Show which tags are already applied via annotation
         (annotator (eval
                     `(lambda (tag)
                        (if (member tag ',current) " (applied)" ""))
                     t))
         ;; completing-read-multiple invokes completion for each
         ;; entry between `crm-separator' (defaults to `,' with
         ;; optional surrounding whitespace), returning a list of
         ;; strings.  Replaces the prior single completing-read +
         ;; split-string approach which only completed the first tag.
         (input (let ((completion-extra-properties
                       (list :annotation-function annotator)))
                  (completing-read-multiple
                   "Add tag(s) (comma-separated): "
                   existing nil nil)))
         ;; Defensive: trim whitespace, remove empties.  CRM already
         ;; trims via `crm-separator', but a stray empty entry from
         ;; a trailing comma would otherwise become a "" tag.
         (new-tags (seq-remove #'string-empty-p
                               (mapcar #'string-trim input))))
    (unless new-tags
      (user-error "No tags provided"))
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (or (gethash conv-key convs)
                      (let ((h (make-hash-table :test 'equal)))
                        (puthash "tags" nil h)
                        (puthash "sessions" nil h)
                        h)))
           (tags (gethash "tags" entry))
           (sids (gethash "sessions" entry))
           (added nil)
           (skipped nil))
      ;; Add each tag, tracking what was added vs already present
      (dolist (tag new-tags)
        (if (member tag tags)
            (push tag skipped)
          (setq tags (append tags (list tag)))
          (push tag added)))
      (puthash "tags" tags entry)
      ;; Track this session in the conversation
      (cl-pushnew session-id sids :test #'string=)
      (puthash "sessions" sids entry)
      ;; Bump recency so this conversation sorts to the top
      (puthash "lastAccessed"
               (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t) entry)
      (puthash conv-key entry convs)
      (decknix--agent-tags-write store)
      ;; Report what happened
      (cond
       ((and added (not skipped))
        (message "Tagged: %s → [%s]"
                 (string-join (nreverse added) ", ")
                 (string-join tags ", ")))
       ((and added skipped)
        (message "Tagged: %s (already had: %s) → [%s]"
                 (string-join (nreverse added) ", ")
                 (string-join (nreverse skipped) ", ")
                 (string-join tags ", ")))
       (t
        (message "All tags already applied: [%s]"
                 (string-join tags ", ")))))))

(defun decknix-agent-tag-remove ()
  "Remove a tag from the current conversation."
  (interactive)
  (let* ((conv-key (decknix--agent-require-conv-key))
         (current (decknix--agent-tags-for-conv-key conv-key)))
    (unless current
      (user-error "This conversation has no tags"))
    (let* ((tag (completing-read "Remove tag: " current nil t))
           (store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (gethash conv-key convs))
           (remaining (remove tag (gethash "tags" entry))))
      (if remaining
          (progn
            (puthash "tags" remaining entry)
            (puthash "lastAccessed"
                     (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t) entry))
        (remhash conv-key convs))
      (decknix--agent-tags-write store)
      (message "Removed \"%s\" from conversation" tag))))

(defun decknix-agent-tag-list ()
  "List conversations filtered by tag.
Prompts for a tag, then shows the latest session per matching conversation."
  (interactive)
  (let* ((all-tags (decknix--agent-tags-all)))
    (unless all-tags
      (user-error "No tags defined yet"))
    (let* ((tag (completing-read "Filter by tag: " all-tags nil t))
           (store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (sessions (decknix--agent-session-list))
           (conv-groups (decknix--agent-session-group-by-conversation sessions))
           (matching nil))
      ;; Find conversations with this tag
      (maphash (lambda (conv-key entry)
                 (when (and (hash-table-p entry)
                            (member tag (gethash "tags" entry)))
                   (push conv-key matching)))
               convs)
      (unless matching
        (user-error "No conversations tagged \"%s\"" tag))
      ;; Build picker from latest session per matching conversation
      (let* ((entries
              (cl-loop for conv-key in matching
                       for group = (seq-find
                                    (lambda (g) (string= (car g) conv-key))
                                    conv-groups)
                       when group
                       collect (let* ((latest (cadr group))
                                      (tags (decknix--agent-tags-for-conv-key conv-key))
                                      (tag-str (if tags (format " [%s]" (string-join tags ", ")) "")))
                                 (cons (format "%s%s"
                                               (decknix--agent-session-preview latest)
                                               tag-str)
                                       (cons 'session latest))))))
        (unless entries
          (user-error "No sessions found for tag \"%s\"" tag))
        (let* ((selection (completing-read
                           (format "Conversations tagged \"%s\": " tag)
                           (decknix--agent-unsorted-table
                            (mapcar #'car entries)) nil t))
               (chosen (cdr (assoc selection entries)))
               (session (cdr chosen))
               (session-id (alist-get 'sessionId session)))
          (let ((conv-key (decknix--agent-conversation-key
                           (alist-get 'firstUserMessage
                                      session ""))))
            (decknix--agent-session-resume
             session-id
             decknix-agent-session-history-count
             (decknix--agent-session-display-name session)
             nil conv-key)))))))

(defun decknix-agent-tag-edit ()
  "Rename a tag across all conversations."
  (interactive)
  (let* ((all-tags (decknix--agent-tags-all)))
    (unless all-tags
      (user-error "No tags defined yet"))
    (let* ((old-tag (completing-read "Rename tag: " all-tags nil t))
           (new-tag (string-trim
                     (read-string (format "Rename \"%s\" to: " old-tag) old-tag)))
           (store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (count 0))
      (when (string-empty-p new-tag)
        (user-error "Tag cannot be empty"))
      (when (string= old-tag new-tag)
        (user-error "Same name, nothing to do"))
      (maphash (lambda (_key entry)
                 (when (hash-table-p entry)
                   (let ((tags (gethash "tags" entry)))
                     (when (member old-tag tags)
                       (puthash "tags"
                                (mapcar (lambda (tg) (if (string= tg old-tag) new-tag tg)) tags)
                                entry)
                       (cl-incf count)))))
               convs)
      (decknix--agent-tags-write store)
      (message "Renamed \"%s\" → \"%s\" across %d conversation%s"
               old-tag new-tag count (if (= count 1) "" "s")))))

(defun decknix-agent-tag-delete ()
  "Delete a tag from all conversations."
  (interactive)
  (let* ((all-tags (decknix--agent-tags-all)))
    (unless all-tags
      (user-error "No tags defined yet"))
    (let* ((tag (completing-read "Delete tag globally: " all-tags nil t)))
      (when (y-or-n-p (format "Delete tag \"%s\" from all conversations? " tag))
        (let* ((store (decknix--agent-tags-read))
               (convs (decknix--agent-tags-conversations store))
               (count 0)
               (empties nil))
          (maphash (lambda (key entry)
                     (when (hash-table-p entry)
                       (let ((tags (gethash "tags" entry)))
                         (when (member tag tags)
                           (let ((remaining (remove tag tags)))
                             (if remaining
                                 (puthash "tags" remaining entry)
                               (push key empties)))
                           (cl-incf count)))))
                   convs)
          (dolist (key empties) (remhash key convs))
          (decknix--agent-tags-write store)
          (message "Deleted \"%s\" from %d conversation%s"
                   tag count (if (= count 1) "" "s")))))))

(defun decknix-agent-tag-cleanup ()
  "Remove conversation entries that have no matching sessions on disk."
  (interactive)
  (let* ((store (decknix--agent-tags-read))
         (convs (decknix--agent-tags-conversations store))
         (sessions (decknix--agent-session-list))
         (conv-groups (decknix--agent-session-group-by-conversation sessions))
         (live-keys (mapcar #'car conv-groups))
         (orphans nil))
    (maphash (lambda (key _entry)
               (unless (member key live-keys)
                 (push key orphans)))
             convs)
    (if orphans
        (when (y-or-n-p (format "Remove %d orphaned conversation tag%s? "
                                (length orphans)
                                (if (= (length orphans) 1) "" "s")))
          (dolist (key orphans) (remhash key convs))
          (decknix--agent-tags-write store)
          (message "Cleaned up %d orphaned conversation%s"
                   (length orphans)
                   (if (= (length orphans) 1) "" "s")))
      (message "No orphaned conversations found"))))

;; == Rename session/conversation ==
;; Persists the name into agent-sessions.json tags so it survives
;; restarts and appears correctly in the sidebar and picker.

(defun decknix-agent-session-rename (new-name)
  "Rename the current conversation to NEW-NAME.
Updates the tags in agent-sessions.json (replacing all existing tags
with the new name) and renames the live buffer.  Works from any
agent-shell buffer."
  (interactive
   (let* ((conv-key (decknix--agent-require-conv-key))
          (current-tags (decknix--agent-tags-for-conv-key conv-key))
          (default (string-join current-tags "/")))
     (list (read-string (format "Rename conversation%s: "
                                (if (string-empty-p default) ""
                                  (format " (%s)" default)))
                        default))))
  (when (string-empty-p (string-trim new-name))
    (user-error "Name cannot be empty"))
  (let* ((conv-key (decknix--agent-require-conv-key))
         (session-id (decknix--agent-require-session-id))
         (store (decknix--agent-tags-read))
         (convs (decknix--agent-tags-conversations store))
         (entry (or (gethash conv-key convs)
                    (let ((h (make-hash-table :test 'equal)))
                      (puthash "tags" nil h)
                      (puthash "sessions" nil h)
                      h)))
         (sids (gethash "sessions" entry))
         ;; Split new-name on "/" or "," to allow multi-tag names
         (new-tags (seq-remove #'string-empty-p
                               (mapcar #'string-trim
                                       (split-string new-name "[/,]" t)))))
    ;; Update tags
    (puthash "tags" new-tags entry)
    (cl-pushnew session-id sids :test #'string=)
    (puthash "sessions" sids entry)
    ;; Bump recency
    (puthash "lastAccessed"
             (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t) entry)
    (puthash conv-key entry convs)
    (decknix--agent-tags-write store)
    ;; Rename the live buffer
    (let ((display (string-join new-tags "/")))
      (rename-buffer (format "*Auggie: %s*" display) t)
      (when (boundp 'shell-maker--buffer-name-override)
        (setq shell-maker--buffer-name-override (buffer-name)))
      ;; Refresh sidebar if visible
      (when (fboundp 'agent-shell-workspace-sidebar-refresh)
        (ignore-errors (agent-shell-workspace-sidebar-refresh)))
      (message "Renamed conversation → %s" display))))   ; Cleanup orphans

;; == Session ID: shortened display, copy, toggle ==

(defvar decknix--agent-show-full-session-id nil
  "When non-nil, show the full session ID in the header.
When nil (default), show only the first 8 characters.")

(defun decknix--agent-get-session-id ()
  "Return the current ACP session ID, or nil."
  (when (derived-mode-p 'agent-shell-mode)
    (map-nested-elt (agent-shell--state) '(:session :id))))

(defun decknix-agent-session-copy-id (&optional full)
  "Copy the session ID to the kill ring.
With prefix argument FULL (\\[universal-argument]), copy the full ID.
Otherwise copy the shortened 8-character hash."
  (interactive "P")
  (if-let ((id (decknix--agent-get-session-id)))
      (let ((result (if full id
                     (substring id 0 (min 8 (length id))))))
        (kill-new result)
        (message "Copied: %s" result))
    (user-error "No active session")))

(defun decknix-agent-session-toggle-id-display ()
  "Toggle between showing short (8-char) and full session ID in the header."
  (interactive)
  (setq decknix--agent-show-full-session-id
        (not decknix--agent-show-full-session-id))
  ;; Force header refresh
  (when (derived-mode-p 'agent-shell-mode)
    (setq-local agent-shell--header-cache (make-hash-table :test 'equal))
    (force-mode-line-update))
  (message "Session ID display: %s"
           (if decknix--agent-show-full-session-id "full" "short (8 chars)")))

;; == Compose buffer: magit-style prompt editing ==
;; Opens a buffer for composing multi-line prompts.
;; Supports sticky (persistent) and transient modes.
;; C-c C-c submits, C-c C-k cancels/clears, C-c C-s toggles sticky.
;; C-c k prefix: k = interrupt, C-c = interrupt + submit.

(defvar-local decknix--compose-target-buffer nil
  "The agent-shell buffer to submit the composed prompt to.")

(defvar-local decknix--compose-history-index -1
  "Current position in the prompt history.
-1 means not navigating history (showing user's own input).")

(defvar-local decknix--compose-saved-input nil
  "Saved user input before history navigation started.
Restored when cycling past the newest history entry.")

(defvar-local decknix--compose-history-items nil
  "Prompts loaded so far (current ring + streamed sessions).")

(defvar-local decknix--compose-history-seen nil
  "Hash table tracking prompts already in history-items (for dedup).")

(defvar-local decknix--compose-history-file-queue nil
  "Remaining session files to load on-demand (newest first).")

(defvar-local decknix--compose-history-exhausted nil
  "Non-nil when all session files have been processed.")

;; == On-demand per-file prompt extraction ==

(defvar decknix--prompt-extract-jq-filter-file nil
  "Path to temp file containing the jq filter for single-file extraction.")

(defun decknix--prompt-extract-ensure-jq-filter ()
  "Create the jq filter file for per-file prompt extraction."
  (unless (and decknix--prompt-extract-jq-filter-file
              (file-exists-p decknix--prompt-extract-jq-filter-file))
    (setq decknix--prompt-extract-jq-filter-file
          (make-temp-file "auggie-extract-" nil ".jq"))
    (with-temp-file decknix--prompt-extract-jq-filter-file
      (insert "[.chatHistory[].exchange.request_message"
              " // \"\" | select(length > 0)] | reverse\n")))
  decknix--prompt-extract-jq-filter-file)

(defun decknix--prompt-extract-from-file (file)
  "Extract user prompts from a single session FILE using jq.
Returns a list of non-empty strings, newest first."
  (condition-case nil
      (let* ((jqf (decknix--prompt-extract-ensure-jq-filter))
             (raw (shell-command-to-string
                   (concat "jq -c -f "
                           (shell-quote-argument jqf) " "
                           (shell-quote-argument file)
                           " 2>/dev/null")))
             (trimmed (string-trim raw)))
        (when (and (not (string-empty-p trimmed))
                   (string-prefix-p "[" trimmed))
          (let* ((json-array-type 'list)
                 (json-key-type 'symbol)
                 (msgs (json-read-from-string trimmed)))
            (seq-filter (lambda (m)
                          (and (stringp m)
                               (not (string-empty-p (string-trim m)))))
                        msgs))))
    (error nil)))

(defvar-local decknix--compose-history-local-only t
  "When non-nil, M-p/M-n only cycle the current session's prompts.
Set to nil by M-P/M-N to enable cross-session history navigation.")

(defun decknix--compose-history-init ()
  "Initialize on-demand history for this compose buffer.
Populates items from comint-input-ring.  When
`decknix--compose-history-local-only' is non-nil (default / M-p/M-n),
only current-session prompts are loaded.  When nil (M-P/M-N), also
builds the cross-session file queue for on-demand streaming."
  (let ((seen (make-hash-table :test 'equal))
        (items nil)
        (current-session-id nil))
    ;; 1. Current session's comint-input-ring
    (when (and decknix--compose-target-buffer
               (buffer-live-p decknix--compose-target-buffer))
      (with-current-buffer decknix--compose-target-buffer
        (setq current-session-id
              (when (bound-and-true-p decknix--agent-auggie-session-id)
                decknix--agent-auggie-session-id))
        (when (and (bound-and-true-p comint-input-ring)
                   (not (ring-empty-p comint-input-ring)))
          (dotimes (i (ring-length comint-input-ring))
            (let ((item (ring-ref comint-input-ring i)))
              (when (and (stringp item)
                         (not (string-empty-p (string-trim item)))
                         (not (gethash item seen)))
                (puthash item t seen)
                (push item items)))))))
    (setq items (nreverse items))
    ;; 2. File queue: only when cross-session mode is active (M-P/M-N)
    (if decknix--compose-history-local-only
        ;; Local-only: no file queue, mark exhausted immediately
        (setq decknix--compose-history-items items
              decknix--compose-history-seen seen
              decknix--compose-history-file-queue nil
              decknix--compose-history-exhausted t)
      ;; Cross-session: build file queue, exclude current session
      (let* ((dir decknix--agent-sessions-dir)
             (exclude-file (when current-session-id
                             (expand-file-name
                              (concat current-session-id ".json") dir)))
             ;; ls -t gives newest-first by mtime
             (all-files
              (split-string
               (shell-command-to-string
                (concat "ls -t "
                        (shell-quote-argument dir)
                        "/*.json 2>/dev/null"))
               "\n" t))
             (queue (if exclude-file
                        (seq-remove
                         (lambda (f) (string= f exclude-file))
                         all-files)
                      all-files)))
        (setq decknix--compose-history-items items
              decknix--compose-history-seen seen
              decknix--compose-history-file-queue queue
              decknix--compose-history-exhausted (null queue))))))

(defun decknix--compose-history-load-next-batch ()
  "Load prompts from the next session file(s) in the queue.
Keeps loading files until at least one new prompt is found or queue is empty.
Returns non-nil if new prompts were added."
  (let ((added nil))
    (while (and (not added) decknix--compose-history-file-queue)
      (let* ((file (pop decknix--compose-history-file-queue))
             (msgs (decknix--prompt-extract-from-file file)))
        (dolist (msg msgs)
          (unless (gethash msg decknix--compose-history-seen)
            (puthash msg t decknix--compose-history-seen)
            ;; Append to end of items list
            (setq decknix--compose-history-items
                  (nconc decknix--compose-history-items (list msg)))
            (setq added t)))))
    (when (null decknix--compose-history-file-queue)
      (setq decknix--compose-history-exhausted t))
    added))

(defun decknix--compose-history-navigate-previous ()
  "Core implementation: move to the previous (older) prompt in history."
  ;; Initialize on first navigation
  (unless decknix--compose-history-seen
    (decknix--compose-history-init))
  (let ((items decknix--compose-history-items))
    ;; Save current input when starting navigation
    (when (= decknix--compose-history-index -1)
      (setq decknix--compose-saved-input
            (buffer-substring-no-properties (point-min) (point-max))))
    ;; Try to move backward
    (let ((new-index (1+ decknix--compose-history-index)))
      (when (and (>= new-index (length items))
                 (not decknix--compose-history-exhausted))
        ;; Need more — load next session file(s)
        (decknix--compose-history-load-next-batch)
        (setq items decknix--compose-history-items))
      (if (>= new-index (length items))
          (progn
            (message "End of %s history (%d prompts)"
                     (if decknix--compose-history-local-only
                         "session" "global")
                     (length items))
            (ding))
        (setq decknix--compose-history-index new-index)
        (erase-buffer)
        (insert (nth new-index items))
        (goto-char (point-max))))))

(defun decknix--compose-history-navigate-next ()
  "Core implementation: move to the next (newer) prompt in history."
  (cond
   ;; Already at current input
   ((= decknix--compose-history-index -1)
    (message "End of history") (ding))
   ;; Moving to current input (restore saved)
   ((= decknix--compose-history-index 0)
    (setq decknix--compose-history-index -1)
    (erase-buffer)
    (when decknix--compose-saved-input
      (insert decknix--compose-saved-input))
    (goto-char (point-max)))
   ;; Move forward (newer)
   (t
    (setq decknix--compose-history-index
          (1- decknix--compose-history-index))
    (erase-buffer)
    (insert (nth decknix--compose-history-index
                 decknix--compose-history-items))
    (goto-char (point-max)))))

(defun decknix-agent-compose-previous-input ()
  "Cycle to the previous prompt from the CURRENT session only.
Use M-P for cross-session history."
  (interactive)
  (when (not decknix--compose-history-local-only)
    ;; Switching from global → local: reset to rebuild
    (setq decknix--compose-history-local-only t
          decknix--compose-history-seen nil))
  (decknix--compose-history-navigate-previous))

(defun decknix-agent-compose-next-input ()
  "Cycle to the next (newer) prompt from the CURRENT session only.
Use M-N for cross-session history."
  (interactive)
  (decknix--compose-history-navigate-next))

(defun decknix-agent-compose-previous-input-global ()
  "Cycle to the previous prompt across ALL sessions.
Starts with the current session, then streams from saved sessions on-demand."
  (interactive)
  (when decknix--compose-history-local-only
    ;; Switching from local → global: reset to rebuild with file queue
    (setq decknix--compose-history-local-only nil
          decknix--compose-history-seen nil))
  (decknix--compose-history-navigate-previous))

(defun decknix-agent-compose-next-input-global ()
  "Cycle to the next (newer) prompt across ALL sessions."
  (interactive)
  (decknix--compose-history-navigate-next))

;; == Consult-based prompt search (M-r) ==

(defvar decknix--prompt-search-cache nil
  "Cached list of all user prompts for consult search (strings).")

(defvar decknix--prompt-search-cache-time 0
  "Time when prompt search cache was last updated.")

(defvar decknix--prompt-search-cache-ttl 300
  "Seconds before prompt search cache is stale (5 min).")

(defvar decknix--prompt-search-refresh-proc nil
  "Process handle for async prompt search cache refresh.")

(defun decknix--prompt-search-jq-cmd ()
  "Shell command to extract all user prompts from all sessions.
Outputs one JSON array per line (one per session file)."
  (let ((jqf (decknix--prompt-extract-ensure-jq-filter)))
    (concat
     "find " (shell-quote-argument decknix--agent-sessions-dir)
     " -maxdepth 1 -name '*.json' -print0 2>/dev/null"
     " | xargs -0 -P8 -I{}"
     " sh -c 'jq -c -f \"$1\" \"$2\" 2>/dev/null || true' _ "
     (shell-quote-argument jqf) " {}")))

;; `decknix--prompt-search-parse' lives in
;; agent-shell/agent/decknix-agent-parse.el — required at the
;; top of this heredoc.

(defun decknix--prompt-search-refresh-sync ()
  "Synchronously build the prompt search cache."
  (message "Loading all prompt history for search…")
  (let ((result (decknix--prompt-search-parse
                 (shell-command-to-string
                  (decknix--prompt-search-jq-cmd)))))
    (setq decknix--prompt-search-cache result
          decknix--prompt-search-cache-time (float-time))
    result))

(defun decknix--prompt-search-refresh-async ()
  "Asynchronously refresh the prompt search cache."
  (when (or (null decknix--prompt-search-refresh-proc)
            (not (process-live-p decknix--prompt-search-refresh-proc)))
    (let ((buf (generate-new-buffer " *auggie-prompt-search*")))
      (setq decknix--prompt-search-refresh-proc
            (start-process-shell-command
             "auggie-prompt-search" buf
             (decknix--prompt-search-jq-cmd)))
      (set-process-sentinel
       decknix--prompt-search-refresh-proc
       (eval
        `(lambda (proc _event)
           (when (eq (process-status proc) 'exit)
             (let ((pbuf (process-buffer proc)))
               (when (buffer-live-p pbuf)
                 (let ((result (decknix--prompt-search-parse
                                (with-current-buffer pbuf
                                  (buffer-string)))))
                   (when result
                     (setq decknix--prompt-search-cache result
                           decknix--prompt-search-cache-time
                           (float-time))))
                 (kill-buffer pbuf)))))
        t)))))

(defun decknix--prompt-search-get ()
  "Return all prompts for search, fetching if needed."
  (when (and (null decknix--prompt-search-cache)
             (= decknix--prompt-search-cache-time 0))
    (decknix--prompt-search-refresh-sync))
  (when (> (- (float-time) decknix--prompt-search-cache-time)
           decknix--prompt-search-cache-ttl)
    (decknix--prompt-search-refresh-async))
  ;; Also prepend current comint-input-ring entries
  (let ((seen (make-hash-table :test 'equal))
        (ring-items nil)
        (target (or decknix--compose-target-buffer
                    (when (derived-mode-p 'agent-shell-mode)
                      (current-buffer)))))
    (when (and target (buffer-live-p target))
      (with-current-buffer target
        (when (and (bound-and-true-p comint-input-ring)
                   (not (ring-empty-p comint-input-ring)))
          (dotimes (i (ring-length comint-input-ring))
            (let ((item (ring-ref comint-input-ring i)))
              (when (and (stringp item)
                         (not (string-empty-p (string-trim item)))
                         (not (gethash item seen)))
                (puthash item t seen)
                (push item ring-items)))))))
    ;; Combine: current ring + saved (deduped)
    (let ((result (nreverse ring-items)))
      (dolist (msg decknix--prompt-search-cache)
        (unless (gethash msg seen)
          (puthash msg t seen)
          (push msg result)))
      (nreverse result))))

;; `decknix--prompt-truncate-for-display' lives in
;; agent-shell/agent/decknix-agent-format.el alongside the
;; relative-time formatters — required at the top of this
;; heredoc.

(defun decknix-agent-compose-search-history ()
  "Search prompt history using consult with fuzzy matching.
Selected prompt replaces the compose buffer content.
Works in both compose buffers and agent-shell buffers."
  (interactive)
  (require 'consult)
  (let* ((all-prompts (decknix--prompt-search-get))
         ;; Build candidates: truncated display → full prompt
         (candidates
          (mapcar (lambda (p)
                    (cons (decknix--prompt-truncate-for-display p 120) p))
                  all-prompts))
         (selected
          (consult--read
           (mapcar #'car candidates)
           :prompt "Search prompts: "
           :sort nil
           :require-match t
           :category 'decknix-prompt
           :history 'decknix--prompt-search-minibuffer-history))
         (full-prompt (cdr (assoc selected candidates))))
    (when full-prompt
      ;; Insert into compose buffer or show in message
      (if (bound-and-true-p decknix-agent-compose-mode)
          (progn
            (erase-buffer)
            (insert full-prompt)
            (goto-char (point-max))
            ;; Reset M-p/M-n state since we jumped
            (setq decknix--compose-history-index -1
                  decknix--compose-saved-input nil
                  decknix--compose-history-items nil
                  decknix--compose-history-seen nil
                  decknix--compose-history-file-queue nil
                  decknix--compose-history-exhausted nil
                  decknix--compose-history-local-only t))
        ;; In agent-shell buffer: open compose with this prompt
        (let ((target (current-buffer)))
          (decknix--compose-get-or-create target)
          (erase-buffer)
          (insert full-prompt)
          (goto-char (point-max)))))))

(defvar decknix--prompt-search-minibuffer-history nil
  "Minibuffer history for prompt search.")

(defcustom decknix-agent-compose-sticky nil
  "When non-nil, the compose editor stays open after submit/cancel.
Toggle with \\[decknix-agent-compose-toggle-sticky] in the compose buffer."
  :type 'boolean
  :group 'decknix)

(defvar-local decknix--compose-sticky nil
  "Buffer-local sticky state for this compose buffer.")

(defvar decknix-agent-compose-interrupt-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "k") #'decknix-agent-compose-interrupt-agent)
    (define-key map (kbd "C-c") #'decknix-agent-compose-interrupt-and-submit)
    map)
  "Sub-keymap under C-c k in compose mode.
\\`k' interrupts the agent, \\`C-c' interrupts and submits.")

;; -- Compose → parent buffer forwarding commands --
;; These let you invoke parent agent-shell commands without
;; closing the compose window first.

(defun decknix-compose--forward-to-parent (cmd)
  "Run CMD interactively in the compose target (parent) buffer."
  (when-let ((target (and (boundp 'decknix--compose-target-buffer)
                          decknix--compose-target-buffer))
             ((buffer-live-p target)))
    (with-current-buffer target
      (call-interactively cmd))))

(defun decknix-compose-jump ()
  "Jump to next pending session (forwarded to parent)."
  (interactive)
  (if (fboundp 'agent-shell-attention-jump)
      (call-interactively 'agent-shell-attention-jump)
    (message "agent-shell-attention not loaded")))

(defun decknix-compose-workspace-toggle ()
  "Toggle Agents workspace from a compose buffer.
Hide the compose side-window first so the tab switch happens
cleanly (side-windows persist across tab switches and corrupt the
layout otherwise).  The compose buffer itself is buried, not killed,
so any in-flight prompt text is preserved and restored the next time
the user opens compose (`C-c e') against the same target.  Focus
returns to the agent buffer before the toggle."
  (interactive)
  (if (fboundp 'agent-shell-workspace-toggle)
      (let ((target decknix--compose-target-buffer)
            (compose-win (selected-window)))
        ;; Hide the compose side-window but keep the buffer alive
        ;; so the user's partially-typed prompt survives the toggle.
        (quit-restore-window compose-win 'bury)
        ;; Move focus to the target agent buffer if it's visible
        (when (and target (buffer-live-p target))
          (let ((target-win (get-buffer-window target)))
            (when (and target-win (window-live-p target-win))
              (select-window target-win))))
        ;; Now toggle tabs cleanly
        (call-interactively 'agent-shell-workspace-toggle))
    (message "agent-shell-workspace not loaded")))

(defun decknix-compose-session-picker ()
  "Open session picker (forwarded to parent)."
  (interactive)
  (decknix-compose--forward-to-parent 'decknix-session-picker))

(defun decknix-compose-context-panel ()
  "Toggle context or open panel (forwarded to parent).
Without prefix, toggle inline header. With prefix, open side panel."
  (interactive)
  (when (fboundp 'decknix-context-toggle-or-panel)
    (decknix-compose--forward-to-parent
     'decknix-context-toggle-or-panel)))

(defun decknix-compose-tags ()
  "Show session tags (forwarded to parent)."
  (interactive)
  (when (fboundp 'decknix-session-tags-show)
    (decknix-compose--forward-to-parent 'decknix-session-tags-show)))

(defvar decknix-agent-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'decknix-agent-compose-submit)
    (define-key map (kbd "C-c C-k") #'decknix-agent-compose-cancel)
    (define-key map (kbd "C-c C-q") #'decknix-agent-compose-close)
    (define-key map (kbd "C-c C-s") #'decknix-agent-compose-toggle-sticky)
    (define-key map (kbd "C-c k") decknix-agent-compose-interrupt-map)
    (define-key map (kbd "M-p") #'decknix-agent-compose-previous-input)
    (define-key map (kbd "M-n") #'decknix-agent-compose-next-input)
    (define-key map (kbd "M-P") #'decknix-agent-compose-previous-input-global)
    (define-key map (kbd "M-N") #'decknix-agent-compose-next-input-global)
    (define-key map (kbd "M-r") #'decknix-agent-compose-search-history)
    ;; Forward parent buffer commands
    (define-key map (kbd "C-c j") #'decknix-compose-jump)
    (define-key map (kbd "C-c w") #'decknix-compose-workspace-toggle)
    (define-key map (kbd "C-c s") #'decknix-compose-session-picker)
    (define-key map (kbd "C-c i") #'decknix-compose-context-panel)
    (define-key map (kbd "C-c T") #'decknix-compose-tags)
    map)
  "Keymap for `decknix-agent-compose-mode'.")

(define-minor-mode decknix-agent-compose-mode
  "Minor mode for composing agent-shell prompts.
\\<decknix-agent-compose-mode-map>
\\[decknix-agent-compose-submit] submit, \
\\[decknix-agent-compose-cancel] cancel/clear, \
\\[decknix-agent-compose-close] close, \
\\[decknix-agent-compose-toggle-sticky] toggle sticky.
C-c k k interrupt agent, C-c k C-c interrupt & submit."
  :lighter (:eval (if decknix--compose-sticky " Compose[sticky]" " Compose"))
  :keymap decknix-agent-compose-mode-map)

;; -- Compose buffer: slash command + file completion --
;; Delegates to agent-shell's completion machinery via the
;; compose buffer's target agent-shell buffer.

(defun decknix--compose-command-completion-at-point ()
  "Complete slash commands in the compose buffer.
Looks up available commands from the target agent-shell buffer."
  (when-let* ((target (and (boundp 'decknix--compose-target-buffer)
                           decknix--compose-target-buffer))
              ((buffer-live-p target))
              (bounds (save-excursion
                        (let* ((end (progn (skip-chars-forward "[:alnum:]_-") (point)))
                               (start (progn (skip-chars-backward "[:alnum:]_-") (point))))
                          (when (eq (char-before start) ?/)
                            (list start end)))))
              (commands (with-current-buffer target
                          (when (boundp 'agent-shell--state)
                            (map-elt agent-shell--state :available-commands))))
              (descriptions (mapcar (lambda (c)
                                      (cons (map-elt c 'name)
                                            (map-elt c 'description)))
                                    commands)))
    (list (nth 0 bounds) (nth 1 bounds)
          (mapcar #'car descriptions)
          :exclusive t
          :annotation-function
          (lambda (name)
            (when-let* ((desc (map-elt descriptions name)))
              (concat "  " desc)))
          :company-kind (lambda (_) 'function)
          :exit-function (lambda (_string _status) (insert " ")))))

(defun decknix--compose-file-completion-at-point ()
  "Complete project files after @ in the compose buffer.
Uses the target agent-shell buffer's project context."
  (when-let* ((target (and (boundp 'decknix--compose-target-buffer)
                           decknix--compose-target-buffer))
              ((buffer-live-p target))
              (bounds (save-excursion
                        (let* ((end (progn (skip-chars-forward "[:alnum:]/_.-") (point)))
                               (start (progn (skip-chars-backward "[:alnum:]/_.-") (point))))
                          (when (eq (char-before start) ?@)
                            (list start end)))))
              (files (with-current-buffer target
                       (when (fboundp 'agent-shell--project-files)
                         (agent-shell--project-files)))))
    (list (nth 0 bounds) (nth 1 bounds)
          files
          :exclusive 'no
          :company-kind (lambda (f) (if (string-suffix-p "/" f) 'folder 'file))
          :exit-function (lambda (_string _status) (insert " ")))))

(defun decknix--compose-trigger-completion ()
  "Trigger completion in compose buffer when / or @ is typed.
Only triggers at line start or after whitespace."
  (when (and (memq (char-before) '(?/ ?@))
             (or (= (point) (1+ (line-beginning-position)))
                 (memq (char-before (1- (point))) '(?\s ?\t ?\n))))
    (cond
     ((and (eq (char-before) ?/)
           (decknix--compose-command-completion-at-point))
      (completion-at-point))
     ((eq (char-before) ?@)
      (completion-at-point)))))

(defun decknix--compose-setup-completion ()
  "Set up slash command and file completion in the compose buffer."
  (add-hook 'completion-at-point-functions
            #'decknix--compose-file-completion-at-point nil t)
  (add-hook 'completion-at-point-functions
            #'decknix--compose-command-completion-at-point nil t)
  (add-hook 'post-self-insert-hook
            #'decknix--compose-trigger-completion nil t))

(defun decknix--compose-finish ()
  "Finish a compose action: clear if sticky, close if transient.
Resets prompt history navigation state."
  ;; Reset all history navigation state (rebuilt on next M-p)
  (setq decknix--compose-history-index -1
        decknix--compose-saved-input nil
        decknix--compose-history-items nil
        decknix--compose-history-seen nil
        decknix--compose-history-file-queue nil
        decknix--compose-history-exhausted nil
        decknix--compose-history-local-only t)
  (if decknix--compose-sticky
      (progn
        (erase-buffer)
        (set-buffer-modified-p nil))
    (let ((win (selected-window)))
      (quit-restore-window win 'kill))))

;; -- Prompt queue: auto-submit when agent becomes idle --
(defvar-local decknix--compose-queued-prompt nil
  "Pending prompt string queued for submission when the agent is idle.
Buffer-local on agent-shell buffers.")

(defvar-local decknix--compose-queue-timer nil
  "Timer polling `shell-maker--busy' to submit a queued prompt.
Buffer-local on agent-shell buffers.")

(defun decknix--compose-queue-poll ()
  "Check if the agent is idle and submit the queued prompt.
Called by a repeating timer on the agent-shell buffer."
  (let ((buf (current-buffer)))
    (if (not (buffer-live-p buf))
        ;; Buffer killed — cancel timer
        (when decknix--compose-queue-timer
          (cancel-timer decknix--compose-queue-timer)
          (setq decknix--compose-queue-timer nil))
      (when (and decknix--compose-queued-prompt
                 (not (bound-and-true-p shell-maker--busy))
                 (get-buffer-process buf)
                 (process-live-p (get-buffer-process buf)))
        ;; Agent is idle — submit the queued prompt
        (let ((input decknix--compose-queued-prompt))
          (setq decknix--compose-queued-prompt nil)
          (when decknix--compose-queue-timer
            (cancel-timer decknix--compose-queue-timer)
            (setq decknix--compose-queue-timer nil))
          (goto-char (point-max))
          (shell-maker-submit :input input)
          (message "Queued prompt submitted"))))))

(defun decknix--compose-enqueue-prompt (target input)
  "Queue INPUT for submission on TARGET buffer when the agent is idle."
  (when (buffer-live-p target)
    (with-current-buffer target
      (setq decknix--compose-queued-prompt input)
      ;; Start a polling timer (every 1s) if not already running
      (unless (and decknix--compose-queue-timer
                  (memq decknix--compose-queue-timer timer-list))
        (setq decknix--compose-queue-timer
              (run-at-time
               1.0 1.0
               (eval `(lambda ()
                        (when (buffer-live-p ,target)
                          (with-current-buffer ,target
                            (decknix--compose-queue-poll))))
                     t)))))))

(defun decknix-agent-compose-submit ()
  "Submit the compose buffer content to the agent-shell.
If the agent is busy, offers three options:
  - Interrupt and submit immediately
  - Queue the prompt (auto-submitted when agent becomes idle)
  - Cancel
Use C-c k k to pre-emptively interrupt, then C-c C-c to submit cleanly."
  (interactive)
  (let ((input (string-trim (buffer-string)))
        (target decknix--compose-target-buffer))
    (if (string-empty-p input)
        (user-error "Empty prompt — nothing to submit")
      ;; Check if the agent is busy
      (when (and (buffer-live-p target)
                 (with-current-buffer target
                   (bound-and-true-p shell-maker--busy)))
        (let ((choice (read-char-choice
                       "Agent is busy: [i]nterrupt & submit  [q]ueue for later  [c]ancel "
                       '(?i ?q ?c))))
          (pcase choice
            (?c (user-error "Submit cancelled — agent is still processing"))
            (?q
             ;; Queue the prompt and close/clear compose
             (decknix--compose-enqueue-prompt target input)
             (decknix--compose-finish)
             (message "Prompt queued — will submit when agent is ready")
             (cl-return-from decknix-agent-compose-submit))
            (?i
             ;; Interrupt and continue to submit below
             (with-current-buffer target
               (when (fboundp 'agent-shell-interrupt)
                 (let ((agent-shell-confirm-interrupt nil))
                   (agent-shell-interrupt))))
             (sit-for 0.3)))))
      ;; Verify the agent process is alive before submitting
      (unless (and (buffer-live-p target)
                   (get-buffer-process target)
                   (process-live-p (get-buffer-process target)))
        (user-error "Agent process not running — wait for it to start or restart with C-c A a"))
      ;; Clear or close the compose buffer
      (decknix--compose-finish)
      ;; Submit to the agent-shell buffer
      (with-current-buffer target
        (goto-char (point-max))
        (shell-maker-submit :input input)))))

(defun decknix-agent-compose-interrupt-agent ()
  "Pre-emptively interrupt the agent without submitting.
After interrupting, you can compose your message and submit with
\\[decknix-agent-compose-submit] without the busy prompt."
  (interactive)
  (let ((target decknix--compose-target-buffer))
    (if (and (buffer-live-p target)
             (with-current-buffer target
               (bound-and-true-p shell-maker--busy)))
        (progn
          (with-current-buffer target
            (when (fboundp 'agent-shell-interrupt)
              (let ((agent-shell-confirm-interrupt nil))
                (agent-shell-interrupt))))
          (message "Agent interrupted. Compose your message and C-c C-c to submit."))
      (message "Agent is not busy."))))

(defun decknix-agent-compose-interrupt-and-submit ()
  "Interrupt any in-progress agent response, then submit the compose buffer.
Use this when the agent is processing and you want to interject immediately
rather than waiting for the current response to complete.
The compose buffer is closed/cleared AFTER the submit, not before."
  (interactive)
  (let ((input (string-trim (buffer-string)))
        (target decknix--compose-target-buffer)
        (compose-buf (current-buffer)))
    (if (string-empty-p input)
        (user-error "Empty prompt — nothing to submit")
      ;; Interrupt the agent first
      (when (buffer-live-p target)
        (with-current-buffer target
          (when (fboundp 'agent-shell-interrupt)
            (let ((agent-shell-confirm-interrupt nil))
              (agent-shell-interrupt)))))
      ;; Submit after a brief delay to let the interrupt settle,
      ;; then close/clear the compose buffer.
      (let ((tgt target)
            (inp input)
            (cbuf compose-buf))
        (run-at-time
         0.3 nil
         (eval
          `(lambda ()
             (when (and (buffer-live-p ,tgt)
                        (get-buffer-process ,tgt)
                        (process-live-p (get-buffer-process ,tgt)))
               (with-current-buffer ,tgt
                 (goto-char (point-max))
                 (shell-maker-submit :input ,inp)))
             ;; Now finish (clear/close) the compose buffer
             (when (buffer-live-p ,cbuf)
               (with-current-buffer ,cbuf
                 (decknix--compose-finish))))
          t))))))

(defun decknix-agent-compose-cancel ()
  "Cancel/clear the compose buffer without submitting.
Sticky mode: clears the buffer. Transient mode: closes the buffer."
  (interactive)
  (decknix--compose-finish)
  (message (if decknix--compose-sticky "Compose cleared." "Compose cancelled.")))

(defun decknix-agent-compose-close ()
  "Close the compose buffer unconditionally (regardless of sticky mode)."
  (interactive)
  (let ((win (selected-window)))
    (quit-restore-window win 'kill))
  (message "Compose closed."))

(defun decknix-agent-compose-toggle-sticky ()
  "Toggle sticky mode for the compose buffer.
Sticky: editor stays open after submit/cancel (content is cleared).
Transient: editor closes after submit/cancel."
  (interactive)
  (setq decknix--compose-sticky (not decknix--compose-sticky))
  (decknix--compose-update-header-line)
  (force-mode-line-update)
  (message "Compose: %s" (if decknix--compose-sticky "sticky (stays open)" "transient (closes on action)")))

(defun decknix--compose-update-header-line ()
  "Update the header-line to reflect current sticky state.
Compact header — shows C-c as the action prefix and hints that
which-key will reveal bindings.  Full sequences shown via which-key
after pressing C-c."
  (setq-local header-line-format
              (list
               (propertize
                (if decknix--compose-sticky " ● Compose [sticky]" " ○ Compose")
                'font-lock-face (if decknix--compose-sticky
                                    'font-lock-constant-face
                                  'font-lock-comment-face))
               (propertize "  " 'font-lock-face 'font-lock-comment-face)
               (propertize "C-c" 'font-lock-face 'font-lock-keyword-face)
               (propertize " actions  " 'font-lock-face 'font-lock-comment-face)
               (propertize "M-p" 'font-lock-face 'font-lock-keyword-face)
               (propertize "/" 'font-lock-face 'font-lock-comment-face)
               (propertize "M-n" 'font-lock-face 'font-lock-keyword-face)
               (propertize " cycle  " 'font-lock-face 'font-lock-comment-face)
               (propertize "M-r" 'font-lock-face 'font-lock-keyword-face)
               (propertize " search" 'font-lock-face 'font-lock-comment-face))))

(defun decknix--compose-find-target ()
  "Find the agent-shell buffer to target for compose."
  (cond
   ;; Already in an agent-shell buffer
   ((derived-mode-p 'agent-shell-mode)
    (current-buffer))
   ;; In a compose buffer — return its target
   (decknix--compose-target-buffer
    decknix--compose-target-buffer)
   ;; Find the most recent agent-shell buffer
   ((and (fboundp 'agent-shell-buffers)
         (agent-shell-buffers))
    (car (agent-shell-buffers)))
   (t (user-error
       "No agent-shell buffer found. Start one with C-c A a"))))

(defun decknix--compose-display-action ()
  "Return a display-buffer action for the compose window.
Uses a bottom side-window so it never steals the workspace sidebar
or other side-windows."
  '((display-buffer-in-side-window)
    (side . bottom)
    (slot . 0)
    (window-height . 10)
    (preserve-size . (nil . t))))

(defun decknix--compose-get-or-create (target)
  "Get the existing compose buffer for TARGET, or create a new one.
If a compose buffer already exists and is visible, just select it."
  (let* ((compose-name (format "*Compose: %s*" (buffer-name target)))
         (existing (get-buffer compose-name)))
    (if (and existing (buffer-live-p existing))
        ;; Re-use existing compose buffer
        (progn
          (unless (get-buffer-window existing)
            (display-buffer existing
                           (decknix--compose-display-action)))
          (select-window (get-buffer-window existing))
          existing)
      ;; Create new compose buffer
      (let ((compose-buf (generate-new-buffer compose-name)))
        (display-buffer compose-buf
                        (decknix--compose-display-action))
        (select-window (get-buffer-window compose-buf))
        (with-current-buffer compose-buf
          (text-mode)
          (decknix-agent-compose-mode 1)
          ;; Enable yasnippet with agent-shell-mode snippets.
          ;; The buffer is text-mode, so yas only sees text-mode
          ;; snippets by default.  yas-activate-extra-mode adds
          ;; agent-shell-mode's snippet table as well.
          (when (fboundp 'yas-minor-mode)
            (yas-minor-mode 1)
            (yas-activate-extra-mode 'agent-shell-mode))
          (setq-local decknix--compose-target-buffer target)
          (setq-local decknix--compose-sticky decknix-agent-compose-sticky)
          ;; Enable slash command (/) and file (@) completion
          (decknix--compose-setup-completion)
          (decknix--compose-update-header-line)
          (set-buffer-modified-p nil))
        compose-buf))))

(defun decknix-agent-compose ()
  "Open or focus the compose buffer for writing a multi-line agent prompt.
The buffer opens at the bottom of the frame. Type your prompt
freely (RET for newlines), then:
  C-c C-c    submit (prompts if agent is busy)
  C-c k k    interrupt agent (pre-emptive)
  C-c k C-c  interrupt agent & submit immediately
  C-c C-k    cancel/clear
  C-c C-s    toggle sticky (stays open) / transient (closes)"
  (interactive)
  (let ((target (decknix--compose-find-target)))
    (decknix--compose-get-or-create target)))

(defun decknix-agent-compose-interrupt ()
  "Interrupt the agent, then open the compose buffer.
Use this when the agent is mid-response and you want to interject."
  (interactive)
  (let ((target (decknix--compose-find-target)))
    ;; Interrupt if busy
    (when (and (buffer-live-p target)
               (with-current-buffer target
                 (bound-and-true-p shell-maker--busy)))
      (with-current-buffer target
        (when (fboundp 'agent-shell-interrupt)
          (let ((agent-shell-confirm-interrupt nil))
            (agent-shell-interrupt))))
      (sit-for 0.3))
    ;; Open/focus compose
    (decknix--compose-get-or-create target)))      ; Interrupt + compose

;; == Custom commands: discovery, picker, authoring ==

;; -- Custom command discovery (PR B.46) --
;; `decknix--agent-command-{dirs,files,description}' moved into
;; agent-shell/agent/decknix-agent-command-discover.el.  Two call
;; sites in this file (~lines 362 / 3533 / 3568) reach the
;; symbols through the heredoc's `(require ...)' chain.
(declare-function decknix--agent-command-files
                  "decknix-agent-command-discover")
(declare-function decknix--agent-command-description
                  "decknix-agent-command-discover" (file))
(defvar decknix--agent-command-dirs)

(defun decknix-agent-command-run ()
  "Pick a custom command and insert it as a slash command in the prompt.
Shows commands from ~/.augment/commands/ and project .augment/commands/."
  (interactive)
  (let* ((cmds (decknix--agent-command-files))
         (annotator (lambda (cand)
                      (when-let* ((file (cdr (assoc cand cmds))))
                        (format "  %s" (decknix--agent-command-description file)))))
         (selection (completing-read
                     "Command: " (mapcar #'car cmds) nil t nil nil nil
                     `(annotation-function . ,annotator)))
         (name (progn (string-match "^/\\([^ ]+\\)" selection)
                      (match-string 1 selection))))
    ;; Insert the slash command at the agent-shell prompt
    (if (derived-mode-p 'agent-shell-mode)
        (progn
          (goto-char (point-max))
          (insert (format "/%s " name)))
      (message "Copied: /%s (use in an agent-shell buffer)" name))))

(defun decknix-agent-command-new ()
  "Create a new auggie custom command.
Prompts for a name and opens a template in ~/.augment/commands/."
  (interactive)
  (let* ((name (read-string "Command name (no extension): "))
         (name (string-trim name))
         (file (expand-file-name
                (format "~/.augment/commands/%s.md" name))))
    (when (string-empty-p name)
      (user-error "Name cannot be empty"))
    (when (file-exists-p file)
      (user-error "Command %s already exists — use edit instead" name))
    (find-file file)
    (insert (format "---\ndescription: %s\nargument-hint: [args]\n---\n\n" name))
    (message "New command: %s — write instructions, then save." name)))

(defun decknix-agent-command-edit ()
  "Edit an existing auggie custom command."
  (interactive)
  (let* ((cmds (decknix--agent-command-files))
         (selection (completing-read "Edit command: "
                                    (mapcar #'car cmds) nil t))
         (file (cdr (assoc selection cmds))))
    (find-file file)))

;; == Quick actions: PR review, batch processing ==
;; DWIM workflows that create a session with pre-configured name,
;; tags, workspace, and auto-send a command.
;; Metadata enrichment (author, Jira key, etc.) is deferred to the
;; review command itself, keeping initiation instant.
;;
;; `decknix--agent-parse-pr-url' lives in
;; agent-shell/agent/decknix-agent-url-parse.el alongside its
;; sibling `decknix--agent-pr-parse-url' (positional-list
;; variant) — required at the top of this heredoc.

;; -- Clipboard URL DWIM (PR B.49) --
;; Moved into agent-shell/agent/decknix-agent-clipboard.el.
;; Sole call site (~line 3649) reaches the symbol through the
;; heredoc's `(require ...)' chain.
(declare-function decknix--agent-clipboard-url "decknix-agent-clipboard")

(defun decknix--agent-quickaction-start (name tags workspace command)
  "Start a quick-action session with NAME, TAGS, WORKSPACE, and auto-send COMMAND.
Creates a new agent session, applies metadata, then subscribes to the
`prompt-ready' event to send COMMAND as soon as the ACP session is
fully established.  Returns immediately.
When invoked from a dedicated or side window (e.g., the sidebar), the
new session is displayed in the frame's main window instead of
replacing the caller, preserving the sidebar."
  (let* ((workspace (expand-file-name workspace))
         (cur (selected-window))
         (sidebar-buf (or (bound-and-true-p
                           agent-shell-workspace-sidebar-buffer-name)
                          "*agent-shell-sidebar*"))
         (cur-is-sidebar (or (window-parameter cur 'window-side)
                             (window-dedicated-p cur)
                             (string= (buffer-name (window-buffer cur))
                                      sidebar-buf)))
         (target-win (if cur-is-sidebar
                         (or (window-main-window (selected-frame)) cur)
                       cur))
         (before-buffers (buffer-list))
         (augmented-cmd
          (append agent-shell-auggie-acp-command
                  (list "--workspace-root" workspace)))
         (config
          (let ((base (agent-shell-auggie-make-agent-config)))
            (setf (alist-get :client-maker base)
                  (eval `(lambda (buffer)
                           (agent-shell--make-acp-client
                            :command ,(car augmented-cmd)
                            :command-params ',(cdr augmented-cmd)
                            :environment-variables
                            (cond ((map-elt agent-shell-auggie-authentication :none)
                                   agent-shell-auggie-environment)
                                  ((map-elt agent-shell-auggie-authentication :login)
                                   agent-shell-auggie-environment)
                                  (t
                                   (error "Invalid Auggie authentication")))
                            :context-buffer buffer)) t))
            base)))
    ;; Override display-action to target the selected window,
    ;; preventing splits when called from sidebar or after
    ;; minibuffer exit.
    (let ((default-directory workspace)
          (agent-shell-display-action
           (eval `(cons (lambda (buffer alist)
                          (let ((win ,target-win))
                            (if (window-live-p win)
                                (window--display-buffer
                                 buffer win 'reuse alist)
                              (display-buffer-same-window buffer alist))))
                        nil)
                 t)))
      (agent-shell-start :config config))
    (setq decknix--agent-session-cache-time 0)
    (decknix--agent-session-new-post-create
     before-buffers name tags workspace command)
    ;; Find the newly created shell buffer and subscribe to prompt-ready.
    ;; agent-shell-start creates the buffer synchronously (mode-hook fires
    ;; before it returns), so find-new-shell-buffer works immediately.
    (let ((shell-buf (decknix--agent-find-new-shell-buffer before-buffers)))
      (when shell-buf
        (agent-shell-subscribe-to
         :shell-buffer shell-buf
         :event 'prompt-ready
         :on-event
         (eval `(lambda (_event)
                  (when (buffer-live-p ,shell-buf)
                    (with-current-buffer ,shell-buf
                      (goto-char (point-max))
                      (shell-maker-submit :input ,command))
                    (message "Sent: %s"
                             (truncate-string-to-width ,command 60))))
               t))))))

(defun decknix-agent-review-pr (url)
  "Start a PR review session for URL.
Parses the GitHub PR URL, creates a new session with auto-generated
name and tags, then sends /review-service-pr.  Metadata enrichment
\(author, Jira key, title\) is handled by the review command itself.

Interactively, prompts for URL (defaulting to clipboard if it
looks like a PR URL) and workspace (defaulting to current project)."
  (interactive
   (let* ((default-url (decknix--agent-clipboard-url))
          (url (read-string
                (if default-url
                    (format "PR URL [%s]: " default-url)
                  "PR URL: ")
                nil nil default-url)))
     (list url)))
  ;; Parse and validate
  (let ((parsed (decknix--agent-parse-pr-url url)))
    (unless parsed
      (user-error "Not a valid GitHub PR URL: %s" url))
    (let* ((owner (alist-get 'owner parsed))
           (repo (alist-get 'repo parsed))
           (number (alist-get 'number parsed))
           ;; Auto-generate session name: pr-<repo>-<number>
           (name (format "pr-%s-%s" repo number))
           ;; Tags: review + repo + PR number for distinguishability
           (tags (list "review" repo (format "#%s" number)))
           ;; Workspace: smart detection from PR URL
           ;; Priority: saved workspace → workspace-roots → project root → cwd
           (default-ws (decknix--agent-pr-detect-workspace owner repo))
           (workspace (read-directory-name
                       (format "Workspace for %s/%s#%s: "
                               owner repo number)
                       default-ws nil t))
           ;; Confirm name
           (name (read-string (format "Session name [%s]: " name)
                              nil nil name))
           (command (format "/review-service-pr %s" url)))
      (decknix--agent-quickaction-start name tags workspace command)
      (message "Starting review: %s/%s#%s" owner repo number))))

;; == Batch processing: launch multiple sessions from a compose editor ==
;; Syntax:
;;   --- <group-name> [: <workspace>]
;;   <url-or-item>
;;   <url-or-item>
;;
;;   --- <another-group> [: <workspace>]
;;   <url-or-item>
;;
;;   <ungrouped-url>          ← gets its own session
;;
;; Lines within a group share a single session.
;; Ungrouped lines each get their own session.
;; Default workspace is the current project root.

(defvar decknix--batch-default-workspace nil
  "Default workspace for the current batch editor.")

(defun decknix--batch-parse-buffer ()
  "Parse the batch editor buffer into a list of session specs.
Each spec is an alist with keys: name, workspace, items, grouped."
  (let ((specs nil)
        (current-items nil)
        (current-ws decknix--batch-default-workspace)
        (current-name nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (string-trim
                     (buffer-substring-no-properties
                      (line-beginning-position)
                      (line-end-position)))))
          (cond
           ;; Divider: --- <name> [: <workspace>]
           ((string-match "^---\\s-+\\(.+\\)" line)
            ;; Flush previous group if any
            (when (and current-name current-items)
              (push (list (cons 'name current-name)
                          (cons 'workspace current-ws)
                          (cons 'items (nreverse current-items))
                          (cons 'grouped t))
                    specs))
            ;; Parse new group header
            (let ((header (match-string 1 line)))
              (if (string-match "^\\(.+?\\)\\s-*:\\s-*\\(\\S-+.*\\)" header)
                  (progn
                    (setq current-name (string-trim (match-string 1 header)))
                    (setq current-ws (expand-file-name
                                      (string-trim (match-string 2 header)))))
                (setq current-name (string-trim header))
                (setq current-ws decknix--batch-default-workspace)))
            (setq current-items nil))
           ;; Empty line or comment — skip
           ((or (string-empty-p line)
                (string-prefix-p "#" line))
            nil)
           ;; Content line
           (t
            (if current-name
                ;; Inside a group
                (push line current-items)
              ;; Ungrouped — each line is its own session
              (let* ((parsed (decknix--agent-parse-pr-url line))
                     (auto-name (if parsed
                                    (format "pr-%s-%s"
                                            (alist-get 'repo parsed)
                                            (alist-get 'number parsed))
                                  (format "review-%s"
                                          (substring
                                           (secure-hash 'sha256 line)
                                           0 8))))
                     ;; Auto-detect workspace from PR URL
                     (ws (if parsed
                             (or (decknix--agent-pr-detect-workspace
                                  (alist-get 'owner parsed)
                                  (alist-get 'repo parsed))
                                 decknix--batch-default-workspace)
                           decknix--batch-default-workspace)))
                (push (list (cons 'name auto-name)
                            (cons 'workspace ws)
                            (cons 'items (list line))
                            (cons 'grouped nil))
                      specs))))))
        (forward-line 1)))
    ;; Flush final group
    (when (and current-name current-items)
      (push (list (cons 'name current-name)
                  (cons 'workspace current-ws)
                  (cons 'items (nreverse current-items))
                  (cons 'grouped t))
            specs))
    (nreverse specs)))

(defvar decknix--batch-launch-results nil
  "List of (NAME STATUS BUFFER) for the most recent batch launch.")

(defun decknix--batch-launch (specs)
  "Launch sessions for each spec in SPECS.
Each spec is an alist with name, workspace, items, grouped.
Grouped specs send all items as a single message.
Ungrouped specs send each item via /review-service-pr."
  (setq decknix--batch-launch-results nil)
  (dolist (spec specs)
    (let* ((name (alist-get 'name spec))
           (items (alist-get 'items spec))
           (grouped (alist-get 'grouped spec))
           ;; Build the command to send
           (command (if grouped
                        ;; Grouped: send all items as one message
                        (mapconcat
                         (lambda (item)
                           (format "/review-service-pr %s" item))
                         items "\n")
                      ;; Ungrouped: single item
                      (format "/review-service-pr %s" (car items))))
           ;; Tags: review + repo names + PR numbers from parsed URLs
           (tags (let ((tag-list (list "review")))
                   (dolist (item items)
                     (let ((parsed (decknix--agent-parse-pr-url item)))
                       (when parsed
                         (cl-pushnew (alist-get 'repo parsed)
                                     tag-list :test #'string=)
                         (cl-pushnew (format "#%s" (alist-get 'number parsed))
                                     tag-list :test #'string=))))
                   tag-list))
           ;; Workspace: for grouped items without explicit workspace,
           ;; auto-detect from the first parseable PR URL
           (workspace
            (let ((ws (alist-get 'workspace spec)))
              (if (and grouped
                       (string= ws decknix--batch-default-workspace))
                  ;; Try auto-detecting from the first PR URL
                  (or (cl-some
                       (lambda (item)
                         (let ((parsed (decknix--agent-parse-pr-url item)))
                           (when parsed
                             (decknix--agent-pr-detect-workspace
                              (alist-get 'owner parsed)
                              (alist-get 'repo parsed)))))
                       items)
                      ws)
                ws))))
      (condition-case err
          (progn
            (decknix--agent-quickaction-start name tags workspace command)
            (push (list name "launched" nil) decknix--batch-launch-results))
        (error
         (push (list name "failed" (error-message-string err))
               decknix--batch-launch-results)))))
  (setq decknix--batch-launch-results
        (nreverse decknix--batch-launch-results))
  ;; Show summary
  (decknix--batch-show-summary))

(defun decknix--batch-show-summary ()
  "Display a summary buffer of the batch launch results."
  (let ((buf (get-buffer-create "*Batch Launch*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Batch Launch Summary\n"
                            'font-lock-face '(:weight bold :height 1.2)))
        (insert (propertize (make-string 40 ?═)
                            'font-lock-face 'font-lock-comment-face)
                "\n\n")
        (dolist (result decknix--batch-launch-results)
          (let ((name (nth 0 result))
                (status (nth 1 result))
                (err (nth 2 result)))
            (insert (propertize
                     (if (string= status "launched") "✓ " "✗ ")
                     'font-lock-face
                     (if (string= status "launched")
                         'success 'error))
                    (propertize name 'font-lock-face '(:weight bold))
                    (format "  — %s" status)
                    (if err (format " (%s)" err) "")
                    "\n")))
        (insert "\n"
                (propertize (format "%d sessions launched"
                                   (length decknix--batch-launch-results))
                            'font-lock-face 'font-lock-comment-face)
                "\n\n"
                (propertize "Press q to close.\n"
                            'font-lock-face 'font-lock-comment-face))
        (special-mode)
        (goto-char (point-min))))
    (display-buffer buf
                    '((display-buffer-at-bottom)
                      (window-height . fit-window-to-buffer)))))

;; -- Batch compose minor mode for syntax highlighting --

(defvar decknix-batch-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") 'decknix--batch-submit)
    (define-key map (kbd "C-c C-k") 'decknix--batch-cancel)
    map)
  "Keymap for `decknix-batch-compose-mode'.")

(defun decknix--batch-submit ()
  "Parse and launch all sessions from the batch editor."
  (interactive)
  (let ((specs (decknix--batch-parse-buffer)))
    (if (null specs)
        (user-error "No items to process — add URLs or groups")
      (when (y-or-n-p (format "Launch %d session(s)? "
                              (length specs)))
        (let ((buf (current-buffer)))
          (decknix--batch-launch specs)
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(defun decknix--batch-cancel ()
  "Cancel the batch editor."
  (interactive)
  (when (y-or-n-p "Cancel batch? ")
    (kill-buffer (current-buffer))))

(defvar decknix--batch-font-lock-keywords
  (list
   ;; --- divider lines (group headers)
   (list "^---\\s-+\\(.+?\\)\\(\\s-*:\\s-*\\(\\S-+.*\\)\\)?$"
         '(0 'font-lock-keyword-face t)
         '(1 'font-lock-function-name-face t)
         '(3 'font-lock-string-face t t))
   ;; GitHub PR URLs
   (list "https?://github\\.com/[^ \t\n]+"
         '(0 'link t))
   ;; Comments
   (list "^#.*$"
         '(0 'font-lock-comment-face t)))
  "Font-lock keywords for batch compose mode.")

(define-minor-mode decknix-batch-compose-mode
  "Minor mode for the batch session editor.
Provides syntax highlighting for --- dividers, URLs, and comments.
\\<decknix-batch-compose-mode-map>
\\[decknix--batch-submit]  Submit — parse and launch all sessions.
\\[decknix--batch-cancel]  Cancel — close without launching."
  :lighter " Batch"
  :keymap decknix-batch-compose-mode-map
  (if decknix-batch-compose-mode
      (progn
        (font-lock-add-keywords nil decknix--batch-font-lock-keywords)
        (setq-local header-line-format
                    (list
                     (propertize
                      " Batch: C-c C-c submit | C-c C-k cancel"
                      'face 'header-line)))
        ;; Enable yasnippet with batch-compose-mode snippets
        ;; (--- groups, PR URLs, workspace templates)
        (when (fboundp 'yas-minor-mode)
          (yas-minor-mode 1)
          (yas-activate-extra-mode 'decknix-batch-compose-mode))
        (font-lock-flush))
    (font-lock-remove-keywords nil decknix--batch-font-lock-keywords)
    (setq-local header-line-format nil)
    (font-lock-flush)))

(defun decknix-agent-batch-process ()
  "Open a batch compose editor for launching multiple sessions.
Syntax:
  --- <group-name> [: <workspace>]
  <url>
  <url>

  --- <another-group> [: ~/other/path]
  <url>

  <ungrouped-url>

Lines within a --- group share a single session.
Ungrouped lines each get their own session.
Comments start with #."
  (interactive)
  (let* ((default-ws (decknix--agent-detect-workspace))
         (buf (generate-new-buffer "*Batch Process*")))
    (display-buffer buf
                    '((display-buffer-at-bottom)
                      (window-height . 15)
                      (dedicated . t)))
    (select-window (get-buffer-window buf))
    (with-current-buffer buf
      (text-mode)
      (setq-local decknix--batch-default-workspace default-ws)
      (decknix-batch-compose-mode 1)
      ;; Insert template
      (insert (format "# Batch session launcher — workspace: %s\n"
                      default-ws)
              "# Syntax: --- <name> [: <workspace>]\n"
              "#         <url-per-line>\n"
              "# Ungrouped URLs get individual sessions.\n"
              "# C-c C-c to launch, C-c C-k to cancel.\n\n")
      (set-buffer-modified-p nil))))

;; == Inline review buffer (decknix-agent-review-mode) ==
;; Capture an agent-shell exchange into a dedicated markdown buffer
;; where you can annotate with Option-1 preamble style
;; (> ✅ approved, > ❌ reject, > 🔀 option B, > 💬 comment).
;; Annotations are routed back to the source session (or to Jira /
;; a PR-comment / a file) via `C-c C-c`.
;;
;; E1 (this commit): scaffolding — mode, capture, preamble, open cmd.
;; E2 adds yasnippets + collaborator picker + persistence.
;; E3 adds the follow-up stash.
;; E4 adds the submit/route transient.

;; -- Review @mention author + collaborators store (PR B.47) --
;; The three user-tunable defvars (`-author', `-collaborators',
;; `-collaborators-file') and three accessor functions
;; (`-author', `-load-collaborators', `-save-collaborators')
;; live in agent-shell/review/decknix-agent-review-collaborators.el
;; alongside `decknix-agent-review-format'.  Multiple call sites in
;; this file (~lines 4083 / 4103 / 4348 / 4359 / 4439 / 4447 / 4448
;; / 4465 / 4471) reach the symbols through the heredoc's
;; `(require ...)' chain.
(defvar decknix-agent-review-author)
(defvar decknix-agent-review-collaborators)
(defvar decknix-agent-review-collaborators-file)

(defvar-local decknix--agent-review-source-buffer nil
  "Agent-shell buffer that this review buffer was created from.")

(defvar-local decknix--agent-review-session-id nil
  "Auggie session-id captured at the time of review.")

(defvar-local decknix--agent-review-workspace nil
  "Workspace root captured from the source buffer.")

(defvar decknix-agent-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'decknix-agent-review-submit)
    (define-key map (kbd "C-c C-k") #'decknix-agent-review-cancel)
    (define-key map (kbd "C-c C-f") #'decknix-agent-review-flag-followup)
    (define-key map (kbd "C-c C-l") #'decknix-agent-review-list-followups)
    (define-key map (kbd "C-c C-m") #'decknix-agent-review-add-collaborator)
    map)
  "Keymap for `decknix-agent-review-mode'.")

;; -- Review collaborator accessors (PR B.47) --
;; Moved into agent-shell/review/decknix-agent-review-collaborators.el
;; alongside the three defvars above.
(declare-function decknix--agent-review-author
                  "decknix-agent-review-collaborators")
(declare-function decknix--agent-review-load-collaborators
                  "decknix-agent-review-collaborators")
(declare-function decknix--agent-review-save-collaborators
                  "decknix-agent-review-collaborators")

(define-derived-mode decknix-agent-review-mode markdown-mode "AgentReview"
  "Major mode for annotating agent-shell exchanges.
Supports inline Option-1 annotations (💬 ✅ ❌ 🔀 🚩) and routing
the review back to the source agent-shell session.
\\{decknix-agent-review-mode-map}"
  (setq-local fill-column 100)
  (setq-local truncate-lines nil)
  (visual-line-mode 1)
  (when (fboundp 'yas-minor-mode)
    (yas-minor-mode 1))
  (decknix--agent-review-load-collaborators))

;; `decknix--agent-review-quote' lives in
;; agent-shell/review/decknix-agent-review-format.el alongside
;; format-exchanges and strip-meta — required at the top of
;; this heredoc.

(defun decknix--agent-review-capture-exchange (source-buffer n)
  "Return the last N exchanges from SOURCE-BUFFER's session, oldest first.
Each exchange is (USER-MSG . ASSISTANT-RESP).  Returns nil on failure."
  (with-current-buffer source-buffer
    (when-let ((sid (decknix--agent-buffer-session-id)))
      (decknix--agent-session-extract-history sid n))))

(defun decknix--agent-review-render-preamble (source-buffer)
  "Build the preamble string for a review of SOURCE-BUFFER."
  (let* ((session-name (buffer-name source-buffer))
         (workspace (with-current-buffer source-buffer
                      (or decknix--agent-session-workspace
                          default-directory)))
         (author (decknix--agent-review-author))
         (collabs (cons author
                        (seq-remove
                         (lambda (c) (string= c author))
                         decknix-agent-review-collaborators))))
    (concat
     "> 🧭 **review meta**\n"
     (format "> session: %s\n" session-name)
     (format "> workspace: %s\n"
             (abbreviate-file-name (or workspace "")))
     (format "> collaborators: %s\n"
             (mapconcat #'identity collabs ", "))
     "> route: agent  (C-c C-c submits to source session)\n"
     ">\n"
     "> 📋 **instructions for the agent** (Option 1):\n"
     "> Respond inline using `> 💬 **agent:** …` immediately after\n"
     "> each of my annotations. Keep order. Don't collapse multiple\n"
     "> annotations into one reply. For ❌ rejections, propose a\n"
     "> concrete change. For 🔀 option picks, acknowledge the chosen\n"
     "> option and update prior assumptions.\n"
     "\n")))

;; `decknix--agent-review-format-exchanges' lives in
;; agent-shell/review/decknix-agent-review-format.el.

(defun decknix-agent-review (&optional all)
  "Open a review buffer for the current agent-shell session.
With prefix ALL, capture the full session history rather than just
the last exchange."
  (interactive "P")
  (unless (decknix--agent-buffer-session-id)
    (user-error "Not in an agent-shell buffer with a known session"))
  (let* ((src (current-buffer))
         (n (if all 20 1))
         (exchanges (decknix--agent-review-capture-exchange src n))
         (sid (decknix--agent-buffer-session-id))
         (ws (or decknix--agent-session-workspace default-directory))
         (buf-name (format "*agent-review: %s*" (buffer-name src)))
         (buf (get-buffer-create buf-name)))
    (unless exchanges
      (user-error "No exchanges found for this session yet"))
    (with-current-buffer buf
      (decknix-agent-review-mode)
      (setq decknix--agent-review-source-buffer src)
      (setq decknix--agent-review-session-id sid)
      (setq decknix--agent-review-workspace ws)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (decknix--agent-review-render-preamble src))
        (insert (decknix--agent-review-format-exchanges exchanges))
        (goto-char (point-min))
        (when (re-search-forward "^## annotations" nil t)
          (forward-line 2))))
    (pop-to-buffer buf)))

;; -- Submit / route --

(defvar decknix-agent-review-jira-drafts-dir
  (expand-file-name "~/.config/decknix/review-jira-drafts")
  "Directory where `j' route writes Jira draft markdown files.")

;; `decknix--agent-review-strip-meta' lives in
;; agent-shell/review/decknix-agent-review-format.el.

(defun decknix--agent-review-content-for-route (route)
  "Return the review buffer content appropriate for ROUTE.
ROUTE is one of `agent', `pr', `jira', `file'."
  (let ((raw (buffer-string)))
    (pcase route
      ('agent
       ;; Agent already has the raw exchange in its history — strip
       ;; the review-meta header but keep the instructions block
       ;; (it tells the agent how to respond).
       (decknix--agent-review-strip-meta raw))
      (_
       ;; Other routes want the full buffer (meta + instructions +
       ;; annotations) for human consumption.
       raw))))

(defun decknix--agent-review-submit-to-agent (content)
  "Send CONTENT to the source agent-shell as a new prompt.
Handles the busy-prompt dance the same way the compose editor does."
  (let ((target decknix--agent-review-source-buffer)
        (action 'submit))
    (unless (buffer-live-p target)
      (user-error "Source agent-shell buffer is gone"))
    (unless (and (get-buffer-process target)
                 (process-live-p (get-buffer-process target)))
      (user-error "Agent process not running — restart with C-c A a"))
    (when (with-current-buffer target
            (bound-and-true-p shell-maker--busy))
      (let ((choice (read-char-choice
                     "Agent busy: [i]nterrupt & submit  [q]ueue  [c]ancel "
                     '(?i ?q ?c))))
        (pcase choice
          (?c (user-error "Submit cancelled"))
          (?q (setq action 'queue))
          (?i
           (with-current-buffer target
             (when (fboundp 'agent-shell-interrupt)
               (let ((agent-shell-confirm-interrupt nil))
                 (agent-shell-interrupt))))
           (sit-for 0.3)))))
    (pcase action
      ('queue
       (when (fboundp 'decknix--compose-enqueue-prompt)
         (decknix--compose-enqueue-prompt target content))
       (message "Queued review for agent"))
      ('submit
       (with-current-buffer target
         (goto-char (point-max))
         (shell-maker-submit :input content))
       (pop-to-buffer target)
       (message "Review sent to %s" (buffer-name target))))))

(defun decknix--agent-review-submit-pr (content)
  "Copy CONTENT to the kill-ring for pasting into a PR comment."
  (kill-new content)
  (message "Review copied to kill-ring (%d chars)" (length content)))

(defun decknix--agent-review-submit-jira (content)
  "Save CONTENT as a Jira draft markdown file."
  (make-directory decknix-agent-review-jira-drafts-dir t)
  (let* ((id (format-time-string "%Y%m%d-%H%M%S"))
         (file (expand-file-name
                (format "review-%s.md" id)
                decknix-agent-review-jira-drafts-dir)))
    (with-temp-file file
      (insert content))
    (message "Jira draft written: %s" (abbreviate-file-name file))))

(defun decknix--agent-review-submit-file (content)
  "Save CONTENT to a user-chosen file."
  (let ((file (read-file-name "Save review to: ")))
    (when (and file (not (string-empty-p file)))
      (with-temp-file file
        (insert content))
      (message "Review saved: %s" (abbreviate-file-name file)))))

(cl-defun decknix-agent-review-submit ()
  "Route the review buffer to the configured destination.
Prompts for:
  a  agent      — send as new prompt to source agent-shell (default)
  p  pr-comment — copy to kill-ring for pasting into a PR review
  j  jira       — save as a draft markdown under
          `decknix-agent-review-jira-drafts-dir'
  f  file       — save to a user-chosen path
  q  cancel"
  (interactive)
  (unless (derived-mode-p 'decknix-agent-review-mode)
    (user-error "Not in a review buffer"))
  (let* ((choice (read-char-choice
                  "Route: [a]gent  [p]r-comment  [j]ira  [f]ile  [q]uit "
                  '(?a ?p ?j ?f ?q ?\r)))
         (route (pcase choice
                  ((or ?a ?\r) 'agent)
                  (?p 'pr)
                  (?j 'jira)
                  (?f 'file)
                  (?q nil))))
    (unless route
      (user-error "Cancelled"))
    (let ((content (decknix--agent-review-content-for-route route)))
      (pcase route
        ('agent (decknix--agent-review-submit-to-agent content))
        ('pr    (decknix--agent-review-submit-pr content))
        ('jira  (decknix--agent-review-submit-jira content))
        ('file  (decknix--agent-review-submit-file content))))))

(defun decknix-agent-review-cancel ()
  "Abandon the current review buffer."
  (interactive)
  (when (yes-or-no-p "Abandon this review buffer? ")
    (kill-buffer (current-buffer))))

;; -- Follow-up stash (local JSON; future: GitHub / Jira routes) --

(defvar decknix-agent-review-followups-file
  (expand-file-name "~/.config/decknix/review-followups.json")
  "JSON file storing follow-ups flagged during review sessions.
A list of objects with keys: id, ts, session, workspace, author,
title, body, route (\"local\"|\"github\"|\"jira\"), status
(\"open\"|\"done\").")

(defun decknix--agent-review-followups-read ()
  "Return the current follow-ups list (may be empty)."
  (let ((f decknix-agent-review-followups-file))
    (if (file-exists-p f)
        (condition-case err
            (let ((json-array-type 'list)
                  (json-object-type 'alist)
                  (json-key-type 'symbol))
              (json-read-file f))
          (error
           (message "review-followups: failed to read %s — %s"
                    f (error-message-string err))
           nil))
      nil)))

(defun decknix--agent-review-followups-write (items)
  "Persist ITEMS to `decknix-agent-review-followups-file'."
  (let ((f decknix-agent-review-followups-file))
    (make-directory (file-name-directory f) t)
    (with-temp-file f
      (insert (json-encode items))
      (insert "\n"))))

(defun decknix--agent-review-followup-id ()
  "Generate a short, time-ordered id for a follow-up."
  (format "fu-%s-%04x"
          (format-time-string "%Y%m%d%H%M%S")
          (random 65536)))

(defun decknix-agent-review-flag-followup (title)
  "Flag the current paragraph as a follow-up.
Records an entry in `decknix-agent-review-followups-file' and
inserts a 🚩 annotation at point referencing its id.  TITLE is
prompted for — defaults to the first non-blank line near point."
  (interactive
   (list
    (let* ((default
            (save-excursion
              (goto-char (line-beginning-position))
              (when (looking-at "[[:space:]]*$")
                (forward-line 1))
              (string-trim
               (buffer-substring-no-properties
                (line-beginning-position)
                (line-end-position))))))
      (read-string (if (and default (not (string-empty-p default)))
                       (format "Follow-up title [%s]: " default)
                     "Follow-up title: ")
                   nil nil default))))
  (when (or (null title) (string-empty-p (string-trim title)))
    (user-error "Empty title — nothing recorded"))
  (let* ((items (decknix--agent-review-followups-read))
         (id (decknix--agent-review-followup-id))
         (entry `((id . ,id)
                  (ts . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z"))
                  (session . ,(or (and (buffer-live-p
                                        decknix--agent-review-source-buffer)
                                       (buffer-name
                                        decknix--agent-review-source-buffer))
                                  ""))
                  (workspace . ,(or decknix--agent-review-workspace ""))
                  (author . ,(decknix--agent-review-author))
                  (title . ,(string-trim title))
                  (body . "")
                  (route . "local")
                  (status . "open"))))
    (decknix--agent-review-followups-write (append items (list entry)))
    ;; Insert a linked annotation at point so the review buffer
    ;; shows where the follow-up came from.
    (save-excursion
      (end-of-line)
      (insert (format "\n> 🚩 **%s:** follow-up [%s] — %s\n"
                      (decknix--agent-review-author)
                      id
                      (string-trim title))))
    (message "Recorded follow-up %s — %s" id title)))

(defun decknix--agent-review-followup-describe (entry)
  "Return a single-line label for follow-up ENTRY."
  (format "%s  %-7s  %s  %s"
          (or (alist-get 'id entry) "?")
          (propertize (or (alist-get 'status entry) "open")
                      'face (if (string= (alist-get 'status entry) "done")
                                'font-lock-comment-face
                              'font-lock-warning-face))
          (format-time-string "%Y-%m-%d"
                              (ignore-errors
                                (date-to-time
                                 (alist-get 'ts entry ""))))
          (or (alist-get 'title entry) "(untitled)")))

(defun decknix-agent-review-list-followups ()
  "List stashed follow-ups via `completing-read'.
Selecting an entry offers a sub-action: mark-done / re-open / delete
/ copy-id / cancel."
  (interactive)
  (let* ((items (decknix--agent-review-followups-read)))
    (unless items
      (user-error "No follow-ups recorded yet"))
    (let* ((candidates
            (mapcar (lambda (e)
                      (cons (decknix--agent-review-followup-describe e)
                            e))
                    items))
           (pick (completing-read "Follow-up: " candidates nil t))
           (entry (cdr (assoc pick candidates)))
           (action (read-char-choice
                    "[d]one  [o]pen  [x]delete  [c]opy id  [q]uit: "
                    '(?d ?o ?x ?c ?q))))
      (pcase action
        (?d (decknix--agent-review-followup-set-status entry "done"))
        (?o (decknix--agent-review-followup-set-status entry "open"))
        (?x (decknix--agent-review-followup-delete entry))
        (?c (let ((id (alist-get 'id entry)))
              (kill-new id)
              (message "Copied: %s" id)))
        (?q (message "Cancelled"))))))

(defun decknix--agent-review-followup-set-status (entry status)
  "Update ENTRY's status to STATUS and persist."
  (let* ((id (alist-get 'id entry))
         (items (decknix--agent-review-followups-read))
         (updated
          (mapcar
           (lambda (e)
             (if (string= (alist-get 'id e) id)
                 (cons (cons 'status status)
                       (assq-delete-all 'status (copy-sequence e)))
               e))
           items)))
    (decknix--agent-review-followups-write updated)
    (message "Follow-up %s → %s" id status)))

(defun decknix--agent-review-followup-delete (entry)
  "Remove ENTRY from the stash (after confirm)."
  (when (yes-or-no-p (format "Delete follow-up %s? "
                             (alist-get 'id entry)))
    (let* ((id (alist-get 'id entry))
           (items (decknix--agent-review-followups-read))
           (filtered (seq-remove
                      (lambda (e) (string= (alist-get 'id e) id))
                      items)))
      (decknix--agent-review-followups-write filtered)
      (message "Deleted follow-up %s" id))))

(defun decknix-agent-review-add-collaborator ()
  "Add a collaborator to the local mention list."
  (interactive)
  (let ((name (read-string "Collaborator name: ")))
    (when (and name (not (string-empty-p name)))
      (cl-pushnew name decknix-agent-review-collaborators
                  :test #'string=)
      (decknix--agent-review-save-collaborators)
      (message "Added collaborator: %s" name))))

(defun decknix--agent-review-read-collaborator ()
  "Prompt for a collaborator name and persist any new entry.
Used by the `,m' yasnippet to populate the mention field.  Returns
the chosen name, or falls back to the review author when cancelled.
Selecting `new…' prompts for a fresh name and adds it to the list."
  (decknix--agent-review-load-collaborators)
  (let* ((author (decknix--agent-review-author))
         (others (seq-remove (lambda (c) (string= c author))
                             decknix-agent-review-collaborators))
         (choice (completing-read
                  "Mention: "
                  (append others (list "new…"))
                  nil nil)))
    (cond
     ((or (null choice) (string-empty-p choice))
      author)
     ((string= choice "new…")
      (let ((new (string-trim
                  (read-string "New collaborator name: "))))
        (if (string-empty-p new)
            author
          (cl-pushnew new decknix-agent-review-collaborators
                      :test #'string=)
          (decknix--agent-review-save-collaborators)
          new)))
     (t
      (unless (member choice decknix-agent-review-collaborators)
        (cl-pushnew choice decknix-agent-review-collaborators
                    :test #'string=)
        (decknix--agent-review-save-collaborators))
      choice))))      ; Unlink PR / repo

;; -- PR / repo linking interactive commands --

(defun decknix--clipboard-github-pr-url ()
  "Return clipboard content if it looks like a GitHub PR URL, else nil."
  (let ((clip (ignore-errors
                (current-kill 0 t))))
    (when (and clip (string-match-p
                     "https://github\\.com/[^/]+/[^/]+/pull/[0-9]+"
                     clip))
      (string-trim clip))))

(defun decknix--clipboard-github-repo-url ()
  "Return clipboard content if it looks like a GitHub repo URL.
Rejects pull-request URLs — those belong to `decknix--clipboard-github-pr-url'."
  (let ((clip (ignore-errors (current-kill 0 t))))
    (when (and clip
               (stringp clip)
               (string-match-p "https://github\\.com/[^/]+/[^/?#]+"
                               clip)
               (not (string-match-p "/pull/[0-9]+" clip)))
      (string-trim clip))))

(defun decknix--agent-current-conv-key ()
  "Get the conversation key for the current agent-shell buffer."
  (when (derived-mode-p 'agent-shell-mode)
    (when-let ((sid decknix--agent-auggie-session-id))
      (let* ((store (decknix--agent-tags-read))
             (convs (decknix--agent-tags-conversations store)))
        (catch 'found
          (maphash
           (lambda (key entry)
             (when (hash-table-p entry)
               (when (member sid (gethash "sessions" entry))
                 (throw 'found key))))
           convs)
          nil)))))

(defun decknix-agent-link-pr ()
  "Link a GitHub PR to the current session's conversation.
Prompts for URL (defaults to clipboard if it looks like a PR URL).
With prefix arg, prompts for PR type (authored/subject)."
  (interactive)
  (let* ((conv-key (decknix--agent-current-conv-key))
         (_ (unless conv-key
              (user-error "Not in an agent session buffer")))
         (default-url (decknix--clipboard-github-pr-url))
         (url (read-string
               (if default-url
                   (format "PR URL [%s]: "
                           (truncate-string-to-width default-url 50))
                 "PR URL: ")
               nil nil default-url))
         (_ (unless (decknix--agent-pr-parse-url url)
              (user-error "Not a valid GitHub PR URL")))
         (pr-type (if current-prefix-arg
                      (completing-read "Type: " '("authored" "subject")
                                       nil t nil nil "authored")
                    "authored")))
    (if (decknix--agent-link-pr conv-key url pr-type "manual")
        (progn
          (message "Linked %s PR: %s" pr-type url)
          (when (get-buffer "*agent-shell-sidebar*")
            (agent-shell-workspace-sidebar-refresh)))
      (message "PR already linked"))))

(defun decknix-agent-link-repo ()
  "Link a GitHub repo + branch to the current session's conversation.
Prompts for repo URL (defaults: clipboard if it looks like a repo URL,
or the session's workspace remote if it points at github.com) and
branch (defaulted via `decknix--detect-default-branch').

Use this for repos where work goes directly to a branch (no PR) — the
sidebar will show a commit row with HEAD SHA, age, CI status and DTSP
deploy indicator, sorted intermixed with PR rows by recency."
  (interactive)
  (let* ((conv-key (decknix--agent-current-conv-key))
         (_ (unless conv-key
              (user-error "Not in an agent session buffer")))
         (workspace (decknix--agent-workspace-for-conv-key conv-key))
         (ws-remote (when (and workspace (file-directory-p workspace))
                      (decknix--git-remote-url workspace)))
         (clip-url (decknix--clipboard-github-repo-url))
         (default-url (or clip-url ws-remote))
         (url (read-string
               (if default-url
                   (format "Repo URL [%s]: "
                           (truncate-string-to-width default-url 50))
                 "Repo URL: ")
               nil nil default-url))
         (_ (unless (decknix--agent-repo-parse-url url)
              (user-error "Not a valid GitHub repo URL (maybe a PR URL?)")))
         (default-branch
           (or (when (and workspace (file-directory-p workspace))
                 (decknix--detect-default-branch workspace))
               "main"))
         (branch (read-string (format "Branch [%s]: " default-branch)
                              nil nil default-branch)))
    (if (decknix--agent-link-repo conv-key url branch "manual")
        (progn
          (message "Linked repo: %s@%s" url branch)
          (when (get-buffer "*agent-shell-sidebar*")
            (agent-shell-workspace-sidebar-refresh)))
      (message "Repo+branch already linked"))))

(defun decknix-agent-unlink-pr ()
  "Unlink a GitHub PR or repo from the current session's conversation.
Both PRs and repo links surface in the same picker so you can unlink
either via a single command."
  (interactive)
  (let* ((conv-key (decknix--agent-current-conv-key))
         (_ (unless conv-key
              (user-error "Not in an agent session buffer")))
         (linked (decknix--agent-linked-items conv-key)))
    (if (not linked)
        (message "No linked items")
      (let* ((entries
              (mapcar
               (lambda (rec)
                 (let* ((url (decknix--agent-pr-url-accessor rec "url"))
                        (tp (or (decknix--agent-pr-url-accessor rec "type")
                                "authored"))
                        (branch (decknix--agent-pr-url-accessor rec "branch"))
                        (label (if (equal tp "repo")
                                   (format "[repo:%s] %s"
                                           (or branch "?") url)
                                 (format "[%s] %s" tp url))))
                   (cons label (cons rec url))))
               linked))
             (choice (completing-read "Unlink item: "
                                      (mapcar #'car entries) nil t))
             (pair (cdr (assoc choice entries)))
             (rec (car pair))
             (url (cdr pair))
             (tp (decknix--agent-pr-url-accessor rec "type"))
             (branch (decknix--agent-pr-url-accessor rec "branch")))
        (if (equal tp "repo")
            (decknix--agent-unlink-repo conv-key url branch)
          (decknix--agent-unlink-pr conv-key url))
        (message "Unlinked: %s" url)
        (when (get-buffer "*agent-shell-sidebar*")
          (agent-shell-workspace-sidebar-refresh))))))

;; == MCP server listing ==

(defun decknix-agent-mcp-list ()
  "Show configured MCP servers in a help buffer.
Reads from ~/.augment/settings.json."
  (interactive)
  (let* ((settings-file (expand-file-name "~/.augment/settings.json"))
         (json-object-type 'alist)
         (json-array-type 'list)
         (json-key-type 'symbol)
         (settings (if (file-exists-p settings-file)
                       (json-read-file settings-file)
                     nil))
         (servers (alist-get 'mcpServers settings))
         (buf (get-buffer-create "*MCP Servers*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert
         (propertize "MCP Server Configuration\n"
                     'font-lock-face '(:weight bold :height 1.2))
         (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face)
         "\n"
         (propertize (format "Source: %s\n\n" settings-file)
                     'font-lock-face 'font-lock-comment-face))
        (if (null servers)
            (insert "  No MCP servers configured.\n")
          (dolist (server servers)
            (let* ((name (symbol-name (car server)))
                   (config (cdr server))
                   (cmd (or (alist-get 'command config) "?"))
                   (args (alist-get 'args config))
                   (stype (or (alist-get 'type config) "stdio"))
                   (env (alist-get 'env config)))
              (insert (propertize (format "  %s\n" name)
                                  'font-lock-face 'font-lock-function-name-face))
              (insert (format "    type:    %s\n" stype))
              (insert (format "    command: %s\n" cmd))
              (when args
                (insert (format "    args:    %s\n"
                                (string-join (mapcar #'format args) " "))))
              (when (and env (> (length env) 0))
                (insert "    env:\n")
                (dolist (e env)
                  (insert (format "      %s=%s\n"
                                  (symbol-name (car e)) (cdr e)))))
              (insert "\n"))))
        (insert (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face) "\n"
                (propertize "Runtime changes (auggie mcp add) are temporary.\n"
                            'font-lock-face 'font-lock-comment-face)
                (propertize "To persist, edit Nix config and run decknix switch.\n"
                            'font-lock-face 'font-lock-comment-face)
                (propertize "Press q to close this buffer.\n"
                            'font-lock-face 'font-lock-comment-face))
        (goto-char (point-min))
        (special-mode)))
    (display-buffer buf '(display-buffer-at-bottom
                          (window-height . fit-window-to-buffer)))))
;; == Unified header-line: status + tags + workspace + context ==
;; Provides at-a-glance session identity and agent state in every
;; agent-shell buffer.  Merges with context panel data when available.
;; Refreshed every 2 seconds via a buffer-local timer to track
;; status transitions (working → ready → finished).

(defvar-local decknix--header-timer nil
  "Buffer-local timer for refreshing the header-line.")

(defvar-local decknix--header-prev-status nil
  "Previous raw status string, used to detect transitions.")

(defun decknix--header-detect-status ()
  "Return the current agent status as a string.
Uses agent-shell-workspace's detection when available (richer states),
otherwise falls back to shell-maker--busy."
  (cond
   ;; Rich detection from agent-shell-workspace
   ((fboundp 'agent-shell-workspace--buffer-status)
    (agent-shell-workspace--buffer-status (current-buffer)))
   ;; Fallback: shell-maker busy flag
   ((bound-and-true-p shell-maker--busy) "working")
   ;; Check if process is alive
   ((and (get-buffer-process (current-buffer))
         (process-live-p (get-buffer-process (current-buffer))))
    "ready")
   ((not (get-buffer-process (current-buffer))) "killed")
   (t "unknown")))

(defun decknix--header-status-icon (status)
  "Return a status icon string for STATUS."
  (pcase status
    ("ready"        "●")
    ("finished"     "✔")
    ("working"      "◐")
    ("waiting"      "◉")
    ("initializing" "○")
    ("killed"       "✕")
    (_              "?")))

(defun decknix--header-status-face (status)
  "Return a face for STATUS."
  (pcase status
    ("ready"        'success)
    ("finished"     '(:foreground "cyan" :weight bold))
    ("working"      'warning)
    ("waiting"      '(:foreground "red" :weight bold))
    ("initializing" 'font-lock-comment-face)
    ("killed"       'error)
    (_              'shadow)))

(defun decknix--header-tags ()
  "Return the tag list for the current buffer's conversation, or nil.
Fast path: uses `decknix--agent-conv-key' (set during post-create) to
look up tags directly, bypassing the session-list cache.  Falls back to
the session-id-based lookup if conv-key is not set yet."
  (or
   ;; Fast path: conv-key available (set during quickaction or
   ;; deferred prompt-ready) — no session-list cache dependency.
   (when (bound-and-true-p decknix--agent-conv-key)
     (decknix--agent-tags-for-conv-key decknix--agent-conv-key))
   ;; Slow path: look up via session-id → session-list → conv-key
   (when (and (boundp 'decknix--agent-auggie-session-id)
              decknix--agent-auggie-session-id)
     (decknix--agent-tags-for-session
      decknix--agent-auggie-session-id))))

(defun decknix--header-workspace-short ()
  "Return an abbreviated workspace path for the header-line."
  (when (and (boundp 'decknix--agent-session-workspace)
             decknix--agent-session-workspace
             (not (string-empty-p decknix--agent-session-workspace)))
    (abbreviate-file-name decknix--agent-session-workspace)))

(defun decknix--header-upstream ()
  "Return agent-shell's text header string.
This embeds the upstream header (agent name, model, mode, workspace,
session ID, context/usage indicator, busy animation) so we inherit
any improvements to agent-shell--make-header automatically."
  (ignore-errors
    (when (fboundp 'agent-shell--make-header)
      (let ((agent-shell-header-style 'text))
        (agent-shell--make-header (agent-shell--state))))))

(defun decknix--header-build ()
  "Build the unified header-line string for the current agent-shell buffer.
Embeds agent-shell's full header (agent name, model, mode, workspace,
busy animation) and appends decknix extras (status icon, tags, context panel)."
  (let* ((raw-status (decknix--header-detect-status))
         ;; Track transitions: working → ready = finished
         (status (cond
                  ((and (member decknix--header-prev-status
                                '("working" "waiting"))
                        (string= raw-status "ready"))
                   "finished")
                  (t raw-status)))
         (icon (decknix--header-status-icon status))
         (face (decknix--header-status-face status))
         (upstream (decknix--header-upstream))
         (tags (decknix--header-tags))
         (parts nil))
    ;; Clear "finished" once user returns to the buffer
    (when (and (string= status "finished")
               (eq (current-buffer) (window-buffer (selected-window))))
      (setq status raw-status))
    ;; Update previous status for next cycle
    (when (member raw-status '("working" "waiting"))
      (setq decknix--header-prev-status raw-status))
    (when (not (member raw-status '("working" "waiting")))
      (setq decknix--header-prev-status nil))
    ;; 1. Status icon + label
    (push (propertize (format " %s %s" icon status)
                      'face face)
          parts)
    ;; 2. Tags (stable width — before animated upstream)
    (when tags
      (push (propertize
             (mapconcat (lambda (tg) (format "#%s" tg)) tags " ")
             'face 'font-lock-type-face)
            parts))
    ;; 3. Context panel items (stable — before animated upstream)
    (when (fboundp 'decknix--context-header-string)
      (let ((ctx (decknix--context-header-string)))
        (when ctx (push ctx parts))))
    ;; 4. Agent-shell upstream header (agent, model, mode,
    ;;    workspace, session-id, usage, busy animation)
    ;; Placed last so the animated busy indicator expands/contracts
    ;; at the right edge without shifting stable elements.
    (when (and upstream (not (string-empty-p upstream)))
      (push (string-trim upstream) parts))
    ;; Join with separator
    (mapconcat #'identity (nreverse parts) "  │  ")))

(defun decknix--header-update ()
  "Update the header-line-format for the current agent-shell buffer."
  (when (derived-mode-p 'agent-shell-mode)
    (setq-local header-line-format
                (list (decknix--header-build)))
    (force-mode-line-update)))

(defun decknix--header-start-timer ()
  "Start a buffer-local 2-second timer to refresh the header-line."
  (when decknix--header-timer
    (cancel-timer decknix--header-timer))
  (let ((buf (current-buffer)))
    (setq decknix--header-timer
          (run-with-timer
           1 2
           (eval
            `(lambda ()
               (when (buffer-live-p ,buf)
                 (with-current-buffer ,buf
                   (decknix--header-update))))
            t)))))

(defun decknix--header-stop-timer ()
  "Stop the header-line refresh timer."
  (when decknix--header-timer
    (cancel-timer decknix--header-timer)
    (setq decknix--header-timer nil)))

;; TAB dispatch: yas field → corfu complete → yas expand → completion.
;; local-set-key overrides both the yas-keymap minor-mode binding
;; AND corfu-map, so we must check for both explicitly.
(defun decknix--agent-tab-dwim ()
  "Smart TAB: yasnippet fields, Corfu completion, snippet expansion, or CAPF.
Priority order:
1. Inside an active yasnippet field → advance to next field
2. Corfu popup visible → accept the selected completion
3. Try yasnippet expansion (returns non-nil on success)
4. Fall back to `completion-at-point'"
  (interactive)
  (cond
   ;; 1. Active snippet field — advance
   ((and (bound-and-true-p yas-minor-mode)
         (yas--snippets-at-point))
    (yas-next-field-or-maybe-expand))
   ;; 2. Corfu popup visible — accept completion
   ((and (bound-and-true-p corfu-mode)
         (boundp 'corfu--frame)
         (frame-live-p corfu--frame)
         (frame-visible-p corfu--frame))
    (corfu-complete))
   ;; 3. Try snippet expansion (yas-expand returns nil when nothing matched)
   ((and (bound-and-true-p yas-minor-mode)
         (yas-expand)))
   ;; 4. Fall back to standard completion
   (t (completion-at-point))))

(provide 'decknix-agent-shell-main)
;;; decknix-agent-shell-main.el ends here
