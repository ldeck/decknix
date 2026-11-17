# Modules Overview

Decknix is organised into modular components, each responsible for a specific area of your environment. Every module uses `lib.mkDefault` so you can override any setting.

## Module Categories

### Home-Manager Modules

| Module | Description | Page |
|--------|-------------|------|
| **Emacs** | Full IDE with 17 sub-modules, profiles, daemon | [Emacs →](./emacs.md) |
| **Vim** | Whitespace cleanup, skim fuzzy finder | [Vim →](./vim.md) |
| **Shell & Terminal** | Zsh, Starship prompt, completions | [Shell →](./shell.md) |
| **Git** | Delta diffs, global config, LFS | [Git →](./git.md) |
| **Window Management** | AeroSpace, Hammerspoon, OmniWM, Spaces (all opt-in) | [WM →](./window-management.md) |
| **AI Tooling** | Opt-in agent CLIs (Claude Code, Pi, Antigravity, Codex, OpenCode, Goose, Qwen, Auggie), Gortex, agent-sync, Agent Shell | [AI →](./ai/overview.md) |
| **Apps** | Ungoogled Chromium from nix-casks (on by default on macOS) | |
| **CLI helpers** | `repo-jdk`, `board`, GitHub token for Nix (`nix-github-auth`) | [CLI →](../cli/extensions.md) |

### Darwin (System) Modules

| Module | Description |
|--------|-------------|
| **System Defaults** | Packages (vim, git, curl, skim, nix-open), Nerd Fonts, Nix settings, Dock/Finder prefs |
| **AeroSpace System** | Disables Stage Manager, Mission Control shortcuts, separate Spaces |
| **Emacs Daemon** | Background Emacs service via launchd, `ec` wrapper command |
| **CLI Module** | Installs `decknix` binary, generates extensions config |
| **Linux Builder** | On-demand aarch64-linux builder VM, stopped when idle ([Linux Builder](./linux-builder.md)) |
| **decknix Hub** | Background work-item aggregator (GitHub, Jira, TeamCity), off by default ([Hub](../guides/decknix-hub.md)) |
| **Repo Sync** | Fast-forwards workspace clones every 3h, on by default ([Services](./services.md)) |
| **Session GC** | Weekly agent session archiving, on by default ([Services](./services.md)) |
| **IAP Proxy** | Local IAP-authenticating proxies, off by default ([Services](./services.md)) |

### Core Options

| Option | Description | Default |
|--------|-------------|---------|
| `decknix.role` | `"developer"`, `"designer"` or `"minimal"`. Currently has no effect on the build | `"minimal"` (`mkSystem` passes `"developer"` unless `settings.nix` sets `role`) |
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

`coreutils` · `curl` · `wget` · `tree` · `jq` · `yq-go` · `ripgrep` · `gh`

System-level: `vim` · `git` · `curl` · `skim` · `nix-open`

Fonts: **JetBrains Mono Nerd Font**

