# Agent Shell

The Emacs Agent Shell is a native, multi-session AI agent interface built on [agent-shell.el](https://github.com/xenodium/agent-shell) and the Augment Code Protocol (ACP). It turns Emacs into a first-class AI development environment where sessions are persistent, context-aware, and deeply integrated with your workflow.

## Why Not Just a Chat Buffer?

Most AI integrations treat conversations as disposable text. Agent Shell treats them as **first-class objects**:

- **Sessions persist** — resume any conversation from days ago with full context
- **Sessions have metadata** — tags, pinned issues, CI status, review threads
- **Sessions are searchable** — find any past session by keyword or tag
- **Sessions are composable** — structured prompts via templates and slash commands
- **Sessions are work-aware** — auto-detect issues, PRs, and Jira tickets from conversation text

## Package Ecosystem

Agent Shell is assembled from 6 packages using tiered sourcing:

| Package | Source | Purpose |
|---------|--------|---------|
| `shell-maker` | nixpkgs unstable | Comint-like shell buffer management |
| `acp` | nixpkgs unstable | Augment Code Protocol client |
| `agent-shell` | nixpkgs unstable | Core agent interface |
| `agent-shell-manager` | Custom derivation | Tabulated session dashboard |
| `agent-shell-workspace` | Custom derivation | Dedicated tab-bar workspace |
| `agent-shell-attention` | Custom derivation | Mode-line attention tracker |

Plus ~1,800 lines of custom Elisp in `agent-shell.nix` providing sessions, tags, compose, commands, templates, and context awareness.

## Layers

The implementation is organised into 5 layers, each building on the previous:

| Layer | Name | What It Provides | Page |
|-------|------|------------------|------|
| 1 | **Foundation** | Core shell, ACP protocol, package sourcing | [Foundation →](./foundation.md) |
| 2 | **Multi-Session** | Session picker, resume, history, quit | [Multi-Session →](./multi-session.md) |
| 3 | **Productivity** | Compose buffer, templates, commands, tags | [Productivity →](./productivity.md) |
| 4 | **Integration** | MCP servers, declarative tool config | [Integration →](./integration.md) |
| 5 | **Context** | Issues, PRs, CI status, review threads | [Context →](./context.md) |

## Quick Reference

```
C-c A a    Start / switch to agent
C-c A s    Session picker (live + saved + new)
C-c A e    Compose multi-line prompt
C-c A ?    Full keybinding help
C-c A I    Context panel (issues, PRs, CI)
```

Inside an agent-shell buffer, drop the `A` prefix: `C-c s`, `C-c e`, `C-c ?`, etc.

→ **[Full keybinding reference](./keybindings.md)**

