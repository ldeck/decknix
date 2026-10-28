# decknix

**Opinionated Nix framework for macOS** — batteries-included configuration for individuals and teams.

[![Documentation](https://img.shields.io/badge/docs-mdBook-blue)](https://ldeck.github.io/decknix/)

Combines [Nix Flakes](https://wiki.nixos.org/wiki/Flakes), [nix-darwin](https://github.com/LnL7/nix-darwin), and [home-manager](https://github.com/nix-community/home-manager) with sensible defaults and a 3-layer override system.

## Quick Start

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ldeck/decknix/main/bin/bootstrap.sh)"
```

Or with an existing Nix installation:

```bash
mkdir -p ~/.config/decknix && cd ~/.config/decknix
nix flake init -t github:ldeck/decknix
$EDITOR settings.nix   # Set username, hostname
sudo nix run nix-darwin -- switch --flake .#default --impure   # first activation installs the decknix CLI
decknix switch         # every later change
```

## What's Included

| Category | Highlights |
|----------|-----------|
| **Editors** | Emacs (full IDE, 17 modules, agent-shell), Vim |
| **Shell** | Zsh, Starship prompt, syntax highlighting |
| **Git** | Delta diffs, Magit, Forge (GitHub PRs) |
| **Dev Tools** | ripgrep, jq, curl, gh CLI, language servers |
| **Window Manager** | AeroSpace, Hammerspoon or OmniWM (all opt-in) |
| **AI Tooling** | Opt-in agent CLIs (Claude Code, Pi, Gemini, Codex, OpenCode, Goose, Qwen, Auggie), Gortex code graph, agent-sync for skills and commands |
| **CLI** | `decknix switch`, `update`, `wt`, `session`, `repos`, extensible subcommands |

## How It Works

```
┌───────────────────────────────────────┐
│  Personal Overrides                   │  ~/.config/decknix/local/
├───────────────────────────────────────┤
│  Organisation Configs                 │  Flake inputs (versioned repos)
├───────────────────────────────────────┤
│  Decknix Framework                    │  github:ldeck/decknix
└───────────────────────────────────────┘
```

Every framework default uses `lib.mkDefault` — your preferences always win.

## Documentation

📖 **[Full documentation →](https://ldeck.github.io/decknix/)**

| Section | Description |
|---------|-------------|
| [Getting Started](https://ldeck.github.io/decknix/getting-started/installation.html) | Installation and first build |
| [Architecture](https://ldeck.github.io/decknix/architecture/overview.html) | 3-layer model, config loader |
| [Configuration](https://ldeck.github.io/decknix/configuration/settings.html) | Settings, overrides, secrets |
| [Modules](https://ldeck.github.io/decknix/modules/overview.html) | Emacs, Vim, Shell, Git, WM, AI |
| [CLI Reference](https://ldeck.github.io/decknix/cli/overview.html) | Core commands, extensions |
| [Guides](https://ldeck.github.io/decknix/guides/org-configs.html) | Org configs, development, troubleshooting |

## Key Commands

```bash
decknix switch              # Apply configuration
decknix switch --dry-run    # Build without activating
decknix switch --override decknix=~/path/to/decknix   # Test local framework changes
decknix update              # Update all flake inputs
decknix wt list             # List worktrees in the registry
decknix wt refresh          # Re-probe worktrees and update cache
decknix wt prune            # Expunge stale worktrees (full sweep)
decknix wt clean            # Remove old merged worktrees
ec filename                 # Open file in Emacs
```

## License

MIT
