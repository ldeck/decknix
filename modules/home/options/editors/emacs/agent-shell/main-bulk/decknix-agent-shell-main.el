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
;; Tags / conv-resolve / conv-recency / session-workspace /
;; session-model / session-id / link-store / vcs forward
;; declarations.  The interactive entry points were split into
;; `decknix-agent-shell-main-tags' (PR Split.S.4); these forward
;; decls remain because session-lifecycle / picker / resume call
;; sites in this file still resolve the carved symbols at
;; byte-compile time.
(declare-function decknix--agent-conversation-key
                  "decknix-agent-conv-resolve" (first-message))
(declare-function decknix--agent-conv-resolve-key
                  "decknix-agent-conv-resolve" (conv-key))
(declare-function decknix--agent-conversation-key-for-session
                  "decknix-agent-conv-resolve" (session-id))
(declare-function decknix--agent-latest-session-id-for-conv-key
                  "decknix-agent-conv-resolve" (conv-key))
(defvar decknix--agent-tags-file)
(defvar decknix--agent-tags-cache)
(defvar decknix--agent-tags-cache-mtime)
(defvar decknix--agent-tags-cache-checked-at)
(defvar decknix--agent-tags-cache-ttl)
(declare-function decknix--agent-tags-read "decknix-agent-tags-store" ())
(declare-function decknix--agent-tags-write
                  "decknix-agent-tags-store" (store))
(declare-function decknix--agent-tags-conversations
                  "decknix-agent-tags-store" (store))
(declare-function decknix--agent-tags-for-session
                  "decknix-agent-tags-read" (session-id))
(declare-function decknix--agent-tags-for-conv-key
                  "decknix-agent-tags-read" (conv-key))
(declare-function decknix--agent-tags-all "decknix-agent-tags-read")
(declare-function decknix--agent-tags-set
                  "decknix-agent-tags-mutate" (conv-key tags))
(declare-function decknix--agent-tags-set-current-conversation
                  "decknix-agent-tags-mutate" (tags))
(declare-function decknix--agent-conv-touch
                  "decknix-agent-conv-recency" (conv-key))
(declare-function decknix--agent-conv-last-accessed
                  "decknix-agent-conv-recency" (conv-key))
(declare-function decknix--agent-workspace-for-conv-key
                  "decknix-agent-session-workspace" (conv-key))
(declare-function decknix--agent-session-save-workspace
                  "decknix-agent-session-workspace" (session-id workspace))
(declare-function decknix--agent-session-save-workspace-for-conv-key
                  "decknix-agent-session-workspace" (conv-key workspace))
(declare-function decknix--agent-session-model-for-conv-key
                  "decknix-agent-session-model" (conv-key))
(declare-function decknix--agent-session-save-model-for-conv-key
                  "decknix-agent-session-model" (conv-key model-id))
(declare-function decknix--agent-current-session-id
                  "decknix-agent-session-id")
(declare-function decknix--agent-require-session-id
                  "decknix-agent-session-id")
(declare-function decknix--agent-require-conv-key
                  "decknix-agent-session-id")
(declare-function decknix--agent-linked-items
                  "decknix-agent-link-store" (conv-key))
(declare-function decknix--agent-linked-prs
                  "decknix-agent-link-store" (conv-key))
(declare-function decknix--agent-linked-repos
                  "decknix-agent-link-store" (conv-key))
(declare-function decknix--agent-link-pr "decknix-agent-link-store"
                  (conv-key url &optional pr-type added))
(declare-function decknix--agent-unlink-pr
                  "decknix-agent-link-store" (conv-key url))
(declare-function decknix--agent-link-repo "decknix-agent-link-store"
                  (conv-key url branch &optional added))
(declare-function decknix--agent-unlink-repo
                  "decknix-agent-link-store" (conv-key url branch))
(declare-function decknix--git-remote-url "decknix-agent-vcs")
(declare-function decknix--detect-default-branch "decknix-agent-vcs")
(declare-function decknix--agent-review-quote "decknix-agent-review-format")
(declare-function decknix--agent-review-format-exchanges "decknix-agent-review-format")
(declare-function decknix--agent-review-strip-meta "decknix-agent-review-format")
(declare-function decknix--agent-review-followup-id "decknix-agent-review-followup-format")
(declare-function decknix--agent-review-followup-describe "decknix-agent-review-followup-format" (entry))
(declare-function decknix--agent-review-followups-read "decknix-agent-review-followup-io" ())
(declare-function decknix--agent-review-followups-write "decknix-agent-review-followup-io" (items))
(declare-function decknix--agent-review-followup-set-status "decknix-agent-review-followup-io" (entry status))
(declare-function decknix--agent-review-followup-delete "decknix-agent-review-followup-io" (entry))
(defvar decknix-agent-review-followups-file)
(declare-function decknix--agent-review-content-for-route "decknix-agent-review-submit" (route))
(declare-function decknix--agent-review-submit-to-agent "decknix-agent-review-submit" (content))
(declare-function decknix--agent-review-submit-pr "decknix-agent-review-submit" (content))
(declare-function decknix--agent-review-submit-jira "decknix-agent-review-submit" (content))
(declare-function decknix--agent-review-submit-file "decknix-agent-review-submit" (content))
(defvar decknix-agent-review-jira-drafts-dir)
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
(defvar comint-input-ring-size)
(defvar comint-scroll-to-bottom-on-input)
(defvar comint-scroll-to-bottom-on-output)
(defvar comint-scroll-show-maximum-output)
(defvar agent-shell-auggie-acp-command)
(defvar agent-shell-display-action)
(defvar decknix--sidebar-previous-sessions)
(defvar agent-shell-confirm-interrupt)
(defvar agent-shell-header-style)

;; == Tutorial: welcome message + help buffer ==
;;
;; PR B.64: the welcome-message renderer + the three help-buffer
;; commands (`-help-keys', `-help-tutorial', `-help-functions')
;; were carved into `decknix-agent-help' (`agent-shell/help/').
;; The advice that wires `decknix--agent-welcome-message' into
;; `agent-shell-auggie-make-agent-config' lives in the heredoc
;; (Rule 2: top-level side-effects stay in main).  Forward-
;; declare so the byte-compile pass resolves the carved symbols
;; if main-bulk grows a future caller of any of them.
(declare-function decknix--agent-welcome-message
                  "decknix-agent-help" (config))
(declare-function decknix--agent-help-show
                  "decknix-agent-help" (name content))
(declare-function decknix-agent-help-keys "decknix-agent-help")
(declare-function decknix-agent-help-tutorial "decknix-agent-help")
(declare-function decknix-agent-help-functions "decknix-agent-help")


;; == Session management: unified picker + clean quit ==
;; PR Split.S.5: extracted into `decknix-agent-shell-main-session'
;; (a sibling under `main-bulk/').  Owns the buffer-local var
;; family, context-history toggle + timeline navigation, comint
;; input-ring restore, the consult `--multi' picker (Live /
;; Previous / Saved / New), the rg + jq full-text grep, the
;; session-resume primitive (with jump-to-match), the
;; workspace-persistence hook, and the four interactive
;; commands (`new', `quit', `recent', `history') plus the
;; agent-buffer switcher.  Side-effecting `(define-key)'
;; bindings into the heredoc's prefix maps still happen in the
;; heredoc itself per AGENTS.md Rule 2.
(require 'decknix-agent-shell-main-session)

;; The post-create hook is consumed by the quickaction-start
;; flow further down in this file (interactive command spawning
;; a new agent-shell with a primed first message).  Forward-
;; declare so this file byte-compiles clean independently of
;; the load order between session.el and tags.el.
(declare-function decknix--agent-session-new-post-create
                  "decknix-agent-shell-main-session"
                  (before-buffers name tags workspace
                                  &optional first-message))

;; == Session tagging + identity + per-session model + linking helpers ==
;; Split into `decknix-agent-shell-main-tags' (PR Split.S.4).
;; Owns:
;;   - interactive tag commands (`decknix-agent-tag-{show,add,remove,
;;     list,edit,delete,cleanup}')
;;   - per-session model wrapper: `decknix-agent-set-session-model'
;;   - rename-conversation: `decknix-agent-session-rename'
;;   - session-id display ops: `decknix-agent-session-{copy-id,toggle-id-display}'
;;     plus the buffer-local toggle defvar `decknix--agent-show-full-session-id'
;;     and the helper `decknix--agent-get-session-id'
;; The split file forward-declares the carved metadata helpers
;; (`decknix-agent-{tags-store,tags-read,tags-mutate,conv-resolve,
;; conv-recency,session-workspace,session-model,session-id,
;; link-store,vcs}') and the main-resident `decknix--agent-session-resume'
;; / `-unsorted-table' / `decknix-agent-session-history-count'
;; consumed by `decknix-agent-tag-list'.
(require 'decknix-agent-shell-main-tags)

;; == Compose buffer: magit-style prompt editing ==
;; Split into `decknix-agent-shell-main-compose' (PR Split.S.3).
;; Owns:
;;   - `decknix-agent-compose-mode' + `-mode-map' + `-interrupt-map'
;;   - buffer-locals: `-target-buffer' / `-sticky' / `-queued-prompt'
;;     / `-queue-timer'
;;   - history navigation: `-{previous,next}-input{,-global}'
;;   - prompt search (M-r): `decknix-agent-compose-search-history'
;;   - parent-buffer forwarding: `decknix-compose-{jump,workspace-toggle,
;;     session-picker,context-panel,tags}'
;;   - submit / interrupt / cancel / close / toggle-sticky entry points
;;   - `decknix--compose-{finish,update-header-line,get-or-create,
;;     queue-poll,enqueue-prompt}' adapters
;;   - top-level entry points: `decknix-agent-compose' /
;;     `-compose-interrupt'
;; The split file forward-declares the carved compose/ helpers
;; (`decknix-agent-compose-{history,busy,queue,header,internals}',
;; `decknix-agent-prompt-{extract,search,search-cache}') and the
;; main-resident `decknix-session-{picker,tags-show}' parent commands.
(require 'decknix-agent-shell-main-compose)

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

;; -- Clipboard URL DWIM (PR B.49 + B.63) --
;; Moved into agent-shell/agent/decknix-agent-clipboard.el.
;; All call sites reach the symbols through the heredoc's
;; `(require 'decknix-agent-clipboard)' chain.
(declare-function decknix--agent-clipboard-url "decknix-agent-clipboard")
(declare-function decknix--clipboard-github-pr-url "decknix-agent-clipboard")
(declare-function decknix--clipboard-github-repo-url "decknix-agent-clipboard")

(defun decknix--agent-quickaction-start (name tags workspace command)
  "Start a quick-action session with NAME, TAGS, WORKSPACE, and auto-send COMMAND.
Creates a new agent session, applies metadata, then subscribes to the
`prompt-ready' event to send COMMAND as soon as the ACP session is
fully established.  Returns immediately.
When invoked from a dedicated or side window (e.g., the sidebar), the
new session is displayed in the frame's main window instead of
replacing the caller, preserving the sidebar."
  ;; PR B.80: window-classification + target-selection are pinned
  ;; by `decknix-agent-quickaction-window' (carved, +10 ERT).
  ;; Bulk evaluates the frame/window I/O signals and hands them
  ;; to the pure resolvers; returned target drives the
  ;; `display-buffer-alist' override below.
  (let* ((workspace (expand-file-name workspace))
         (cur (selected-window))
         (sidebar-buf (or (bound-and-true-p
                           agent-shell-workspace-sidebar-buffer-name)
                          "*agent-shell-sidebar*"))
         (cur-is-sidebar
          (decknix--quickaction-window-is-sidebar-p
           (window-parameter cur 'window-side)
           (window-dedicated-p cur)
           (buffer-name (window-buffer cur))
           sidebar-buf))
         (target-win
          (decknix--quickaction-target-window
           cur-is-sidebar cur (window-main-window (selected-frame))))
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
;; Split into `decknix-agent-shell-main-batch' (PR Split.S.2).
;; Owns:
;;   - `decknix--batch-{launch,show-summary,submit,cancel}'
;;   - `decknix-batch-compose-mode' + `-mode-map' + font-lock keywords
;;   - `decknix-agent-batch-process' (interactive entry point)
;;   - state: `decknix--batch-default-workspace',
;;     `decknix--batch-launch-results'
;; The split file forward-declares the carved batch helpers
;; (`decknix-agent-batch-parse', `decknix-agent-batch-build') and
;; the main-resident `decknix--agent-quickaction-start' /
;; `-detect-workspace' / `-pr-detect-workspace'.
(require 'decknix-agent-shell-main-batch)

;; == Inline review buffer (decknix-agent-review-mode) ==
;; Split into `decknix-agent-shell-main-review' (PR Split.S.1).
;; Owns:
;;   - `decknix-agent-review-mode' + `-mode-map'
;;   - buffer-locals: `-source-buffer' / `-session-id' / `-workspace'
;;   - interactive entry points: `-review' / `-submit' / `-cancel'
;;     / `-flag-followup' / `-list-followups' / `-add-collaborator'
;;   - the `,m' yasnippet helper `-read-collaborator'
;; The split file forward-declares the carved review/ helpers and
;; the heredoc-resident defvars (`-author', `-collaborators',
;; `-followups-file', `-jira-drafts-dir').
(require 'decknix-agent-shell-main-review)


;; -- PR / repo linking interactive commands --

;; PR B.63: `decknix--clipboard-github-pr-url' and
;; `decknix--clipboard-github-repo-url' carved into
;; `agent-shell/agent/decknix-agent-clipboard.el' alongside
;; the pre-existing `decknix--agent-clipboard-url'.  Forward
;; declarations live with the other clipboard declares above.

;; `decknix--agent-current-conv-key' carved into
;; `decknix-agent-buffer-lookup' (PR B.66) alongside the other
;; buffer / conv-key lookups.

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
;;
;; PR B.65: the entire header-line cluster -- two buffer-local
;; defvars + the eleven pure builders + the timer plumbing --
;; was carved into `decknix-agent-header'
;; (`agent-shell/header/').  The agent-shell startup hook below
;; (`decknix--header-update' + `-start-timer' + the
;; `kill-buffer-hook' wiring) stays in the heredoc per AGENTS.md
;; Rule 2 because it side-effects on buffer init.  Forward-declare
;; so the byte-compile pass resolves the carved symbols if a
;; future caller in main-bulk references any of them.
(defvar decknix--header-timer)
(defvar decknix--header-prev-status)
(declare-function decknix--header-update "decknix-agent-header")
(declare-function decknix--header-build "decknix-agent-header")
(declare-function decknix--header-start-timer "decknix-agent-header")
(declare-function decknix--header-stop-timer "decknix-agent-header")


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
