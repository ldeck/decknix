;;; decknix-agent-shell-main-misc.el --- Misc agent-shell commands -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix

;;; Commentary:
;;
;; Split.S.7: trailing miscellany from `decknix-agent-shell-main' that
;; doesn't justify its own thematic file.  Sibling of the six other
;; `main-bulk/decknix-agent-shell-main-*' files.  Co-resident in the
;; same `trivialBuild' so all `main-bulk/' siblings are byte-compiled
;; together against a shared load-path.
;;
;; Owns:
;;   - Custom command CRUD: `decknix-agent-command-{run,new,edit}'.
;;     The pure discovery layer (`decknix--agent-command-{files,
;;     description,dirs}') was carved into
;;     `agent-shell/agent/decknix-agent-command-discover.el' (PR B.46);
;;     this file owns only the interactive surfaces that prompt the
;;     user, insert slash commands at the agent-shell prompt, or
;;     visit the .md template under `~/.augment/commands/'.
;;   - MCP server listing: `decknix-agent-mcp-list' (renders
;;     `~/.augment/settings.json'->mcpServers in a `*MCP Servers*'
;;     help buffer with propertised columns).
;;   - TAB dispatch: `decknix--agent-tab-dwim' (yas field -> corfu
;;     complete -> yas expand -> completion-at-point).  Wired into
;;     `agent-shell-mode' via `local-set-key' in the heredoc.
;;
;; Side-effecting `(define-key)' bindings (`C-c A c c' / `c n' / `c e'
;; for custom commands; agent-shell-mode-hook -> local-set-key for
;; TAB) still happen in the heredoc itself per AGENTS.md Rule 2.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

;; -- Carved discovery layer (PR B.46) --
(declare-function decknix--agent-command-files
                  "decknix-agent-command-discover")
(declare-function decknix--agent-command-description
                  "decknix-agent-command-discover" (file))
(defvar decknix--agent-command-dirs)

;; -- Yasnippet / Corfu surfaces consumed by `tab-dwim' --
(declare-function yas-next-field-or-maybe-expand "ext:yasnippet")
(declare-function yas-expand "ext:yasnippet")
(declare-function yas--snippets-at-point "ext:yasnippet")
(declare-function corfu-complete "ext:corfu")

;; == Custom commands: discovery, picker, authoring ==

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

;; == TAB dispatch ==

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

(provide 'decknix-agent-shell-main-misc)
;;; decknix-agent-shell-main-misc.el ends here
