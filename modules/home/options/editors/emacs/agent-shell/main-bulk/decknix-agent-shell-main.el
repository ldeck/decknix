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

;; == Custom commands + MCP listing + TAB dwim ==
;; Split into `decknix-agent-shell-main-misc' (PR Split.S.7).
;; Owns:
;;   - `decknix-agent-command-{run,new,edit}' (custom command CRUD;
;;     pure discovery layer was carved into
;;     `decknix-agent-command-discover' in PR B.46, this owns the
;;     interactive surfaces)
;;   - `decknix-agent-mcp-list' (renders ~/.augment/settings.json
;;     mcpServers in `*MCP Servers*')
;;   - `decknix--agent-tab-dwim' (TAB dispatch: yas field -> corfu
;;     complete -> yas expand -> completion-at-point)
;; The split file forward-declares the carved discovery layer and
;; the upstream yasnippet / corfu surfaces it consumes.  Side-
;; effecting `(define-key)' bindings (`C-c A c c' / `c n' / `c e'
;; for custom commands; `agent-shell-mode-hook' -> `local-set-key'
;; for TAB) still happen in the heredoc per AGENTS.md Rule 2.
(require 'decknix-agent-shell-main-misc)

;; == Quickaction primitive + PR review + PR/repo linking ==
;; Split into `decknix-agent-shell-main-link' (PR Split.S.6).
;; Owns:
;;   - `decknix--agent-quickaction-start' (reusable spawn-a-new-
;;     session-with-a-primed-first-message primitive)
;;   - `decknix-agent-review-pr' (the canonical quick action)
;;   - `decknix-agent-link-pr' / `-link-repo' / `-unlink-pr'
;;     (interactive linking commands that mutate the carved
;;     `decknix-agent-link-store' for the current conv-key)
;; The split file forward-declares the carved url-parse / clipboard
;; / link-store / vcs / quickaction-window / buffer-lookup helpers
;; and the sibling `decknix--agent-session-new-post-create'.  Side-
;; effecting `(define-key)' bindings (`C-c A c r' / `c l' / `c L'
;; / `c u') into the heredoc's prefix maps still happen in the
;; heredoc itself per AGENTS.md Rule 2.
(require 'decknix-agent-shell-main-link)

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

(provide 'decknix-agent-shell-main)
;;; decknix-agent-shell-main.el ends here
