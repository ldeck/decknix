# AI Tooling

Decknix provides a declarative, Nix-managed AI development environment — from CLI agent configuration to a full Emacs-native agent interface with session management, work context awareness, and prompt engineering tools.

## What's Included

| Component | Option | Default | Description |
|-----------|--------|---------|-------------|
| **Claude Code** | `decknix.ai.claude.enable` | off | Claude Code CLI, settings, MCP servers, permissions |
| **Pi** | `decknix.ai.pi.enable` | off | Pi coding agent |
| **Antigravity** | `decknix.ai.antigravity.enable` | off | Antigravity CLI (`agy`), Google's successor to the Gemini CLI; speaks ACP via `agy acp`. Sign in once with `agy` |
| **Gemini** | `decknix.ai.gemini.enable` | off | Gemini CLI (deprecated: warns and points to Antigravity) |
| **Codex** | `decknix.ai.codex.enable` | off | Codex CLI and its ACP bridge |
| **OpenCode** | `decknix.ai.opencode.enable` | off | OpenCode |
| **Goose** | `decknix.ai.goose.enable` | off | Goose |
| **Qwen Code** | `decknix.ai.qwen.enable` | off | Qwen Code |
| **Auggie CLI** | `decknix.cli.auggie.enable` | off | Augment Code agent with Nix-managed settings and MCP servers ([Configuration](./configuration.md)) |
| **Gortex** | `decknix.ai.gortex.enable` | on | Code-intelligence graph of your tracked repos, served to every configured agent over MCP; its daemon runs only when a roster is set |
| **agent-sync** | `decknix.cli.agentSync.enable` | on when files are registered | Deploys skills, commands and guidelines as real, editable copies |
| **Agent Shell** | `programs.emacs.decknix.agentShell.enable` | on (full Emacs profile) | Emacs-native multi-session AI interface ([Agent Shell](./agent-shell/overview.md)) |

Every option is listed in the [Configuration Hub](../../hub.md).

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
  ~/.augment/     ~/.augment/    ~/.claude/commands/
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

For CLI-only usage without Emacs, run the agent directly (`claude`, `pi`, `auggie`, ...) or use the workspace- and tag-aware session commands:

```bash
decknix session new                 # new Claude session in this workspace
decknix session list                # sessions in this workspace
decknix session resume --last       # resume the most recent one
```

## Next Steps

- [Configuration](./configuration.md): Auggie CLI settings, MCP servers, model selection
- [Agent Shell Overview](./agent-shell/overview.md) — The Emacs agent interface
- [Vision](./vision.md) — Where this is heading

