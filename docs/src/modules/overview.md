# Modules Overview

Decknix is organised into modular components, each responsible for a specific area of your environment. Every module uses `lib.mkDefault` so you can override any setting.

## Module Categories

### Home-Manager Modules

| Module | Description | Page |
|--------|-------------|------|
| **Emacs** | Full IDE with 13+ sub-modules, profiles, daemon | [Emacs →](./emacs.md) |
| **Vim** | Whitespace cleanup, skim fuzzy finder | [Vim →](./vim.md) |
| **Shell & Terminal** | Zsh, Starship prompt, completions | [Shell →](./shell.md) |
| **Git** | Delta diffs, global config, LFS | [Git →](./git.md) |
| **Window Management** | AeroSpace, Hammerspoon, Spaces | [WM →](./window-management.md) |
| **AI Tooling** | Augment Code agent, MCP servers, Agent Shell | [AI →](./ai/overview.md) |

### Darwin (System) Modules

| Module | Description |
|--------|-------------|
| **System Defaults** | Packages (vim, git, curl, skim), Nerd Fonts, Dock/Finder prefs |
| **AeroSpace System** | Disables Stage Manager, Mission Control shortcuts, separate Spaces |
| **Emacs Daemon** | Background Emacs service via launchd, `ec` wrapper command |
| **CLI Module** | Installs `decknix` binary, generates extensions config |

### Core Options

| Option | Description | Default |
|--------|-------------|---------|
| `decknix.role` | Bootstrap template: `"developer"`, `"designer"`, `"minimal"` | `"developer"` |
| `decknix.username` | Your macOS username (set automatically by mkSystem) | — |
| `decknix.hostname` | Machine hostname | — |

## Editor Profiles

Instead of toggling individual modules, choose a profile tier:

### Emacs Profiles

| Profile | Modules Included |
|---------|-----------------|
| `minimal` | core, completion, editing, UI, undo, project |
| `standard` | minimal + development, magit, treemacs, languages, welcome |
| `full` *(default)* | standard + LSP, org-mode, HTTP client, agent-shell |
| `custom` | Disables framework Emacs — bring your own config |

### Vim Profiles

| Profile | Modules Included |
|---------|-----------------|
| `minimal` | Base config (exrc, line numbers, secure) |
| `standard` *(default)* | minimal + whitespace + skim |
| `custom` | Disables framework Vim — bring your own config |

```nix
# Change profiles
{ ... }: {
  decknix.editors.emacs.profile = "standard";
  decknix.editors.vim.profile = "minimal";
}
```

## Default Packages

Installed for all users regardless of role:

`coreutils` · `curl` · `wget` · `tree` · `jq` · `ripgrep` · `gh`

System-level: `vim` · `git` · `curl` · `skim`

Fonts: **JetBrains Mono Nerd Font**

