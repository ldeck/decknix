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

The largest module (~2600 lines). Key subsystems:

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

### Context Panel
- Tracks GitHub issues, PRs, CI status, review threads.
- Collapsible header-line summary.
- `C-c i` prefix for context commands.

### Key Prefix Map

| Prefix | Purpose |
|--------|---------|
| `C-c A` | Agent commands (global) |
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
| `C-c A T` | Tags — global (list/filter conversations, rename, delete, cleanup) |
| `C-c T` | Tags — conversation-scoped (show, add, remove) — in-buffer only (#78) |
| `C-c D` | Deckmacs — framework management (reload, status, diff, log) (#85) |
| `C-c D r` | Reload default.el from current Nix profile; `C-u` to force |
| `C-c D s` | Show framework status (loaded/current store paths, staleness) |
| `C-c D d` | Show diff between loaded and current store paths |
| `C-c D l` | Show reload history log |
| `C-c i` | Context panel (in agent-shell buffers) |

### Planned Features

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
- Batch compose: `C-c C-c` submit, `C-c C-k` cancel
- Always add `which-key` labels for new prefix maps

