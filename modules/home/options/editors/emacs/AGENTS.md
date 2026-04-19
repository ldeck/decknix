# AI Agent Guidelines — Emacs Modules

> Emacs-specific conventions for AI agents. Read the root `AGENTS.md` first.

## Architecture

The Emacs configuration is split into independent Nix modules, each generating
Elisp into a shared `default.el` that is byte-compiled and native-compiled at
Nix build time.

### Module Map

| Module | Purpose |
|--------|---------|
| `default.nix` | Core settings, theme, daemon config, `exec-path-from-shell` |
| `agent-shell.nix` | Augment AI agent integration (sessions, compose, context) |
| `completion.nix` | Vertico, Consult, Corfu, Orderless, Embark |
| `magit.nix` | Git via Magit, Forge, code-review |
| `ui.nix` | which-key, helpful, nerd-icons |
| `languages.nix` | 30+ language modes |
| `lsp.nix` | Eglot, language servers, DAP debugging |
| `deckmacs.nix` | Framework management — hot-reload, status, diagnostics (#85) |
| Others | editing, undo, org, treemacs, http, welcome, project |

### Daemon (`modules/darwin/emacs.nix`)

- Runs as a launchd user agent (`org.nixos.emacs-server`)
- Uses `bin/emacs --fg-daemon` (not `Emacs.app` — avoids macOS quit dialogs)
- `ProcessType = "Background"` in the plist
- GUI frames via `emacsclient -c`; `ec` wrapper auto-starts daemon

## Critical: Dynamic Binding in `default.el`

**`default.el` is evaluated under dynamic binding** (no `;;; -*- lexical-binding: t -*-`).
This means lambdas do NOT capture enclosing variables as closures.

### The Pattern

When you need a closure (timers, sentinels, callbacks), use:

```elisp
;; WRONG — variables are unbound when the lambda runs:
(let ((name "foo"))
  (run-at-time 1 nil (lambda () (message "Hello %s" name))))

;; CORRECT — eval with t flag creates a lexical closure:
(let ((name "foo"))
  (run-at-time 1 nil
    (eval `(lambda () (message "Hello %s" ,name)) t)))
```

**Exception**: Lambda parameters (e.g., `proc` and `_event` in a process
sentinel) are always bound by the lambda itself — the pattern is only needed
for captured *outer* variables.

## Package Sourcing

```
Priority: stable nixpkgs → unstable nixpkgs → custom derivations
```

- Packages from `pkgs.unstable.emacsPackages` must be rebuilt via
  `pkgs.emacsPackages.trivialBuild` to ensure native-compiled `.eln` files
  match the daemon's Emacs build hash. See the `agent-shell.nix` header.
- Custom packages use `pkgs.emacsPackages.trivialBuild` with local source.

## Agent Shell Module (`agent-shell.nix`)

The largest module (~4400 lines). Key subsystems:

### Session Management
- **Session picker** (`C-c A s`): Uses `consult--multi` with sectioned groups
  (like `C-x b`): **Live Sessions** → **Saved Sessions** → **New**. Each section
  has a horizontal divider. Live sessions show workspace + tags; current buffer
  is excluded. Saved sessions read `~/.augment/sessions/*.json` via parallel
  `jq`, cached with 2-min TTL, pre-fetched on daemon start. Default view is
  **conversation-collapsed** (one row per conversation). `C-u C-c A s` expands
  to show all individual session snapshots.
- **Conversation identity**: Derived by hashing `firstUserMessage` (SHA-256,
  truncated to 16 chars). Provides stable identity across resumed sessions (#78).
- **Session creation** (`C-c A n`): Guided flow — workspace dir, name, tags.
  Passes `--workspace-root` to auggie CLI via closure (survives deferred
  `:client-maker` invocation).
- **Session close** (`C-c A q` / `C-c s q`): Kills the buffer. If other live
  sessions exist, switches to the next one (or opens the picker if multiple).
  If last session, returns to the welcome screen or `*scratch*`.
- **Session resume**: Restores history into comint buffer. Buffer is renamed
  to `*Auggie: <name>*` using tags (if any) or first-message preview, matching
  the naming convention of new sessions. **Workspace is restored** from
  `agent-sessions.json` — passes `--workspace-root` to auggie CLI and sets
  `default-directory` so the agent operates in the original project directory.
- **Workspace persistence**: Workspace directory is stored per conversation in
  `~/.config/decknix/agent-sessions.json` alongside tags. Saved on session
  creation, restored on resume.
- **Model persistence** (`C-c C-v`): The global default model for new sessions
  is configured via `decknix.cli.auggie.settings.model` (written to
  `~/.augment/settings.json`). When the user picks a different model mid-session
  with `C-c C-v`, the choice is persisted against the conversation in
  `agent-sessions.json`. On resume, that override is passed to auggie as
  `--model <id>` so the session continues on the same model.

### Quick Actions
- **PR review** (`C-c A c r`): DWIM workflow — prompts for GitHub PR URL
  (defaults to clipboard), workspace, and session name. Parses `owner/repo/number`
  from URL (lightweight, no `gh` CLI). Auto-generates name (`pr-<repo>-<number>`)
  and tags (`review`, `<repo>`). Creates session and auto-sends
  `/review-service-pr <url>` once the process is ready.
- **Batch process** (`C-c A c B`): Opens a compose editor for launching multiple
  sessions. Uses `---` grouping syntax:
  ```
  --- <group-name> [: <workspace>]
  <url>
  <url>
  ```
  Lines within a `---` group share a single session. Ungrouped lines each get
  their own session. `C-c C-c` to launch, `C-c C-k` to cancel.
- **Batch compose mode**: Minor mode (`decknix-batch-compose-mode`) with
  font-lock for `---` dividers, GitHub URLs, and `#` comments. Header-line
  shows keybindings.
- **Summary buffer**: `*Batch Launch*` shows ✓/✗ per session after batch launch.
- Built on reusable `decknix--agent-quickaction-start` — any future quick action
  (e.g., investigate-issue) follows the same pattern: name + tags + workspace +
  auto-send command.

### Compose Editor
- Decoupled input buffer (sticky or transient mode).
- Header-line shows available keys with `C-c` prefix factored out.
- `which-key` labels for all sub-maps including the `k` (interrupt) prefix.
- **History navigation**: `M-p`/`M-n` cycle through the **current session's**
  prompts only (from `comint-input-ring`). `M-P`/`M-N` (shifted) cycle through
  **all sessions** (current first, then on-demand from saved session files).
- **Interrupt-and-submit** (`C-c k C-c`): Interrupts the agent, then submits
  the compose buffer after a 0.3s delay. The compose buffer stays visible until
  the submit fires (not closed prematurely).

### Unified Header-Line
Every agent-shell buffer displays a persistent header-line combining:
1. **Status icon + label** — `● ready`, `◐ working`, `◉ waiting`,
   `✔ finished`, `○ initializing`, `✕ killed`. Color-coded (green/yellow/red/cyan).
   Uses `agent-shell-workspace`'s rich detection when available, falls back to
   `shell-maker--busy`.
2. **Session tags** — from `agent-sessions.json`, shown as `#tag1 #tag2`.
3. **Workspace path** — abbreviated (e.g., `~/tools/decknix`).
4. **Context panel items** — issues, PRs, CI, reviews (when context module enabled).

Auto-refreshed every 2 seconds via a buffer-local timer. Detects `working → ready`
transitions and shows `✔ finished` until the user views the buffer.

The `decknix--context-update-header` function delegates to the unified header
(`decknix--header-update`) so context data is always incorporated.

### Context Panel
- Tracks GitHub issues, PRs, CI status, review threads.
- Data is rendered as part of the unified header-line (merged, not standalone).
- `C-c i` prefix for context commands.

### Hub Integration (`decknix-hub`)
- Surfaces data from the `decknix-hub` background daemon in the workspace
  sidebar — zero Emacs CPU overhead (all polling happens in the Rust daemon).
- **Requests** section: PR reviews assigned to me, ordered oldest first.
  Shows age (color-coded: 3d+ = red, <3d = yellow), repo, PR number, CI
  status icon (✓/✗/⟳), and title. `RET` opens the PR in the browser.
- **WIP** section: My open PRs grouped by repository, with CI status and
  branch names. `RET` opens the PR in the browser.
- Data is read from `~/.config/decknix/hub/` JSON files via
  `file-notify-add-watch` on the directory — sidebar refreshes the instant
  any hub file changes.
- Header-line shows review count: `⚡3 reviews`.
- Controlled by `programs.agent-shell.decknix.hub.enable` (default: true).
- Requires `decknix.services.hub.enable = true` in the darwin config to run
  the background daemon. See `modules/darwin/hub.nix` for service options.
- Future adapters (Jira, TeamCity, Slack) will add more sidebar sections
  reading from additional JSON files in the same hub directory.

### Workspace (`agent-shell-workspace`)
- Dedicated `Agents` tab-bar tab with buffer isolation (`C-c w` to toggle).
- Sidebar sections (top to bottom): **Requests** → **WIP** → **Live** →
  **Recent** → **Keys/Toggles** footer.
- Agent management: `c` new, `k` kill, `r` restart, `R` rename, `d` delete killed.
- Tiling controls: `a a` add, `a x` remove.
- Toggles transient (`T`): Opens sectioned menu grouped by sidebar section:
  - **Global**: `W` width, `O` org filter
  - **Requests**: `F` age, `C` ci, `@` mention, `B` bots
  - **Live**: `E` PRs (4-way cycle: off/PR/pipeline/both), `S` quick-switch,
    `t` tile, `d` display mode, `H` hidden, `y` symbol style (ascii/emoji),
    `N` repo-name cap (short/medium/full)
  - **WIP**: `P` pipeline/deploy indicators, `L` hide linked (PRs that are
    already live as sessions)
- All toggles are advertised in the sidebar footer (press `K` to hide).  When
  the sidebar is wide (≥48 cols), Global+Requests and Live+WIP sections
  render side-by-side so the footer does not push content off-screen.
- Session ops prefix (`s`): `s s` picker, `s g` grep, `s r` recent.
- Auto-refreshes every 2 seconds (live sessions) plus instant refresh on hub
  file changes.

### Attention (`agent-shell-attention`)
- Global mode-line indicator `AS:n/m` showing pending/active session counts.
- `C-c j` jumps to the next session needing user input.
- `C-u C-c j` prompts with a completion list of all active sessions (annotated
  with Awaiting/Permissions/Running status).
- `C-u C-u C-c j` opens a tabulated dashboard of all agent-shell buffers.
- Tracks status via advice on `agent-shell--send-command` and
  `agent-shell--on-request` — no custom process sentinels needed.

### Multi-Session Concurrency
Multiple agent-shell sessions run **independently and concurrently**. Each
buffer has its own process. Switching away from a session does NOT pause it —
the agent continues working in the background. The attention indicator and
workspace sidebar surface which sessions need attention.

### Inline Review (`decknix-agent-review-mode`)
- Derived from `markdown-mode`. Captures the last exchange (prompt +
  response) from an agent session into a `*agent-review: <name>*` buffer
  with a read-only preamble describing the Option-1 reply contract.
- Entry points: `C-c A v` / `C-c v` in a session buffer, or `v` on a live
  row in the workspace sidebar (also reachable via `a v`). Prefix arg
  captures the full history instead of just the last exchange.
- Annotation snippets (yasnippet, `,` prefix, TAB to expand):
  `,c` comment, `,a` approve, `,r` reject, `,o` option, `,A` agent reply,
  `,m` mention (consult-style picker over persisted collaborators),
  `,f` follow-up. Identity resolves via `user-login-name`; collaborators
  are persisted to `~/.config/decknix/review-collaborators.el`.
- Follow-up stash: `C-c C-f` flags the paragraph near point and records a
  JSON entry in `~/.config/decknix/review-followups.json` with id, ts,
  session, workspace, author, title, and status. `C-c C-l` lists stashed
  items via completing-read with sub-actions `[d]one / [o]pen / [x]delete
  / [c]opy-id`.
- Submit/route (`C-c C-c`): `a` sends back to the source agent-shell
  (reusing compose's busy-prompt interrupt/queue dance), `p` copies to
  the kill-ring for PR comments, `j` writes a draft under
  `~/.config/decknix/review-jira-drafts/`, `f` saves to a user-chosen
  path. `q` cancels. The agent route strips the `🧭 review meta` header
  but preserves the `📋 instructions` block.

### Key Prefix Map

| Prefix | Purpose |
|--------|---------|
| `C-c A` | Agent commands (global) |
| `C-c A b` | Switch agent buffer — live buffers only, MRU ordered (#96) |
| `C-c A s` | Session picker (sectioned: Live / Saved / New); `C-u` for all snapshots (#77) |
| `C-c A g` | Grep sessions — consult + ripgrep full-text search across all session content; `C-u` for all snapshots |
| `C-c A n` | New session |
| `C-c A q` | Quit/close session (switch to next or welcome) |
| `C-c A c` | Commands — quick actions and custom commands |
| `C-c A c r` | Review PR (quick action) |
| `C-c A c B` | Batch process (multi-session launcher) |
| `C-c A c c` | Run custom command (pick & insert) |
| `C-c A c n` | New custom command |
| `C-c A c e` | Edit custom command |
| `C-c A w` | Toggle Agents workspace tab (tab-bar with sidebar) |
| `C-c A j` | Jump to next session needing attention; `C-u` to pick, `C-u C-u` dashboard |
| `C-c A v` | Review last exchange (inline review buffer); `C-u` for full history |
| `C-c A T` | Tags — global (list/filter conversations, rename, delete, cleanup) |
| `C-c T` | Tags — conversation-scoped (show, add, remove) — in-buffer only (#78) |
| `C-c D` | Deckmacs — framework management (reload, status, diff, log) (#85) |
| `C-c D r` | Reload default.el from current Nix profile; `C-u` to force |
| `C-c D s` | Show framework status (loaded/current store paths, staleness) |
| `C-c D d` | Show diff between loaded and current store paths |
| `C-c D l` | Show reload history log |
| `C-c b` | Switch agent buffer — live buffers only (#96) |
| `C-c i` | Context panel (in agent-shell buffers) |
| `C-c w` | Toggle Agents workspace (in-buffer shortcut) |
| `C-c j` | Jump to pending session (in-buffer shortcut) |
| `C-c v` | Review last exchange (in-buffer shortcut for `C-c A v`) |
| `C-c C-c` | Route review (review-mode only) |
| `C-c C-f` | Flag paragraph as follow-up (review-mode only) |
| `C-c C-l` | List stashed follow-ups (review-mode only) |

### Planned Features

- **Sub-agent tree** — Show spawned sub-agents as children in sidebar (#95) (Planned)
- **Hub: Slack adapter** — Unread mentions requiring follow-up (Planned)
- **Hub: Cross-linking** — Associate sessions with work items (reviews, tasks) (Planned)
- **Hub: Expandable Recent** — Expand a saved session to see related work items (Planned)
- **Hub: macOS notifications** — New review requests, CI failures (Planned)
- **Worktree-aware sessions** — git worktree per agent session (#69) (Planned)
- **Session board** — magit-style multi-session dashboard (#70) (Planned)
- **Session templates** — engineering, review, support workflows (#71) (Planned)
- **Automation** — push notifications, auto-created sessions (#72) (Planned)
- **Full I/O decoupling** — hide comint prompt, read-only output (#67) (Planned)

## Keybinding Conventions

- Global agent prefix: `C-c A` (capital A)
- Framework prefix: `C-c D` (capital D — Deckmacs)
- Module-local prefix: `C-c <lowercase>` (e.g., `C-c i` for context)
- Compose mode: `C-c C-c` submit, `C-c k` interrupt sub-map, `C-c C-s` toggle
- Compose history: `M-p`/`M-n` local (current session), `M-P`/`M-N` global (all sessions)
- Batch compose: `C-c C-c` submit, `C-c C-k` cancel
- Always add `which-key` labels for new prefix maps

