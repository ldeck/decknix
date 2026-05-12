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
;;
;; PR B.52: the path builder (`decknix--agent-session-file') and
;; the pure turn-grouping extractor
;; (`decknix--agent-session-extract-history') were carved into
;; `decknix-agent-session-history' (`agent-shell/agent/').  The
;; buffer-side `prepopulate' / `restore-input-ring' below stay in
;; main-bulk because they side-effect the agent buffer (per
;; AGENTS.md Rule 2).  Forward-declare so the byte-compile pass
;; resolves the carved symbols.

(declare-function decknix--agent-session-file
                  "decknix-agent-session-history" (session-id))
(declare-function decknix--agent-session-extract-history
                  "decknix-agent-session-history" (session-id n))
;; Timeline navigation helpers (#136) — pure list/index math used
;; by the buffer-local cursor commands `decknix-agent-history-older'
;; / `-newer' and the cross-window jump-to-match below.
(declare-function decknix--agent-session-extract-all-turns
                  "decknix-agent-session-history" (session-id))
(declare-function decknix--agent-session-window-clamp
                  "decknix-agent-session-history" (cursor count total))
(declare-function decknix--agent-session-take-window
                  "decknix-agent-session-history" (turns cursor count))
(declare-function decknix--agent-session-find-turn-containing
                  "decknix-agent-session-history" (turns regexp))

;; Pure session formatters live in `decknix-agent-session-format'
;; (PR B.54, `agent-shell/agent/').  Picker rows + buffer rename
;; sites in this file dispatch to them; forward-declare so the
;; byte-compile pass resolves the carved symbols.
(declare-function decknix--agent-session-preview
                  "decknix-agent-session-format" (session))
(declare-function decknix--agent-session-display-name
                  "decknix-agent-session-format" (session))

;; Conversation aggregation + live-buffer label live in
;; `decknix-agent-session-group' (PR B.56, `agent-shell/agent/').
;; The picker / sidebar / collapsed-conversation header dispatch
;; to them; forward-declare so the byte-compile pass resolves the
;; carved symbols.
(declare-function decknix--agent-session-group-by-conversation
                  "decknix-agent-session-group"
                  (sessions &optional include-hidden))
(declare-function decknix--agent-session-live-label
                  "decknix-agent-session-group" (buf))

;; Pure formatters for the session-grep picker live in
;; `decknix-agent-grep-format' (PR B.57, `agent-shell/agent/').
;; The grep command in this file dispatches to them via the
;; consult :items lambda; forward-declare so the byte-compile
;; pass resolves the carved symbols.
(declare-function decknix--agent-session-grep-candidate
                  "decknix-agent-grep-format" (session))
(declare-function decknix--agent-session-grep-build-entries
                  "decknix-agent-grep-format" (sessions expand))

;; Pure formatter for conversation-collapsed picker rows lives in
;; `decknix-agent-conv-format' (PR B.58, `agent-shell/agent/').
;; The session picker dispatches to it from the saved-sessions
;; section; forward-declare so the byte-compile pass resolves the
;; carved symbol.
(declare-function decknix--agent-conversation-preview
                  "decknix-agent-conv-format" (conv-group))

;; Pure dispatch helper for the compose-submit busy-prompt lives
;; in `decknix-agent-compose-busy' (`agent-shell/compose/').  Maps
;; (busy-p, user-choice) to one of `submit', `interrupt-submit',
;; `queue', or `cancel'; the submit handler `pcase'-es over the
;; result instead of using `cl-return-from'.
(declare-function decknix--compose-busy-action
                  "decknix-agent-compose-busy" (busy-p))

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
    ;; Timeline navigation (#136) — page the rendered window of
    ;; restored exchanges by `decknix-agent-session-history-count'
    ;; in either direction without reloading the JSON.  The full
    ;; turn list is cached buffer-locally on the first prepopulate.
    (define-key map (kbd "[") #'decknix-agent-history-older)
    (define-key map (kbd "]") #'decknix-agent-history-newer)
    map)
  "Keymap for the Context section header toggle.")

;; -- Timeline navigation (#136) ----------------------------------
;;
;; The Context section restored on `--resume' shows a fixed window
;; of the last `decknix-agent-session-history-count' turns.  These
;; buffer-local vars + the `[' / `]' commands (bound on the Context
;; header keymap above and on `C-c s [' / `C-c s ]' in agent-shell
;; buffers) page that window through the full on-disk turn list
;; without re-parsing the JSON on every press.
;;
;; The cache holds the parsed all-turns list; the cursor is the
;; 0-based index of the topmost turn currently rendered.  Both are
;; per-buffer so multiple sessions can sit at different positions
;; in their respective timelines.

;; PR B.68: the two buffer-local caches and the three paging
;; primitives (`-context-find-existing', `-context-render-window',
;; `-session-prepopulate') were carved into
;; `decknix-agent-context-history'.  The interactive paging
;; commands (`decknix-agent-history-older' / `-newer' below) and
;; the section-header keymap (`decknix--agent-context-header-map'
;; above) stay here per AGENTS.md Rule 2.  Forward-declare the
;; carved symbols so the byte-compiler resolves them.
(defvar decknix--agent-history-cache)
(defvar decknix--agent-history-cursor)
(declare-function decknix--agent-context-find-existing
                  "decknix-agent-context-history")
(declare-function decknix--agent-context-render-window
                  "decknix-agent-context-history" (cursor))
(declare-function decknix--agent-session-prepopulate
                  "decknix-agent-context-history"
                  (session-id n))


(defun decknix-agent-history-older (&optional n)
  "Page the Context timeline window backwards by N turns.
N defaults to `decknix-agent-session-history-count' so a single
press shifts the window by exactly one screenful.  No-op when
already at the oldest turn (cursor = 0); reports that fact when
called interactively."
  (interactive "P")
  (let ((step (if n (prefix-numeric-value n)
                decknix-agent-session-history-count)))
    (cond
     ((null decknix--agent-history-cache)
      (when (called-interactively-p 'interactive)
        (message "No restored Context history in this buffer.")))
     ((or (null decknix--agent-history-cursor)
          (zerop decknix--agent-history-cursor))
      (when (called-interactively-p 'interactive)
        (message "Already at the oldest turn.")))
     (t
      (decknix--agent-context-render-window
       (- decknix--agent-history-cursor step))))))

(defun decknix-agent-history-newer (&optional n)
  "Page the Context timeline window forwards by N turns.
N defaults to `decknix-agent-session-history-count' so a single
press shifts the window by exactly one screenful.  No-op when
already at the newest turn; reports that fact when called
interactively."
  (interactive "P")
  (let* ((step (if n (prefix-numeric-value n)
                 decknix-agent-session-history-count))
         (count decknix-agent-session-history-count)
         (total (length decknix--agent-history-cache))
         (max-cursor (max 0 (- total count))))
    (cond
     ((null decknix--agent-history-cache)
      (when (called-interactively-p 'interactive)
        (message "No restored Context history in this buffer.")))
     ((or (null decknix--agent-history-cursor)
          (>= decknix--agent-history-cursor max-cursor))
      (when (called-interactively-p 'interactive)
        (message "Already at the newest turn.")))
     (t
      (decknix--agent-context-render-window
       (+ decknix--agent-history-cursor step))))))

(defun decknix--agent-session-restore-input-ring (session-id)
  "Populate `comint-input-ring' with prompts from SESSION-ID's local JSON.
On a freshly-resumed session the ring is created empty by
`comint-mode' and only grows from inputs the user submits in *this*
Emacs run, so M-p / M-n in the compose buffer (and standard comint
history navigation in the agent buffer itself) cycle through nothing
even though the session has hundreds of past prompts.  Same blocker
hits the global cross-session walk (M-P / M-N) when it starts at
the current session.

Reads the user prompts via `decknix--prompt-extract-from-file' (jq
path, newest first), grows the ring to fit when there are more
prompts than the default `comint-input-ring-size', then ring-inserts
in oldest-first order so the newest sits at index 0 -- matching how
`comint-read-input-ring' loads from a history file.

No-ops when the ring already has entries (the user has typed in this
buffer) so we never clobber fresh history with stale on-disk data."
  (when (and (bound-and-true-p comint-input-ring)
             (ring-p comint-input-ring)
             (ring-empty-p comint-input-ring))
    (let* ((file (decknix--agent-session-file session-id))
           (prompts (and (file-exists-p file)
                         (decknix--prompt-extract-from-file file))))
      (when prompts
        ;; PR B.78: ring-sizing and insertion-ordering rules are
        ;; pinned by `decknix-agent-input-ring' (carved, +11 ERT).
        ;; This function is the comint-side adapter that performs
        ;; the actual `make-ring' / `ring-insert' mutation.
        (let ((needed (decknix--input-ring-required-size
                       comint-input-ring-size (length prompts))))
          (setq-local comint-input-ring-size needed)
          (setq-local comint-input-ring (make-ring needed)))
        (dolist (p (decknix--input-ring-insertion-order prompts))
          (ring-insert comint-input-ring p))))))

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

;; PR B.66: `decknix--agent-buffer-session-id',
;; `-find-new-shell-buffer', `-find-live-buffer-for-conv-key' and
;; `-current-conv-key' carved into `decknix-agent-buffer-lookup'.
;; All four are read-only helpers; the heredoc requires the package
;; and forward-declares the symbols so this file compiles clean.

;; `decknix--agent-session-preview' lives in
;; agent-shell/agent/decknix-agent-session-format.el (PR B.54) --
;; required at the top of this heredoc.

(defvar decknix-agent-session-history-count 2
  "Default number of recent exchanges to show when resuming a session.
Use C-u prefix with the session picker to override.")

(defvar decknix--agent-grep-last-input nil
  "Most recent input typed into `decknix-agent-session-grep'.
Captured by the dynamic collection lambda so the post-selection
handler can pass the search term through to
`decknix--agent-session-resume' for jump-to-match.")

;; `decknix--agent-session-display-name' lives in
;; agent-shell/agent/decknix-agent-session-format.el (PR B.54) --
;; required at the top of this heredoc.

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
to the match end and recenters.

When TERM is not present in the rendered buffer text, falls back
to searching the buffer-local `decknix--agent-history-cache' (the
full parsed turn list).  If a turn matches, seeds
`decknix--agent-history-cursor' so that turn lands at the bottom
of the rendered window, re-renders via
`decknix--agent-context-render-window', expands the section so
the matched text is visible, then re-runs the buffer search to
position point on the match.

Falls back to point-max with an explanatory message when neither
the buffer nor the cache yields a match.  Returns t when a match
was found (in either pass), nil otherwise."
  (when (and term (buffer-live-p buf))
    (with-current-buffer buf
      (let ((case-fold-search t)
            (win (get-buffer-window buf)))
        (cl-labels
            ((find-in-buffer ()
               (save-excursion
                 (goto-char (point-min))
                 (search-forward term nil t)))
             (land-on (hit)
               (when (and hit (window-live-p win))
                 (set-window-point win hit)
                 (with-selected-window win
                   (goto-char hit)
                   (recenter)))
               t)
             (force-expand-section ()
               (let ((existing (decknix--agent-context-find-existing)))
                 (when existing
                   (let ((inhibit-read-only t))
                     (put-text-property
                      (plist-get existing :body-start)
                      (plist-get existing :body-end)
                      'invisible nil)
                     (save-excursion
                       (goto-char (plist-get existing :header-start))
                       (when (re-search-forward
                              "[▼▶]"
                              (plist-get existing :body-start)
                              t)
                         (replace-match "▼")))))))
             (give-up (msg)
               (when (window-live-p win)
                 (set-window-point win (point-max)))
               (message msg)
               nil))
          ;; Decision separated from side-effects via the carved
          ;; `decknix-agent-jump-target' resolver (PR B.77, #136).
          ;; We compute the two search results up-front and let the
          ;; pure resolver pick the strategy; the dispatch below
          ;; performs the actual rendering / window mutation.
          (let* ((buffer-hit (find-in-buffer))
                 (cache-idx (when (and (null buffer-hit)
                                       decknix--agent-history-cache)
                              (decknix--agent-session-find-turn-containing
                               decknix--agent-history-cache
                               (regexp-quote term))))
                 (target (decknix--jump-target-resolve
                          buffer-hit cache-idx
                          decknix-agent-session-history-count)))
            (pcase (plist-get target :strategy)
              ('in-buffer
               (land-on (plist-get target :hit)))
              ('render-window
               (decknix--agent-context-render-window
                (plist-get target :anchor))
               (force-expand-section)
               (let ((rehit (find-in-buffer)))
                 (if rehit
                     (land-on rehit)
                   ;; Edge case: turn matched but the buffer search
                   ;; still misses (e.g. truncation ate the region).
                   (give-up
                    (format "Term %S found in turn but truncated out of view"
                            term)))))
              ('not-found
               (give-up
                (format "Term %S not in loaded history (only %d exchanges shown)"
                        term
                        decknix-agent-session-history-count))))))))))

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
         ;; Per-conversation model override (set mid-session
         ;; via C-c C-v).  When absent, omit --model so auggie
         ;; falls back to the global default in settings.json.
         (saved-model (decknix--agent-session-model-for-conv-key
                       conv-key))
         ;; Validate workspace once here (filesystem I/O); the
         ;; pure `decknix--resume-command-build' below treats a
         ;; non-empty string as "use it".
         (validated-ws (when (and workspace
                                  (file-directory-p workspace))
                         workspace))
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
         ;; default.el is dynamic-bound.  Composition itself is
         ;; carved into `decknix-agent-resume-command' (PR B.76)
         ;; so the argument-order contract is unit-tested.
         (augmented-cmd
          (decknix--resume-command-build
           agent-shell-auggie-acp-command
           validated-ws saved-model session-id))
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
          (let ((default-directory (or validated-ws default-directory)))
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
                   ;; Seed `comint-input-ring' from the on-disk
                   ;; session so M-p / M-n in compose (and the
                   ;; agent buffer's own comint history nav) cycle
                   ;; through this conversation's previous prompts
                   ;; instead of finding an empty ring.
                   (decknix--agent-session-restore-input-ring ,sid)
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

;; PR B.67: `decknix--agent-conversation-hidden-p' and
;; `-set-hidden' carved into `decknix-agent-conv-hidden'.  The
;; heredoc requires the package and forward-declares both symbols.

;; `decknix--agent-session-group-by-conversation' lives in
;; agent-shell/agent/decknix-agent-session-group.el (PR B.56) --
;; required at the top of this heredoc.

;; `decknix--agent-conversation-preview' lives in
;; agent-shell/agent/decknix-agent-conv-format.el (PR B.58) --
;; required at the top of this heredoc.

;; ── Session picker (consult--multi) ──────────────────────────
;; Modelled after C-x b (consult-buffer): sectioned groups with
;; horizontal dividers — Live Sessions → Saved Sessions → New.

;; `decknix--agent-session-live-label' lives in
;; agent-shell/agent/decknix-agent-session-group.el (PR B.56) --
;; required at the top of this heredoc.

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
         (cmd (decknix--rg-fast-command rg term sessions-dir))
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
           (id-set (decknix--rg-paths-to-id-set paths))
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
         (cmd (decknix--rg-thorough-command
               (or (executable-find "rg") "rg")
               term sessions-dir jqf))
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

;; `decknix--agent-session-grep-candidate' and
;; `decknix--agent-session-grep-build-entries' live in
;; agent-shell/agent/decknix-agent-grep-format.el (PR B.57) --
;; required at the top of this heredoc.

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

;; PR B.70: `decknix--agent-flush-pending-metadata',
;; `-store-metadata-by-conv-key' and `-register-session-id' were
;; carved into `decknix-agent-tags-mutate'.  The `add-hook' that
;; installs the flush against `comint-input-filter-functions' lives
;; in `decknix--agent-auto-persist-workspace' below per AGENTS.md
;; Rule 2; the function bodies themselves are pure tag-store
;; mutators.  Forward-declare so the byte-compiler resolves them.
(declare-function decknix--agent-flush-pending-metadata
                  "decknix-agent-tags-mutate" (input))
(declare-function decknix--agent-store-metadata-by-conv-key
                  "decknix-agent-tags-mutate"
                  (conv-key tags workspace))
(declare-function decknix--agent-register-session-id
                  "decknix-agent-tags-mutate"
                  (conv-key session-id))

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
  ;; PR B.81: persist-decision + ring-first-message are pinned by
  ;; `decknix-agent-workspace-persist' (carved, +14 ERT).  This
  ;; function is the comint/event-side adapter that performs hook
  ;; installation, ring access, and the prompt-ready subscription.
  (let ((buf (current-buffer)))
    ;; Stash workspace + install comint hook (covers new sessions).
    (with-current-buffer buf
      (let* ((ws (or decknix--agent-session-workspace
                     default-directory))
             (decision (decknix--workspace-persist-decision
                        ws
                        decknix--agent-workspace-persisted
                        decknix--agent-pending-workspace)))
        (when (eq (plist-get decision :action) 'install)
          (let ((stash (plist-get decision :stash)))
            (when stash
              (setq-local decknix--agent-pending-workspace stash)))
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
                              (and ring (ring-p ring)
                                   (decknix--workspace-ring-first-message
                                    (ring-length ring)
                                    (lambda (idx) (ring-ref ring idx))))))
                        (when first-msg
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
      ;; Rename immediately — the buffer exists now.  Buffer-name
      ;; format is pinned by `decknix--post-create-buffer-name'
      ;; (PR B.83).
      (with-current-buffer shell-buf
        (rename-buffer
         (generate-new-buffer-name
          (decknix--post-create-buffer-name name)))
        (setq-local shell-maker--buffer-name-override
                    (buffer-name))
        (when workspace
          (setq-local decknix--agent-session-workspace workspace)))
      ;; Persist metadata.  The immediate-vs-deferred dispatch is
      ;; pinned by `decknix--post-create-flush-mode' (PR B.83):
      ;;   immediate              -> conv-key handoff + setq-local
      ;;   deferred-with-metadata -> stash + comint input-filter hook
      ;;   deferred-no-metadata   -> only the prompt-ready subscription
      ;; Whichever branch runs, we ALWAYS subscribe to prompt-ready
      ;; below to capture the session-id once ACP bootstrap finishes.
      (let* ((conv-key (when first-message
                         (decknix--agent-conversation-key first-message)))
             (mode (decknix--post-create-flush-mode
                    conv-key tags workspace)))
        (pcase mode
          ('immediate
           (when (or tags workspace)
             (decknix--agent-store-metadata-by-conv-key
              conv-key tags workspace))
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
          ('deferred-with-metadata
           ;; Stash pending metadata and wire the one-shot
           ;; input-filter hook that will flush it once the user
           ;; submits their first message.
           (with-current-buffer shell-buf
             (setq-local decknix--agent-pending-tags tags)
             (setq-local decknix--agent-pending-workspace workspace)
             (add-hook 'comint-input-filter-functions
                       #'decknix--agent-flush-pending-metadata
                       nil t)))
          ('deferred-no-metadata nil))
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
