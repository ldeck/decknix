# AI Tooling

Decknix provides a declarative, Nix-managed AI development environment — from CLI agent configuration to a full Emacs-native agent interface with session management, work context awareness, and prompt engineering tools.

## What's Included

| Component | Description | Page |
|-----------|-------------|------|
| **Auggie CLI** | Augment Code agent with Nix-managed settings and MCP servers | [Configuration →](./configuration.md) |
| **Agent Shell** | Emacs-native multi-session AI interface (7 sub-modules) | [Agent Shell →](./agent-shell/overview.md) |

## Design Principles

1. **Declarative first** — all configuration lives in Nix. `decknix switch` reproduces your entire AI setup on any machine.
2. **Runtime-mutable** — settings are *copied* (not symlinked) so tools can modify them at runtime. The next `decknix switch` resets to the Nix-managed baseline.
3. **Composable** — each component is independently toggleable. Use the CLI without Emacs, or Emacs without MCP servers.
4. **Session-as-first-class** — AI conversations are persistent objects with tags, context items, and metadata — not disposable chat buffers.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Nix Configuration (agent-shell.nix, auggie.nix)│
│  ┌──────────┐  ┌──────────┐  ┌────────────────┐│
│  │ Settings  │  │ MCP      │  │ Commands &     ││
│  │ & Model   │  │ Servers  │  │ Templates      ││
│  └─────┬─────┘  └─────┬────┘  └───────┬────────┘│
└────────┼──────────────┼───────────────┼──────────┘
         ▼              ▼               ▼
  ~/.augment/     ~/.augment/    ~/.augment/commands/
  settings.json   settings.json  ~/.emacs.d/snippets/
         │              │               │
         ▼              ▼               ▼
┌─────────────────────────────────────────────────┐
│  Emacs Agent Shell                              │
│  ┌──────┐ ┌─────────┐ ┌────────┐ ┌───────────┐│
│  │Core  │ │Sessions │ │Prompts │ │Context    ││
│  │ACP   │ │Tags     │ │Commands│ │CI/PR/Issue││
│  └──────┘ └─────────┘ └────────┘ └───────────┘│
└─────────────────────────────────────────────────┘
```

## Quick Start

AI tooling is enabled by default in the `full` Emacs profile. To start:

```
C-c A a    → Start an agent session
C-c A s    → Session picker (live + saved + new)
C-c A ?    → Full keybinding reference
```

For CLI-only usage without Emacs:

```bash
auggie                    # Interactive agent session
auggie session list       # List saved sessions
auggie session resume ID  # Resume a session
```

## Next Steps

- [Configuration](./configuration.md) — Auggie CLI settings, MCP servers, model selection
- [Agent Shell Overview](./agent-shell/overview.md) — The Emacs agent interface
- [Vision](./vision.md) — Where this is heading

