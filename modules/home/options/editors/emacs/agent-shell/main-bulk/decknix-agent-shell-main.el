;;; decknix-agent-shell-main.el --- Always-loaded agent-shell core -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix

;;; Commentary:
;;
;; Always-loaded agent-shell core, originally extracted from
;; agent-shell.nix as a verbatim 254-form bulk in PR B-Bulk.3 and
;; subsequently sliced into the seven thematic sibling files under
;; `main-bulk/' via PR Split.S.1..S.7.  This file is now a near-pure
;; index module: it loads the siblings via the `(require ...)' calls
;; below in heredoc order, with each cluster fronted by a `;; == ... =='
;; header documenting which carved / sibling / upstream symbols the
;; sibling owns and which side-effects (define-key / add-hook /
;; advice-add / with-eval-after-load) stay in the heredoc per
;; AGENTS.md Rule 2.
;;
;; This module is loaded unconditionally -- there is no feature gate
;; for the core agent-shell setup.  Each sibling forward-declares
;; its own carved / sibling / upstream symbols at its own preamble,
;; so main.el itself carries no forward-declarations and references
;; no external symbols.  If a future caller is added back to main.el
;; (rather than to a sibling), declare its deps alongside the new
;; code rather than restoring a top-level block.

;;; Code:

;; == Tutorial: welcome message + help buffer ==
;;
;; PR B.64: the welcome-message renderer + the three help-buffer
;; commands (`-help-keys', `-help-tutorial', `-help-functions')
;; were carved into `decknix-agent-help' (`agent-shell/help/').
;; The advice that wires `decknix--agent-welcome-message' into
;; `agent-shell-auggie-make-agent-config' lives in the heredoc
;; (Rule 2: top-level side-effects stay in main).


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
;; Rule 2 because it side-effects on buffer init.

(provide 'decknix-agent-shell-main)
;;; decknix-agent-shell-main.el ends here
