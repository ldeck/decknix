# Productivity (Layer 3)

Layer 3 provides the tools for structured, repeatable interactions with the AI agent.

## Compose Buffer (`C-c e`)

A magit-style multi-line editor for writing prompts. Opens at the bottom of the frame:

```
┌─────────────────────────────────────────────┐
│  *agent-shell*<my-session>                  │
│                                             │
│  ... conversation ...                       │
│                                             │
├─────────────────────────────────────────────┤
│  Compose prompt → C-c C-c submit, C-c C-k  │
│                                             │
│  Please refactor the UnrecoverableError     │
│  handler to support a new category:         │
│                                             │
│  - Add `TransientNetworkError` subclass     │
│  - Wire it into the metrics recorder        │
│  - Update the Terraform alert definitions   │
│                                             │
└─────────────────────────────────────────────┘
```

- `C-c C-c` — submit the composed text to the agent
- `C-c C-k` — cancel and close the compose buffer
- Full text-mode editing: `RET` for newlines, no accidental submissions

## Yasnippet Prompt Templates (`C-c t t`)

Seven built-in templates with interactive fields:

| Template | Key | Purpose |
|----------|-----|---------|
| `/review` | `C-c t t` → review | Code review with focus selector (bugs, performance, security, readability) |
| `/refactor` | `C-c t t` → refactor | Refactoring with pattern selector (extract, rename, DRY up, etc.) |
| `/test` | `C-c t t` → test | Test generation covering happy path, edge cases, errors |
| `/explain` | `C-c t t` → explain | Code explanation with aspect focus |
| `/fix` | `C-c t t` → fix | Bug fix with stack trace placeholder |
| `/implement` | `C-c t t` → implement | Feature implementation following existing patterns |
| `/debug` | `C-c t t` → debug | Debugging with logs and steps-taken fields |

Templates auto-populate the current file from the source buffer. TAB advances between fields; `yas-choose-value` provides dropdown selectors.

### Creating Templates

- `C-c t n` — create a new yasnippet template
- `C-c t e` — edit an existing template

Templates are stored in `~/.emacs.d/snippets/agent-shell-mode/`.

## Custom Slash Commands (`C-c c c`)

Slash commands are markdown files with YAML frontmatter, deployed to `~/.augment/commands/`:

```markdown
---
description: Create a new session from a Jira ticket key
argument-hint: [session name or JIRA-KEY]
---

Create a new Augment session and rename it in one step.
...
```

### Built-in Commands

| Command | Description |
|---------|-------------|
| `/start` | Create a new session from a Jira ticket key or plain name |
| `/find-session` | Search all saved sessions by keyword (up to 500) |
| `/pivot-conversation` | Hard pivot — discard current plan, re-evaluate |
| `/step-back` | Stop, summarise progress, wait for direction |

### Command Discovery

The picker (`C-c c c`) scans both global (`~/.augment/commands/`) and project-level (`.augment/commands/`) directories. Each command shows its scope and description:

```
Command:
  /start           (global)  Create a new session from a Jira ticket key
  /find-session    (global)  Search all saved sessions by keyword
  /pivot-conversation (global)  Hard pivot — discard current plan
  /deploy-check    (project) Verify deployment prerequisites
```

### Nix-Managed vs Runtime Commands

Nix-managed commands are deployed as **symlinks**. User-created commands are **regular files**. On `decknix switch`, Nix refreshes its symlinks; runtime-created commands persist untouched.

## Session Tagging (`C-c T`)

Tag sessions with freeform labels for organisation:

| Key | Action |
|-----|--------|
| `C-c T t` | Add a tag (with completion from existing tags) |
| `C-c T r` | Remove a tag |
| `C-c T l` | Filter sessions by tag → resume picker |
| `C-c T e` | Rename a tag across all sessions |
| `C-c T d` | Delete a tag globally |
| `C-c T c` | Cleanup orphaned tags (sessions that no longer exist) |

Tags are stored in `~/.config/decknix/agent-sessions.json`, keyed by auggie session ID. The session picker shows tags inline:

```
[saved] a1b2c3d4  2h ago  12x  Fix pubsub timeout... [proptrack, bug]
```

## Nix Options

```nix
programs.emacs.decknix.agentShell = {
  templates.enable = true;  # Yasnippet prompt templates
  commands.enable = true;   # Nix-managed slash commands
};
```

