;;; decknix-agent-shell-main-session.el --- Session lifecycle: cache, picker, search, resume, new/quit/recent -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix

;;; Commentary:
;;
;; The session lifecycle layer of agent-shell.  Owns the buffer-local
;; var family that every agent-shell buffer carries
;; (`-auggie-session-id', `-conv-key', `-session-workspace',
;; `-workspace-persisted', `-pending-tags', `-pending-workspace'), the
;; consult--multi picker sources (Live / Previous / Saved / New), the
;; ripgrep + jq full-text grep, the session-resume primitive with
;; jump-to-match, the workspace-persistence auto-hook, and the four
;; interactive session-management commands (`new', `quit', `recent',
;; `history') plus the agent-buffer switcher and the Context-history
;; timeline navigation commands.
;;
;; PR Split.S.5: split out of `decknix-agent-shell-main' so the
;; ~2275-line bulk file can be navigated by theme.  Co-resident with
;; the main file in `main-bulk/'.  All pure layers
;; (`decknix-agent-session-{cache,history,format,group}',
;; `decknix-agent-{grep-format,conv-{format,resolve,recency,hidden},
;; tags-{store,read,mutate},session-{workspace,model,id},
;; jump-target,resume-command,input-ring,workspace-detect,
;; workspace-persist,rg-search-command,post-create,
;; quickaction-window,context-history}') already live in their own
;; carved + ERT-tested packages.  This file owns the side-effecting
;; orchestration: agent-shell startup, comint ring mutation, consult
;; dynamic collection, agent-shell-start invocation, post-create
;; renaming, and prompt-ready event wiring.  Side-effecting
;; `(define-key)' bindings into the heredoc's prefix maps still
;; happen in the heredoc itself (per AGENTS.md Rule 2).
;;
;; Forward-declarations for symbols defined in carved packages, in
;; `decknix-agent-shell-main' proper, or in the heredoc are kept at
;; the head of the file so the original structure of the bulk file
;; is preserved when reading the body below.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'comint)

;; Forward declarations for upstream agent-shell + shell-maker + consult.
(declare-function agent-shell-start "ext:agent-shell")
(declare-function agent-shell-buffers "ext:agent-shell")
(declare-function agent-shell-subscribe-to "ext:agent-shell")
(declare-function agent-shell--make-acp-client "ext:agent-shell")
(declare-function agent-shell--state "ext:agent-shell")
(declare-function shell-maker-submit "ext:shell-maker")
(declare-function consult--multi "ext:consult")
(declare-function consult--read "ext:consult")
(declare-function consult--dynamic-collection "ext:consult")
(defvar agent-shell-display-action)
(defvar shell-maker--buffer-name-override)
(defvar shell-maker--config)
(defvar decknix--sidebar-previous-sessions)

(defvar decknix-agent-session-history-count 2
  "Default number of recent exchanges to show when resuming a session.
Use C-u prefix with the session picker to override.")

;; Provider abstraction.
(require 'decknix-agent-provider)
(declare-function decknix-agent-require-provider "decknix-agent-provider")
(declare-function decknix-agent-provider-select "decknix-agent-provider")
(declare-function decknix--agent-command-build "decknix-agent-provider")
(declare-function decknix--agent-make-config "decknix-agent-provider")
(defvar decknix-agent-default-provider)

;; Forward declarations for sibling decknix carved packages used by
;; the session lifecycle.  Mirrors the cluster at the top of
;; `decknix-agent-shell-main' so this split file byte-compiles
;; clean independently.
(declare-function decknix-welcome "ext:decknix-welcome")
(declare-function decknix--sidebar-previous-dedupe
                  "ext:decknix-agent-shell-workspace")
(declare-function decknix--sidebar-restore-previous-session
                  "ext:decknix-agent-shell-workspace" (entry interactive))
(declare-function agent-shell-workspace-sidebar-refresh
                  "ext:decknix-agent-shell-workspace")
(declare-function decknix--session-delete-by-id
                  "decknix-sidebar-row-actions" (sid conv-key))

;; Carved pure helpers consumed by the session lifecycle.  Each
;; mirrors a `decknix-agent-*' package required by the heredoc
;; before this file is loaded; the declares below keep the
;; byte-compile clean even when the heredoc evaluation order
;; changes between Nix builds.
(declare-function decknix--agent-session-parse "decknix-agent-parse")
(declare-function decknix--prompt-extract-from-file "decknix-agent-parse")
(declare-function decknix--agent-conversation-key
                  "decknix-agent-conv-resolve" (first-message))
(declare-function decknix--agent-conv-touch
                  "decknix-agent-conv-recency" (conv-key))
(declare-function decknix--agent-session-list "decknix-agent-session-cache")
(declare-function decknix--agent-session-ensure-jq-filter
                  "decknix-agent-session-cache")
(declare-function decknix--agent-session-file
                  "decknix-agent-session-history" (session-id))
(declare-function decknix--agent-session-extract-history
                  "decknix-agent-session-history" (session-id n))
(declare-function decknix--agent-session-extract-all-turns
                  "decknix-agent-session-history" (session-id))
(declare-function decknix--agent-session-find-turn-containing
                  "decknix-agent-session-history" (turns regexp))
(declare-function decknix--agent-context-find-existing
                  "decknix-agent-context-history")
(declare-function decknix--agent-context-render-window
                  "decknix-agent-context-history" (cursor))
(declare-function decknix--agent-session-prepopulate
                  "decknix-agent-context-history"
                  (session-id n))
(declare-function decknix--agent-session-preview
                  "decknix-agent-session-format" (session))
(declare-function decknix--agent-session-display-name
                  "decknix-agent-session-format" (session))
(declare-function decknix--agent-session-derive-name
                  "decknix-agent-session-format"
                  (tags &optional workspace branch first-message sid))
(declare-function decknix--agent-session-group-by-conversation
                  "decknix-agent-session-group"
                  (sessions &optional include-hidden))
(declare-function decknix--agent-session-live-label
                  "decknix-agent-session-group" (buf))
(declare-function decknix--agent-session-grep-build-entries
                  "decknix-agent-grep-format" (sessions expand))
(declare-function decknix--agent-conversation-preview
                  "decknix-agent-conv-format" (conv-group))
(declare-function decknix--agent-buffer-session-id
                  "decknix-agent-buffer-lookup" (buf))
(declare-function decknix--agent-find-new-shell-buffer
                  "decknix-agent-buffer-lookup" (before))
(declare-function decknix--agent-find-live-buffer-for-conv-key
                  "decknix-agent-buffer-lookup" (conv-key))
(declare-function decknix--session-conv-id "decknix-agent-buffer-lookup")
(declare-function decknix--agent-workspace-for-conv-key
                  "decknix-agent-session-workspace" (conv-key))
(declare-function decknix--agent-session-save-workspace-for-conv-key
                  "decknix-agent-session-workspace" (conv-key workspace))
(declare-function decknix--agent-tags-for-conv-key
                  "decknix-agent-tags-read" (conv-key))
(declare-function decknix--agent-tags-all "decknix-agent-tags-read")
(declare-function decknix--agent-flush-pending-metadata
                  "decknix-agent-tags-mutate" (input))
(declare-function decknix--agent-store-metadata-by-conv-key
                  "decknix-agent-tags-mutate"
                  (conv-key tags workspace))
(declare-function decknix--agent-register-session-id
                  "decknix-agent-tags-mutate"
                  (conv-key session-id))
(declare-function decknix--agent-session-model-for-conv-key
                  "decknix-agent-session-model" (conv-key))
(declare-function decknix--agent-detect-workspace
                  "decknix-agent-workspace-detect")
(declare-function decknix--agent-detect-branch
                  "decknix-agent-workspace-detect" (dir))
(defvar decknix-agent-workspace-roots)
(declare-function decknix--workspace-persist-decision
                  "decknix-agent-workspace-persist"
                  (workspace persisted-p pending))
(declare-function decknix--workspace-ring-first-message
                  "decknix-agent-workspace-persist"
                  (ring-len ring-ref-fn))
(declare-function decknix--input-ring-required-size
                  "decknix-agent-input-ring" (current needed))
(declare-function decknix--input-ring-insertion-order
                  "decknix-agent-input-ring" (prompts))
(declare-function decknix--jump-target-resolve
                  "decknix-agent-jump-target" (buffer-hit cache-idx count))
(declare-function decknix--resume-command-build
                  "decknix-agent-resume-command"
                  (base-cmd workspace model session-id))
(declare-function decknix--rg-fast-command
                  "decknix-agent-rg-search-command" (rg term dir))
(declare-function decknix--rg-paths-to-id-set
                  "decknix-agent-rg-search-command" (paths))
(declare-function decknix--rg-thorough-command
                  "decknix-agent-rg-search-command" (rg term dir jqf))
(declare-function decknix--post-create-buffer-name
                  "decknix-agent-post-create" (name))
(declare-function decknix--post-create-flush-mode
                  "decknix-agent-post-create"
                  (conv-key tags workspace))
(declare-function decknix--header-status-icon
                  "decknix-agent-header" (status))
(declare-function decknix--header-status-face
                  "decknix-agent-header" (status))
(declare-function agent-shell-workspace--buffer-status
                  "ext:agent-shell-workspace" (buffer))
(declare-function decknix--quickaction-window-is-sidebar-p
                  "decknix-agent-quickaction-window"
                  (window-side dedicated-p buf-name sidebar-buf))
(declare-function decknix--quickaction-target-window
                  "decknix-agent-quickaction-window"
                  (cur-is-sidebar cur main))
(declare-function decknix--quit-pick-replacement
                  "decknix-agent-quickaction-window"
                  (mru-other-bufs visible-bufs))
(declare-function decknix-picker-selections-coerce
                  "decknix-picker-selections" (raw))
(declare-function decknix-picker-selections-cand-key
                  "decknix-picker-selections" (cand))
;; Carved bulk-send planner (agent-shell/session-bulk-send/).
(declare-function decknix--session-bulk-send-plan
                  "decknix-agent-session-bulk-send" (bufs busy-fn))
;; Compose primitives (main-bulk sibling; resolved via heredoc load-order).
(declare-function decknix--compose-enqueue-prompt
                  "decknix-agent-shell-main-compose" (target input))
(declare-function decknix--compose-submit-after-wait
                  "decknix-agent-shell-main-compose" (target input))

;; Carved-package state vars consumed by this file.  Their values
;; live in the carved modules; the defvar below keeps the byte-
;; compiler happy in this file.
(defvar decknix--agent-session-cache)
(defvar decknix--agent-session-cache-time)
(defvar decknix--agent-session-cache-ttl)
(defvar decknix--agent-session-refresh-proc)
(defvar decknix--agent-sessions-dir)
(defvar decknix--agent-session-jq-filter-file)

;; Buffer-local timeline cache + cursor for the Context section.
;; Defined by `decknix-agent-context-history' (PR B.68); declared
;; here so the paging commands below byte-compile clean.
(defvar decknix--agent-history-cache)
(defvar decknix--agent-history-cursor)


;; == Session management: unified picker + clean quit ==

;; Buffer-local var to track the auggie CLI session ID
;; (distinct from ACP session ID in agent-shell--state)
(defvar-local decknix--agent-auggie-session-id nil
  "The auggie CLI session ID for this buffer, if known.")

;; Buffer-local var to track the agent provider ID (symbol)
(defvar-local decknix--agent-provider-id nil
  "The provider ID (symbol) for this agent session.")


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
(declare-function decknix--agent-session-derive-name
                  "decknix-agent-session-format"
                  (tags &optional workspace branch first-message sid))

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
;; Phase 1.3: provider lookup by session-id and label accessor
(declare-function decknix--agent-provider-for-session-id
                  "decknix-agent-session-cache" (session-id))
(declare-function decknix-agent-provider-label "decknix-agent-provider" (id))
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
         ;; Phase 1.3: look up the backend that created this session
         ;; from the cache (providerId is stamped at parse time).
         ;; Falls back to `decknix-agent-default-provider' for old
         ;; cache entries that pre-date the Phase 1.3 stamp.
         (provider (decknix--agent-provider-for-session-id session-id))
         (augmented-cmd
          (decknix--agent-command-build
           provider validated-ws saved-model session-id))
         (config (decknix--agent-make-config provider augmented-cmd))
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
                   (setq-local decknix--agent-provider-id ',provider)
                   (setq-local decknix--agent-auggie-session-id ,sid)
                   ;; Store conv-key for fast tag lookup in header-line
                   (when ,ck
                     (setq-local decknix--agent-conv-key ,ck))
                   ;; Restore workspace for the session picker display
                   (when ,ws
                     (setq-local decknix--agent-session-workspace ,ws))
                   ;; Rename buffer to match conversation identity.
                   ;; Phase 1.3: use provider label so Claude sessions
                   ;; show "*Claude: ...*" instead of "*Auggie: ...*".
                   (when ,bname
                     (let ((lbl (decknix-agent-provider-label ',provider)))
                       (rename-buffer
                        (generate-new-buffer-name
                         (format "*%s: %s*" lbl ,bname)))
                       (setq-local shell-maker--buffer-name-override
                                   (buffer-name))))
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
                     (progn
                       (let ((win (get-buffer-window shell-buf)))
                         (when (and win (window-live-p win))
                           (set-window-point win (point-max))))
                       ;; Hint: context is collapsed; tell the user
                       ;; how to open the viewer without them needing
                       ;; to ask "Where were we?"
                       (when decknix--agent-history-cache
                         (message
                          "Context restored (%d turns) — press C-c s c to view previous interactions"
                          (length decknix--agent-history-cache))))))
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

;; Multi-select support: C-SPC marks candidates (via embark-select)
;; and RET confirms.  A captured-selections var holds embark's list;
;; a multi-mode flag suppresses the single-select :action so the
;; unified dispatch handler can iterate all marked items instead.
(defcustom decknix-agent-picker-hide-live-backed t
  "Hide saved sessions whose conversation is currently live in the picker.
When non-nil (default), the Saved Sessions section omits entries whose
conv-key matches a live buffer — those conversations are already shown in
the Live Sessions section and duplicating them adds noise.
Set to nil to always show all saved sessions."
  :type 'boolean
  :group 'decknix)

(defvar decknix--session-picker-captured-selections nil
  "Embark-captured candidate strings from the current picker invocation.
Populated by the minibuffer-exit-hook in `decknix-agent-session-picker'
when the user marks candidates with C-SPC.  Reset at the start of each
picker call so stale values from a previous invocation never leak.")

(defvar decknix--session-picker-multi-mode nil
  "Non-nil while multi-select post-processing runs in the session picker.
Each source's :action lambda is a no-op when this flag is set;
`decknix--session-picker-dispatch' iterates the captured selections
instead, routing each candidate to the correct restore/resume action.")

(defvar decknix--session-picker-action nil
  "Special action to perform on the selected candidate(s) after the picker exits.
One of nil (open/resume — normal behaviour), `kill', `delete', or `send'.
Reset to nil at the start of each picker call.  Set by the C-k / C-d / C-s
key bindings wired inside `decknix-agent-session-picker's setup hook.")

(defvar decknix--session-picker-workspace-filter nil
  "Workspace path to restrict the session picker's Saved/Previous sections.
When nil (default) all workspaces are shown.  When set to a directory
path string, only sessions whose recorded workspace is a prefix-match
of (or equal to) this path are shown.  Toggled by M-w inside the
picker; persists across re-opens so the filter survives the close-and-
reopen cycle triggered by the toggle.")

(defvar decknix--session-picker-current-ws nil
  "Workspace of the buffer that invoked the session picker, or `default-directory'.
Captured at `decknix-agent-session-picker' call time; used as the
M-w cycle target so the filter snaps to the caller's context.")

(defvar decknix--session-picker-reopen nil
  "When non-nil, `decknix-agent-session-picker' re-invokes itself on exit.
Set by the M-w workspace-filter toggle; cleared immediately before the
recursive call so only one level of re-entry occurs.")

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
          ;; No-op during multi-select: dispatch handles all items.
          (unless decknix--session-picker-multi-mode
            (when cand
              (let ((buf (gethash cand decknix--session-picker-live-map)))
                (when (and buf (buffer-live-p buf))
                  ;; Select main window first so the buffer doesn't
                  ;; try to display in the dedicated sidebar window.
                  (let ((main (window-main-window (selected-frame))))
                    (when (and main (window-live-p main))
                      (select-window main)))
                  (switch-to-buffer buf)))))))
  "Consult multi-source for live agent-shell buffers.")

(defvar decknix--session-source-saved
  (list :name     "Saved Sessions"
        :narrow   ?s
        :category 'agent-session-saved
        :face     'consult-file
        :items
        (lambda ()
          (let* (;; Compute live conv-keys so we can hide saved sessions
                 ;; that duplicate a conversation already in Live section.
                 (live-bufs
                  (seq-filter #'buffer-live-p
                              (when (fboundp 'agent-shell-buffers)
                                (agent-shell-buffers))))
                 (live-conv-keys
                  (when decknix-agent-picker-hide-live-backed
                    (delq nil
                          (mapcar (lambda (b)
                                    (with-current-buffer b
                                      (and (bound-and-true-p decknix--agent-conv-key)
                                           decknix--agent-conv-key)))
                                  live-bufs))))
                 ;; Filter the session list: when hide-live-backed is on and
                 ;; there are live conversations, drop sessions whose conv-key
                 ;; is already open in a live buffer.
                 (sessions
                  (let ((all (decknix--agent-session-list)))
                    (if live-conv-keys
                        (seq-filter
                         (lambda (session)
                           (let* ((first-msg (alist-get 'firstUserMessage session ""))
                                  (ck (decknix--agent-conversation-key first-msg)))
                             (not (member ck live-conv-keys))))
                         all)
                      all)))
                 ;; Workspace filter: when set, only show sessions whose
                 ;; recorded workspace path matches the filter (exact or prefix).
                 (ws-filter decknix--session-picker-workspace-filter)
                 (ws-filter-true (when ws-filter
                                   (ignore-errors (file-truename ws-filter))))
                 (sessions
                  (if (null ws-filter-true) sessions
                    (seq-filter
                     (lambda (session)
                       (let* ((first-msg (alist-get 'firstUserMessage session ""))
                              (ck (decknix--agent-conversation-key first-msg))
                              (ws (when ck
                                    (decknix--agent-workspace-for-conv-key ck)))
                              (ws-true (when ws
                                         (ignore-errors (file-truename ws)))))
                         (and ws-true
                              (string-prefix-p ws-filter-true ws-true))))
                     sessions)))
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
          ;; No-op during multi-select: dispatch handles all items.
          (unless decknix--session-picker-multi-mode
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
                         workspace conv-key))))))))))
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
          ;; No-op during multi-select: dispatch handles all items.
          (unless decknix--session-picker-multi-mode
            (when cand
              (let ((entry (gethash cand decknix--session-picker-previous-map)))
                (when entry
                  (decknix--sidebar-restore-previous-session entry t)))))))
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

(defun decknix--session-picker-dispatch (cand)
  "Route CAND to the correct restore/resume action based on source maps.
Used by the multi-select path in `decknix-agent-session-picker' to
process each embark-marked candidate after the picker exits.  Checks
the three source lookup tables in priority order: live → previous →
saved.  Falls through to `decknix-agent-session-new' for unrecognised
candidates (e.g., the New section placeholder).

CAND arrives as the propertized 161-char consult--multi candidate
(160-char display string + a trailing `consult-strip' char), so the
canonical 160-char key the :items lambda used to build each
hash-table is extracted via `decknix-picker-selections-cand-key'
before any lookup -- otherwise every `gethash' silently misses on
the off-by-one tail and RET appears to do nothing."
  (let ((key (decknix-picker-selections-cand-key cand)))
    (cond
     ;; Live session: switch to buffer (without focus on non-first items).
     ((and decknix--session-picker-live-map
           (gethash key decknix--session-picker-live-map))
      (let ((buf (gethash key decknix--session-picker-live-map)))
        (when (and buf (buffer-live-p buf))
          (let ((main (window-main-window (selected-frame))))
            (when (and main (window-live-p main))
              (select-window main)))
          (switch-to-buffer buf))))
     ;; Previous session: restore without auto-focus (caller manages it).
     ((and decknix--session-picker-previous-map
           (gethash key decknix--session-picker-previous-map))
      (let ((entry (gethash key decknix--session-picker-previous-map)))
        (when entry
          (decknix--sidebar-restore-previous-session entry nil))))
     ;; Saved session: resume without prompting for workspace on multi-pick.
     ((and decknix--session-picker-saved-map
           (gethash key decknix--session-picker-saved-map))
      (let* ((session (gethash key decknix--session-picker-saved-map))
             (workspace (alist-get '__workspace session)))
      (when session
        (let ((conv-key (decknix--agent-conversation-key
                         (alist-get 'firstUserMessage session ""))))
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
               workspace conv-key))))))))))

;; -- Session-picker action helpers (C-k kill, C-d delete) --
;;
;; These operate on the candidate list captured by the picker's
;; minibuffer-exit-hook after C-k or C-d exits the minibuffer.
;; `decknix--session-picker-kill-cands'  — kill live buffer(s).
;; `decknix--session-picker-delete-cands' — delete saved/previous sessions.
;; `decknix--session-picker-do-action'   — routes to either helper.

(defun decknix--session-picker-kill-cands (cands)
  "Kill live session buffer(s) for candidates CANDS.
Resolves each candidate key against `decknix--session-picker-live-map'.
Non-live candidates are skipped.  Prompts once (single: `Kill session?';
multiple: `Kill N sessions?') before touching any buffer."
  (let* ((bufs (delq nil
                     (mapcar
                      (lambda (cand)
                        (let ((key (decknix-picker-selections-cand-key cand)))
                          (and decknix--session-picker-live-map
                               (gethash key decknix--session-picker-live-map))))
                      cands)))
         (live (seq-filter #'buffer-live-p bufs))
         (n (length live)))
    (if (null live)
        (message "No live sessions in selection — use C-d to delete saved sessions")
      (when (yes-or-no-p
             (format "Kill %d live session%s? " n (if (= 1 n) "" "s")))
        (dolist (buf live)
          (kill-buffer buf))
        (message "Killed %d session%s" n (if (= 1 n) "" "s"))))))

(defun decknix--session-picker-delete-cands (cands)
  "Permanently delete saved/previous sessions for candidates CANDS.
Live candidates are refused with an explanatory message.  Resolves each
candidate key against `decknix--session-picker-previous-map' and
`decknix--session-picker-saved-map', collecting (SID . CONV-KEY) pairs.
Prompts once before touching anything, then calls
`decknix--session-delete-by-id' for each session and refreshes the sidebar."
  (let ((deletable nil)
        (live-count 0))
    ;; Pass 1: categorise candidates
    (dolist (cand cands)
      (let ((key (decknix-picker-selections-cand-key cand)))
        (cond
         ;; Live: refuse
         ((and decknix--session-picker-live-map
               (gethash key decknix--session-picker-live-map))
          (cl-incf live-count))
         ;; Previous session
         ((and decknix--session-picker-previous-map
               (gethash key decknix--session-picker-previous-map))
          (let ((entry (gethash key decknix--session-picker-previous-map)))
            (push (cons (alist-get 'session-id entry)
                        (alist-get 'conv-key entry))
                  deletable)))
         ;; Saved session
         ((and decknix--session-picker-saved-map
               (gethash key decknix--session-picker-saved-map))
          (let* ((session (gethash key decknix--session-picker-saved-map))
                 (sid (alist-get 'sessionId session))
                 (conv-key (decknix--agent-conversation-key
                            (alist-get 'firstUserMessage session ""))))
            (when sid
              (push (cons sid conv-key) deletable)))))))
    ;; Report live refusals
    (when (> live-count 0)
      (message "%d live session%s skipped — kill %s first with C-k"
               live-count
               (if (= 1 live-count) "" "s")
               (if (= 1 live-count) "it" "them")))
    ;; Pass 2: confirm + delete
    (when deletable
      (let ((n (length deletable)))
        (when (yes-or-no-p
               (format "Permanently delete %d session%s? "
                       n (if (= 1 n) "" "s")))
          (dolist (pair deletable)
            (when (fboundp 'decknix--session-delete-by-id)
              (decknix--session-delete-by-id (car pair) (cdr pair))))
          (when (fboundp 'agent-shell-workspace-sidebar-refresh)
            (agent-shell-workspace-sidebar-refresh))
          (message "Deleted %d session%s" n (if (= 1 n) "" "s")))))))

;; == Bulk-send action: C-s in the session picker ==
;;
;; Resolves marked live-session candidates to buffers, then opens a
;; *Bulk Send* compose buffer.  The user types the prompt there and
;; confirms with C-c C-c.  Idle sessions receive the prompt immediately
;; via `decknix--compose-submit-after-wait'; busy sessions are queued
;; via `decknix--compose-enqueue-prompt' so they fire when ready.
;; The pure partition logic lives in the carved
;; `decknix-agent-session-bulk-send' package (session-bulk-send/).

(defvar-local decknix--session-bulk-send-targets nil
  "List of target agent-shell buffers for this bulk-send compose buffer.")

(defvar decknix-session-bulk-send-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'decknix--session-bulk-send-submit)
    (define-key map (kbd "C-c C-k") #'decknix--session-bulk-send-cancel)
    map)
  "Keymap for `decknix-session-bulk-send-mode'.")

(define-minor-mode decknix-session-bulk-send-mode
  "Minor mode for the *Bulk Send* compose buffer.
C-c C-c dispatches the buffer contents to all target sessions.
C-c C-k cancels without sending."
  :lighter " [Bulk]"
  :keymap decknix-session-bulk-send-mode-map)

(defun decknix--session-bulk-send-submit ()
  "Send the compose buffer content to all target sessions.
Idle sessions get an immediate submit; busy sessions are queued."
  (interactive)
  (let* ((bufs decknix--session-bulk-send-targets)
         (text (string-trim
                (buffer-substring-no-properties (point-min) (point-max)))))
    (if (string-empty-p text)
        (message "Empty prompt — nothing sent")
      (decknix--session-bulk-dispatch bufs text)
      (kill-buffer (current-buffer)))))

(defun decknix--session-bulk-send-cancel ()
  "Cancel the bulk-send compose buffer without sending."
  (interactive)
  (kill-buffer (current-buffer))
  (message "Bulk send cancelled"))

(defun decknix--session-bulk-dispatch (bufs input)
  "Dispatch INPUT to each live buffer in BUFS via the bulk-send planner.
Idle buffers receive an immediate submit; busy buffers are queued via
the compose-queue polling timer.  Reports the counts after dispatch."
  (when bufs
    (let* ((plan (decknix--session-bulk-send-plan
                  bufs
                  (lambda (buf)
                    (with-current-buffer buf
                      (and (fboundp 'shell-maker--busy)
                           (shell-maker--busy))))))
           (send-now (plist-get plan :send-now))
           (to-queue (plist-get plan :enqueue))
           (sent 0)
           (queued 0))
      (dolist (buf send-now)
        (decknix--compose-submit-after-wait buf input)
        (cl-incf sent))
      (dolist (buf to-queue)
        (decknix--compose-enqueue-prompt buf input)
        (cl-incf queued))
      (message "Bulk send: %d sent immediately, %d queued" sent queued))))

(defun decknix--session-bulk-send-open-compose (bufs)
  "Open a *Bulk Send* compose buffer for BUFS.
The buffer activates `decknix-session-bulk-send-mode'; C-c C-c sends,
C-c C-k cancels."
  (let* ((n (length bufs))
         (buf (get-buffer-create "*Bulk Send*")))
    (with-current-buffer buf
      (erase-buffer)
      (setq-local decknix--session-bulk-send-targets bufs)
      (decknix-session-bulk-send-mode 1))
    (let ((win (display-buffer buf
                               '(display-buffer-at-bottom
                                 . ((window-height . 0.3))))))
      (when (window-live-p win)
        (select-window win)))
    (message "Bulk send to %d session%s — C-c C-c to send, C-c C-k to cancel"
             n (if (= 1 n) "" "s"))))

(defun decknix--session-picker-send-cands (cands)
  "Resolve CANDS to live buffers and open the bulk-send compose buffer.
Non-live candidates (saved/previous sessions) are skipped with a note;
bulk send requires a running agent process to dispatch to."
  (let* ((live-bufs
          (delq nil
                (mapcar
                 (lambda (cand)
                   (let ((key (decknix-picker-selections-cand-key cand)))
                     (and decknix--session-picker-live-map
                          (let ((buf (gethash key
                                              decknix--session-picker-live-map)))
                            (and buf (buffer-live-p buf) buf)))))
                 cands)))
         (skipped (- (length cands) (length live-bufs))))
    (when (> skipped 0)
      (message "Skipping %d non-live candidate%s (bulk send targets live sessions)"
               skipped (if (= 1 skipped) "" "s")))
    (if (null live-bufs)
        (message "No live sessions selected — C-SPC mark live sessions, then C-s")
      (decknix--session-bulk-send-open-compose live-bufs))))

(defun decknix--session-picker-do-action (action cands)
  "Perform ACTION on CANDS from the session picker.
ACTION is one of `kill' (kill live buffers), `delete' (permanently
remove saved/previous sessions from disk and metadata), or `send'
(bulk-send a prompt to the selected live sessions).  CANDS is the
list of candidate strings captured by the picker's minibuffer-exit-hook."
  (pcase action
    ('kill   (decknix--session-picker-kill-cands cands))
    ('delete (decknix--session-picker-delete-cands cands))
    ('send   (decknix--session-picker-send-cands cands))
    (_ (message "Unknown session-picker action: %s" action))))

(defun decknix-agent-session-picker (arg)
  "Pick from live agent-shell buffers and saved auggie sessions.
Sections are separated by dividers (like `consult-buffer' / C-x b):
  Live Sessions     — currently running agent buffers (most recent first)
  Previous          — sessions that were live before last restart (greyed)
  Saved Sessions    — past conversations from ~/.augment/sessions
  New               — start a new session (fallback)

Press RET to open the highlighted session.  Press C-SPC to mark
candidates (multi-select) and RET to open all of them at once.

In-picker action keys (work on the highlighted item or all C-SPC marks):
  M-w  — Toggle workspace filter: cycles between all workspaces and the
          workspace of the buffer that opened the picker.  The picker
          closes and reopens immediately with the new scope; the filter
          label appears in the prompt (e.g. \"[~/projects/foo]\").
  C-k  — Kill the live session buffer(s).  Prompts for confirmation.
          Non-live candidates are ignored.
  C-d  — Permanently delete saved/previous session(s) from disk and
          metadata.  Live sessions are refused; kill them first with C-k.
  C-s  — Bulk-send a prompt to the selected live session(s).  Opens a
          *Bulk Send* compose buffer: type the prompt, then C-c C-c to
          dispatch (idle sessions submit immediately, busy ones are
          queued).  C-c C-k cancels.  Only live sessions are targeted.

Saved sessions whose conversation already has a live buffer are hidden
by default (controlled by `decknix-agent-picker-hide-live-backed').

By default, saved sessions are collapsed by conversation.
With \\[universal-argument], shows all individual session snapshots."
  (interactive "P")
  (require 'consult)
  (setq decknix--session-picker-expand arg)
  (setq decknix--session-picker-captured-selections nil)
  (setq decknix--session-picker-multi-mode nil)
  (setq decknix--session-picker-action nil)
  (setq decknix--session-picker-reopen nil)
  ;; Capture current workspace at invocation time as M-w cycle target.
  ;; Use the buffer-local session workspace if available; fall back to
  ;; default-directory.  Stored into decknix--session-picker-current-ws
  ;; so the M-w handler can reference it even after focus moves to the
  ;; minibuffer.
  (setq decknix--session-picker-current-ws
        (expand-file-name
         (or (and (bound-and-true-p decknix--agent-session-workspace)
                  (file-exists-p decknix--agent-session-workspace)
                  decknix--agent-session-workspace)
             default-directory)))
  (let ((setup-fn
         (lambda ()
           ;; Wire C-SPC → embark-select so the user can mark candidates.
           (when (fboundp 'embark-select)
             (local-set-key (kbd "C-SPC") 'embark-select))
           ;; M-w: cycle workspace filter (all workspaces ↔ current workspace).
           ;; Because consult--multi builds static candidate lists, we close
           ;; the picker and reopen it; the filter persists via its defvar so
           ;; re-entry immediately applies the new scope.
           (local-set-key (kbd "M-w")
             (lambda () (interactive)
               (setq decknix--session-picker-workspace-filter
                     (if decknix--session-picker-workspace-filter
                         nil
                       decknix--session-picker-current-ws))
               (setq decknix--session-picker-reopen t)
               (exit-minibuffer)))
           ;; Wire C-k → kill-action, C-d → delete-action, C-s → send-action.
           ;; All three set multi-mode (suppresses the normal :action lambdas)
           ;; and exit the minibuffer; the minibuffer-exit-hook below then
           ;; captures the highlighted candidate into captured-selections.
           (local-set-key (kbd "C-k")
             (lambda () (interactive)
               (setq decknix--session-picker-action 'kill)
               (setq decknix--session-picker-multi-mode t)
               (exit-minibuffer)))
           (local-set-key (kbd "C-d")
             (lambda () (interactive)
               (setq decknix--session-picker-action 'delete)
               (setq decknix--session-picker-multi-mode t)
               (exit-minibuffer)))
           (local-set-key (kbd "C-s")
             (lambda () (interactive)
               (setq decknix--session-picker-action 'send)
               (setq decknix--session-picker-multi-mode t)
               (exit-minibuffer)))
           ;; Capture selections BEFORE completing-read unwinds.
           ;; Embark returns `(TYPE . CANDS)' — the coerce helper strips the
           ;; leading symbol.  When an action key (C-k/C-d) was used without
           ;; first marking with C-SPC, capture the currently highlighted
           ;; candidate via `vertico--candidate' (internal but widely used by
           ;; embark itself; guarded with fboundp + ignore-errors for safety).
           (add-hook 'minibuffer-exit-hook
             (lambda ()
               (when (fboundp 'embark-selected-candidates)
                 (let* ((raw (embark-selected-candidates))
                        (sels (decknix-picker-selections-coerce raw)))
                   (when sels
                     (setq decknix--session-picker-multi-mode t)
                     (setq decknix--session-picker-captured-selections sels))))
               ;; C-k / C-d without C-SPC marks: capture the current candidate.
               (when (and decknix--session-picker-action
                          (null decknix--session-picker-captured-selections))
                 (let ((cur (and (fboundp 'vertico--candidate)
                                 (ignore-errors (vertico--candidate)))))
                   (when cur
                     (setq decknix--session-picker-captured-selections
                           (list cur))))))
             nil t))))
    (minibuffer-with-setup-hook setup-fn
      (consult--multi (list decknix--session-source-live
                            decknix--session-source-previous
                            decknix--session-source-saved
                            decknix--session-source-new)
                      :prompt (format "Agent session%s%s (M-w ws; C-SPC mark; C-k kill, C-d delete, C-s send): "
                                      (if arg " (all snapshots)" "")
                                      (if decknix--session-picker-workspace-filter
                                          (format " [%s]"
                                                  (abbreviate-file-name
                                                   decknix--session-picker-workspace-filter))
                                        ""))
                      :sort nil)))
  ;; Reopen after M-w workspace filter toggle: loop back into the picker
  ;; with the new filter already set.  Capture the flag first, then clear
  ;; it to prevent double-reopen if something goes wrong.
  (let ((reopen decknix--session-picker-reopen))
    (setq decknix--session-picker-reopen nil)
    (if reopen
        (decknix-agent-session-picker arg)
      ;; Multi-select / action-mode post-processing:
      ;; When multi-mode is set (C-SPC multi-select, C-k kill, or C-d delete),
      ;; the :action lambdas were suppressed (no-op) and we route every captured
      ;; candidate through either the action handler or the normal dispatch.
      (when decknix--session-picker-multi-mode
        (setq decknix--session-picker-multi-mode nil)
        (let ((sels decknix--session-picker-captured-selections)
              (action decknix--session-picker-action))
          (setq decknix--session-picker-captured-selections nil)
          (setq decknix--session-picker-action nil)
          (if action
              (decknix--session-picker-do-action action sels)
            (dolist (cand sels)
              (decknix--session-picker-dispatch cand))))))))

;; == Agent buffer switch: C-c b (in-buffer) / C-c A b (global) ==
;; Like C-x b but scoped to live agent-shell buffers only.
;; Uses consult for live narrowing when available, else completing-read.
;; Excludes the current buffer; sorted by MRU. (#96)
;;
;; Each candidate is prefixed with the same status icon used by the
;; unified header-line and the workspace sidebar's Live section (●/◐/◉
;; etc., coloured by `decknix--header-status-face') so it stays obvious
;; which sessions are working / awaiting permission / idle without
;; having to switch into them.

(defun decknix--agent-switch-buffer--status-prefix (buf)
  "Return a coloured status-icon prefix for live buffer BUF.
Falls back to two spaces when the upstream status helper or the
header icon/face helpers aren't loaded yet (build-time stubbing,
early daemon start) so the column stays aligned regardless."
  (let ((status (and (fboundp 'agent-shell-workspace--buffer-status)
                     (buffer-live-p buf)
                     (ignore-errors
                       (agent-shell-workspace--buffer-status buf)))))
    (if (and status
             (fboundp 'decknix--header-status-icon)
             (fboundp 'decknix--header-status-face))
        (concat (propertize (decknix--header-status-icon status)
                            'face (decknix--header-status-face status))
                " ")
      "  ")))

(defun decknix--agent-switch-buffer--decorated-label (buf)
  "Build a status-decorated picker label for live buffer BUF."
  (concat (decknix--agent-switch-buffer--status-prefix buf)
          (decknix--agent-session-live-label buf)))

(defun decknix-agent-switch-buffer ()
  "Switch to another live agent-shell buffer.
Like \\[switch-to-buffer] but showing only agent-shell buffers.
Excludes the current buffer.  Most-recently-used ordering is
preserved from `agent-shell-buffers' and forced through the
completion UI via `display-sort-function = identity', so vertico /
consult don't re-sort the candidates alphabetically.  Each entry is
prefixed with the same status icon shown in the header-line and the
sidebar's Live section."
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
          (let ((label (decknix--agent-switch-buffer--decorated-label buf)))
            (puthash label buf ht)
            (push label candidates)))
        (setq candidates (nreverse candidates))
        (let* ((table
                (lambda (string pred action)
                  (if (eq action 'metadata)
                      '(metadata
                        (category . agent-shell-buffer)
                        (display-sort-function . identity)
                        (cycle-sort-function . identity))
                    (complete-with-action action candidates string pred))))
               (chosen (completing-read "Agent buffer: " table nil t))
               (buf (gethash chosen ht)))
          (when (and buf (buffer-live-p buf))
            (switch-to-buffer buf))))))))

;; == Session grep: consult + ripgrep full-text search ==
;; Searches ALL content (user messages, agent responses, code blocks)
;; across every session JSON file using ripgrep.
;; C-c A g — type a search term, results narrow live.

(defun decknix--agent-session-rg-search-fast (term &optional provider-id)
  "Find sessions matching TERM via rg + the in-memory metadata cache.
If PROVIDER-ID is nil, searches all registered providers."
  (if (null provider-id)
      (let ((all-results nil))
        (dolist (provider-entry decknix-agent-provider-registry)
          (setq all-results (append all-results
                                    (decknix--agent-session-rg-search-fast term (car provider-entry)))))
        (sort all-results (lambda (a b)
                            (string> (alist-get 'modified a "") (alist-get 'modified b "")))))
    (let* ((rg (or (executable-find "rg") "rg"))
           (dir (decknix-agent-provider-sessions-dir provider-id))
           (cmd (decknix--rg-fast-command rg term dir))
           (output "")
           (proc (make-process
                  :name (format "agent-grep-%s-rg-fast" provider-id)
                  :buffer nil
                  :command (list "sh" "-c" cmd)
                  :noquery t
                  :connection-type 'pipe
                  :filter (lambda (_p o)
                            (setq output (concat output o))))))
      (while (process-live-p proc)
        (accept-process-output proc 0.03))
      (accept-process-output proc 0)
      (let* ((paths (split-string output "\0" t))
             (id-set (decknix--rg-paths-to-id-set paths))
             (all-cached (decknix--agent-session-list provider-id)))
        (seq-filter (lambda (s)
                      (gethash (alist-get 'sessionId s) id-set))
                    all-cached)))))

(defun decknix--agent-session-rg-search-thorough (term &optional provider-id)
  "Search session files for TERM using ripgrep + parallel jq.
If PROVIDER-ID is nil, searches all registered providers."
  (if (null provider-id)
      (let ((all-results nil))
        (dolist (provider-entry decknix-agent-provider-registry)
          (setq all-results (append all-results
                                    (decknix--agent-session-rg-search-thorough term (car provider-entry)))))
        (sort all-results (lambda (a b)
                            (string> (alist-get 'modified a "") (alist-get 'modified b "")))))
    (let* ((jqf (decknix--agent-session-ensure-jq-filter provider-id))
           (dir (shell-quote-argument (decknix-agent-provider-sessions-dir provider-id)))
           (ext (decknix-agent-provider-session-file-extension provider-id))
           (jq-args (if (string= ext ".jsonl") "-Mcs" "-Mc"))
           (rg (or (executable-find "rg") "rg"))
           ;; Thorough path: build a pipeline that feeds rg matches into jq.
           (cmd (format "%s -l0 %s %s 2>/dev/null | xargs -0 -P8 -I{} jq %s -f %s {} 2>/dev/null | jq -Msc 'sort_by(.modified) | reverse'"
                        (shell-quote-argument rg)
                        (shell-quote-argument term)
                        dir jq-args (shell-quote-argument jqf)))
           (output "")
           (proc (make-process
                  :name (format "agent-grep-%s-rg-thorough" provider-id)
                  :buffer nil
                  :command (list "sh" "-c" cmd)
                  :noquery t
                  :connection-type 'pipe
                  :filter (lambda (_p o)
                            (setq output (concat output o))))))
      (while (process-live-p proc)
        (accept-process-output proc 0.03))
      (accept-process-output proc 0)
      (decknix--agent-session-parse output))))

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
Prompts for workspace directory and initial tags.  The buffer name is
derived automatically via `decknix--agent-session-derive-name': tags
joined by '/' if any were supplied, else <dir>/<branch> from the chosen
workspace.  This matches the naming convention used when restoring saved
sessions, so live and resumed buffers are always consistently labelled.

With prefix argument QUICK, skip prompts and use defaults:
workspace = project root, no tags; name is still derived automatically."
  (interactive "P")
  (let* ((default-ws (decknix--agent-detect-workspace))
         (provider (if quick decknix-agent-default-provider
                     (decknix-agent-provider-select)))
         (workspace (if quick default-ws
                      (read-directory-name "Workspace: " default-ws nil t)))
         (workspace (expand-file-name workspace))
         (branch (decknix--agent-detect-branch workspace))
         (tags (unless quick
                 (let ((input (completing-read-multiple
                               "Tags (comma-separated): "
                               (decknix--agent-tags-all)
                               nil nil)))
                   (mapcar #'string-trim
                           (seq-remove #'string-empty-p input)))))
         (name (decknix--agent-session-derive-name tags workspace branch nil nil))
         (before-buffers (buffer-list))
         ;; Build an augmented command with --workspace-root.
         ;; We must capture this in a closure rather than using a let-binding
         ;; of agent-shell-auggie-acp-command, because the :client-maker
         ;; lambda is stored in agent-shell--state and called later
         ;; (when the first message is sent) — by which time a dynamic
         ;; let-binding would have expired.
         (augmented-cmd (decknix--agent-command-build provider workspace))
         (config (decknix--agent-make-config provider augmented-cmd)))
    ;; Set default-directory so agent-shell-cwd picks up the chosen
    ;; workspace instead of inheriting the calling buffer's directory
    ;; (which may be ~/ when invoked from the welcome screen).
    (let ((default-directory workspace))
      (agent-shell-start :config config))
    ;; Invalidate session cache so next picker is fresh
    (setq decknix--agent-session-cache-time 0)
    ;; Post-creation: rename buffer immediately, subscribe to prompt-ready for metadata
    (decknix--agent-session-new-post-create
     before-buffers name tags workspace nil provider)
    (message "Starting agent session \"%s\" in %s…" name workspace)))

(defun decknix-agent-session-fork ()
  "Start a new session forked from the current one.
Prompts for workspace (defaulting to the current session's workspace)
and tags pre-seeded with the current session's tags, so you can delete
unwanted tags and type new ones in a single step.

When called from outside an agent-shell buffer the defaults fall back
to `decknix--agent-detect-workspace' with no tags — identical to
calling `decknix-agent-session-new' interactively."
  (interactive)
  (let* ((src-conv-key (and (bound-and-true-p decknix--agent-conv-key)
                            decknix--agent-conv-key))
         (src-workspace (or (and (bound-and-true-p decknix--agent-session-workspace)
                                 (file-exists-p decknix--agent-session-workspace)
                                 decknix--agent-session-workspace)
                            (decknix--agent-detect-workspace)))
         (src-tags (when src-conv-key
                     (decknix--agent-tags-for-conv-key src-conv-key)))
         (provider (decknix-agent-provider-select))
         ;; Let the user also change the workspace.
         (workspace (expand-file-name
                     (read-directory-name "Workspace: " src-workspace nil t)))
         (branch (decknix--agent-detect-branch workspace))
         ;; Pre-seed the prompt with the source tags so the user can
         ;; delete unwanted ones and add new ones before confirming.
         (tags (let ((input (completing-read-multiple
                             "Tags (comma-separated): "
                             (decknix--agent-tags-all)
                             nil nil
                             (when src-tags
                               (mapconcat #'identity src-tags ",")))))
                 (mapcar #'string-trim
                         (seq-remove #'string-empty-p input))))
         (name (decknix--agent-session-derive-name tags workspace branch nil nil))
         (before-buffers (buffer-list))
         (augmented-cmd (decknix--agent-command-build provider workspace))
         (config (decknix--agent-make-config provider augmented-cmd)))
    (let ((default-directory workspace))
      (agent-shell-start :config config))
    (setq decknix--agent-session-cache-time 0)
    (decknix--agent-session-new-post-create
     before-buffers name tags workspace nil provider)
    (message "Forking session \"%s\" in %s…" name workspace)))

(defun decknix--agent-session-new-post-create
    (before-buffers name tags workspace &optional first-message provider-id)
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
        (setq-local decknix--agent-provider-id (or provider-id decknix-agent-default-provider))
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
recently used one that is not already on screen in another window
of the current frame, so a split-window view does not collapse
into two panes showing the same session.  Use `C-c A s' afterwards
to pick a different session.  If this was the last session,
returns to the welcome screen or *scratch*."
  (interactive)
  (unless (derived-mode-p 'agent-shell-mode)
    (user-error "Not in an agent-shell buffer"))
  (when (y-or-n-p "Quit this agent session? ")
    (let* ((buf (current-buffer))
           (this-win (selected-window))
           ;; Snapshot buffers visible in OTHER windows of the
           ;; current frame BEFORE the kill mutates window/buffer
           ;; layout.  Multi-frame setups stay independent: only
           ;; the current frame's panes are considered "visible".
           (visible-bufs
            (delq nil
                  (mapcar (lambda (w)
                            (unless (eq w this-win)
                              (window-buffer w)))
                          (window-list nil 'no-minibuffer))))
           ;; agent-shell-buffers is MRU-first; remove the buffer
           ;; being killed so the carved replacement picker only
           ;; sees the surviving candidates.
           (other-bufs (remq buf
                             (when (fboundp 'agent-shell-buffers)
                               (agent-shell-buffers))))
           ;; Pure pick: prefer the first MRU candidate not already
           ;; visible elsewhere; falls back to MRU head when every
           ;; candidate is already on screen.  Returns nil only
           ;; when no other live sessions exist.
           (replacement
            (decknix--quit-pick-replacement other-bufs visible-bufs)))
      (kill-buffer buf)
      (cond
       (replacement
        (switch-to-buffer replacement))
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
    ;; Build completion table with annotations (workspace + tags).
    ;; Use plain `completing-read' + embark-select (C-SPC) for multi-select,
    ;; matching the pattern in `decknix--hub-completing-read-with-mention-toggle'.
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
           captured-selections
           (setup-fn
            (lambda ()
              (when (fboundp 'embark-select)
                (local-set-key (kbd "C-SPC") 'embark-select))
              (add-hook 'minibuffer-exit-hook
                (lambda ()
                  (when (fboundp 'embark-selected-candidates)
                    (setq captured-selections
                          (embark-selected-candidates))))
                nil t)))
           (choice
            (condition-case nil
                (let ((completion-extra-properties
                       (list :annotation-function annotator)))
                  (minibuffer-with-setup-hook setup-fn
                    (completing-read
                     "Recent sessions (C-SPC=mark  RET=open): " table nil t)))
              (quit nil)))
           (selections
            (cond
             ((and captured-selections (consp captured-selections)
                   (> (length captured-selections) 0))
              captured-selections)
             ((and choice (not (string-empty-p choice)))
              (list choice))
             (t nil))))
      (dolist (selection selections)
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
                 name workspace conv-key)))))))))

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

(provide 'decknix-agent-shell-main-session)
;;; decknix-agent-shell-main-session.el ends here
