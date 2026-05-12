;;; decknix-agent-help.el --- Welcome message + help / tutorial buffers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, help

;;; Commentary:
;;
;; Pure presentation layer for the agent-shell welcome banner and
;; the three help buffers reachable via `C-c ? k' (keys),
;; `C-c ? t' (tutorial), and `C-c ? f' (functions / templates).
;; Carved out of `decknix-agent-shell-main' (main-bulk) so the
;; large block of `propertize'-built reference text -- ~270 lines
;; that account for ~5% of main-bulk -- lives in its own
;; byte-compiled unit.
;;
;; Public surface:
;;
;;   `decknix--agent-welcome-message' (config)
;;       Renders the auggie ASCII art + `shell-maker' welcome
;;       blurb and appends a one-line key hint.  Wired into
;;       `agent-shell--config' via a `setcdr' in the heredoc so
;;       a fresh session opens with the discoverability hint
;;       already on screen.
;;
;;   `decknix-agent-help-keys'         (interactive)
;;   `decknix-agent-help-tutorial'     (interactive)
;;   `decknix-agent-help-functions'    (interactive)
;;       The three help buffers themselves.  All three pop a
;;       read-only `*Agent Keys*' / `*Agent Tutorial*' /
;;       `*Agent Functions*' buffer at the bottom of the frame
;;       sized to its content; press `q' to dismiss.
;;
;; Three external symbols are touched at runtime: the upstream
;; `agent-shell--indent-string', `agent-shell-auggie--ascii-art',
;; and `shell-maker-welcome-message' (welcome path) plus
;; `decknix--agent-command-files' /
;; `decknix--agent-command-description' (functions path) and the
;; standard `yas-snippet-dirs' defvar.  All are forward-declared
;; below so the byte-compile pass stays warning-clean.

;;; Code:

;; -- Forward declarations ----------------------------------------

(declare-function agent-shell--indent-string "agent-shell" (n s))
(declare-function agent-shell-auggie--ascii-art "agent-shell-auggie")
(declare-function shell-maker-welcome-message "shell-maker" (config))

(declare-function decknix--agent-command-files
                  "decknix-agent-command-discover")
(declare-function decknix--agent-command-description
                  "decknix-agent-command-discover" (file))

(defvar yas-snippet-dirs)

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
    "  C-c s [     Page Context window to older turns\n"
    "  C-c s ]     Page Context window to newer turns\n"
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
                  'font-lock-face 'font-lock-comment-face)))))

(provide 'decknix-agent-help)
;;; decknix-agent-help.el ends here
