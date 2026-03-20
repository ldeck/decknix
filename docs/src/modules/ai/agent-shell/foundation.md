# Foundation (Layer 1)

The foundation layer provides the core shell infrastructure that everything else builds on.

## Core Components

### shell-maker

The underlying comint-like buffer management library. Handles prompt rendering, input submission, scroll behaviour, and process lifecycle. Agent Shell inherits its robust terminal semantics.

### ACP (Augment Code Protocol)

The `acp` package implements the wire protocol between Emacs and the `auggie` CLI. Unlike HTTP-based integrations, ACP runs auggie as a subprocess — no server, no ports, no latency.

### agent-shell.el

The main interface package. Provides:
- Agent configuration and model selection
- Session lifecycle (start, interrupt, rename)
- Mode-line status display
- Buffer management

## Tiered Package Sourcing

Packages are sourced from the most stable channel available:

```
Priority 1: stable nixpkgs     → (nothing currently — all are too new)
Priority 2: unstable nixpkgs   → shell-maker, acp, agent-shell
Priority 3: custom derivations → agent-shell-manager, workspace, attention
```

Custom derivations use `trivialBuild` with pinned GitHub revisions and hashes:

```nix
agent-shell-manager-el = pkgs.emacsPackages.trivialBuild {
  pname = "agent-shell-manager";
  version = "0-unstable-2026-03-17";
  src = pkgs.fetchFromGitHub {
    owner = "jethrokuan";
    repo = "agent-shell-manager";
    rev = "53b73f1...";
    hash = "sha256-JPB/OnOhYbM0LMirSYQhpB6hW8SAg0Ri6buU8tMP7rA=";
  };
  packageRequires = [ agent-shell ];
};
```

As packages mature into nixpkgs, they'll migrate up the priority chain automatically.

## Default Behaviour

| Setting | Value | Why |
|---------|-------|-----|
| `agent-shell-preferred-agent-config` | `'auggie` | Skip agent selection prompt |
| `agent-shell-session-strategy` | `'new` | Always start fresh; session management via our picker |
| `agent-shell-header-style` | `'text` | Model/mode in mode-line, not graphical header |
| `agent-shell-show-session-id` | `t` | Show session ID for resume/history |

## Welcome Message

Every new session displays a custom welcome with a quick-reference keybinding card:

```
Welcome to Auggie (opus4.6, agent mode)
────────────────────────────────────────────────────
 Quick Reference

  C-c e     Compose     Open multi-line prompt editor
  C-c s     Sessions    Pick / resume / start session
  C-c q     Quit        Save and quit session
  C-c h     History     View conversation history
  C-c t t   Template    Insert a prompt template
  C-c c c   Command     Pick & insert a slash command
  C-c T t   Tag         Tag this session
  C-c T l   By tag      Filter sessions by tag
  C-c ?     Help        Full keybinding reference
────────────────────────────────────────────────────
```

The welcome is implemented as an `:override` advice on `agent-shell-auggie--welcome-message`, preserving the original auggie welcome while appending the reference card.

## Nix Options

```nix
programs.emacs.decknix.agentShell.enable = true;  # Enable the entire ecosystem
```

Disabling this single option removes all agent-shell packages and configuration.

