# Introduction

**Decknix** is an opinionated Nix framework for macOS configuration management. It combines [Nix Flakes](https://nixos.wiki/wiki/Flakes), [nix-darwin](https://github.com/LnL7/nix-darwin), and [home-manager](https://github.com/nix-community/home-manager) into a batteries-included system that's easy to customise and share across teams.

## Why Decknix?

- **One command to set up a Mac** — bootstrap installs Nix, nix-darwin, and your full dev environment
- **Layered configuration** — framework defaults → org/team configs → personal overrides
- **Everything in Nix** — editors, shell, git, window manager, CLI tools, AI tooling
- **Team-friendly** — org configs are versioned flake inputs that everyone shares
- **Easy to override** — every default uses `lib.mkDefault`, so your preferences always win

## What's Included

| Category | Highlights |
|----------|-----------|
| **Editors** | Emacs (full IDE with 13+ modules), Vim |
| **Shell** | Zsh with Starship prompt, completions, syntax highlighting |
| **Git** | Delta diffs, Magit, Forge (GitHub PRs from Emacs) |
| **Dev Tools** | ripgrep, jq, curl, gh CLI, language servers |
| **Window Manager** | AeroSpace tiling WM with fuzzy workspace picker |
| **AI Tooling** | Augment Code agent with declarative MCP config |
| **CLI** | `decknix switch`, `decknix update`, extensible subcommands |

## How This Documentation Is Organised

- **[Getting Started](./getting-started/installation.md)** — install and build your first configuration
- **[Architecture](./architecture/overview.md)** — understand the 3-layer model, config loader, and directory layout
- **[Configuration](./configuration/settings.md)** — customise settings, features, secrets, and org configs
- **[Modules](./modules/overview.md)** — explore every module: editors, shell, git, WM, AI
- **[CLI Reference](./cli/overview.md)** — core commands and the extension system
- **[Guides](./guides/org-configs.md)** — set up org configs for your team, develop the framework, troubleshoot

