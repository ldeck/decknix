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
- **Session picker** (`C-c A s`): Reads `~/.augment/sessions/*.json` directly
  via parallel `jq`, cached with 2-min TTL, pre-fetched on daemon start.
- **Session creation** (`C-c A n`): Guided flow — workspace dir, name, tags.
  Passes `--workspace-root` to auggie CLI.
- **Session resume**: Restores history into comint buffer.

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
| `C-c A s` | Session picker |
| `C-c A n` | New session |
| `C-c A t` | Tag management |
| `C-c i` | Context panel (in agent-shell buffers) |

### Planned Features

- **Worktree-aware sessions** — git worktree per agent session (#69) (Planned)
- **Session board** — magit-style multi-session dashboard (#70) (Planned)
- **Session templates** — engineering, review, support workflows (#71) (Planned)
- **Automation** — push notifications, auto-created sessions (#72) (Planned)
- **Full I/O decoupling** — hide comint prompt, read-only output (#67) (Planned)

## Keybinding Conventions

- Global agent prefix: `C-c A` (capital A)
- Module-local prefix: `C-c <lowercase>` (e.g., `C-c i` for context)
- Compose mode: `C-c C-c` submit, `C-c k` interrupt sub-map, `C-c C-s` toggle
- Always add `which-key` labels for new prefix maps

