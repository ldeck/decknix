# AI Configuration

All AI tooling is configured declaratively in Nix and deployed via `decknix switch`.

## Auggie CLI

### Enabling

```nix
{ ... }: {
  decknix.cli.auggie.enable = true;
}
```

### Settings

```nix
{ ... }: {
  decknix.cli.auggie.settings = {
    model = "opus4.6";
    indexingAllowDirs = [
      "~/tools/decknix"
      "~/Code"
    ];
  };
}
```

Settings are written to `~/.augment/settings.json`. The file is **copied** (not symlinked) so auggie can modify it at runtime; the next `decknix switch` overwrites with the Nix-managed version.

## MCP Servers

Declaratively configure [Model Context Protocol](https://modelcontextprotocol.io/) servers:

```nix
{ ... }: {
  decknix.cli.auggie.mcpServers = {
    context7 = {
      type = "stdio";
      command = "npx";
      args = [ "-y" "@upstash/context7-mcp@latest" ];
      env = {};
    };
    "gcp-monitoring" = {
      type = "stdio";
      command = "npx";
      args = [ "-y" "gcp-monitoring-mcp" ];
      env.GOOGLE_APPLICATION_CREDENTIALS = "~/.config/gcloud/credentials.json";
    };
  };
}
```

MCP servers are written into the `mcpServers` section of `~/.augment/settings.json`.

### Slack MCP Workspaces

Connect auggie to one or more Slack workspaces using the official [Slack MCP server](https://mcp.slack.com/mcp):

```nix
{ ... }: {
  decknix.cli.auggie.slack.workspaces = {
    acme-corp = {
      clientId = "3660753192626.123456";
      description = "ACME Corp team workspace";
    };
    personal = {
      clientId = "3660753192626.789012";
    };
  };
}
```

Each workspace generates a `slack-<name>` entry in `mcpServers` pointing at `https://mcp.slack.com/mcp` with the workspace's `CLIENT_ID` for OAuth authentication.

**Setup requirements:**
1. Create or reuse a Slack app at [api.slack.com/apps](https://api.slack.com/apps)
2. Enable OAuth with appropriate scopes (e.g., `search:read.public`, `chat:write`, `channels:history`)
3. Publish as an internal app or to the Slack Marketplace
4. Copy the **Client ID** from the app's OAuth settings

Multiple workspaces merge naturally — define some in your org config, others in your personal config, and they all appear in `settings.json`.

### Viewing Configured Servers

From Emacs: `C-c A S` opens a formatted buffer showing all configured MCP servers with their type, command, args, and environment variables.

### Runtime vs Nix-Managed

| Source | Persists across `decknix switch`? | How to add |
|--------|-----------------------------------|------------|
| Nix config | ✅ Yes | `decknix.cli.auggie.mcpServers` |
| `auggie mcp add` | ❌ No (temporary) | Runtime command |

## Agent Shell Module

The Emacs agent-shell module is enabled by default in the `full` profile:

```nix
{ ... }: {
  programs.emacs.decknix.agentShell = {
    enable = true;           # Core agent-shell.el + ACP
    manager.enable = true;   # Tabulated session dashboard
    workspace.enable = true; # Dedicated tab-bar workspace
    attention.enable = true; # Mode-line attention tracker
    templates.enable = true; # Yasnippet prompt templates
    commands.enable = true;  # Nix-managed slash commands
    context.enable = true;   # Work context panel (issues, PRs, CI)
  };
}
```

Each sub-module can be independently disabled. See [Agent Shell Overview](./agent-shell/overview.md) for details on each component.

## Per-Purpose Provider & Model

Automated agent launches (PR reviews, bot-authored PR reviews) and the
interactive `new-session` path can pin a specific `(provider, model,
mode)` triple via Nix, independent of the interactive
`decknix-agent-default-provider`.  Three purposes ship today:

| Purpose | Trigger | Default provider | Default model | Default mode |
|---------|---------|------------------|---------------|--------------|
| `pr-review` | `C-c A c r`, sidebar Requests row, batch processor | `claude-code` | `sonnet` | `auto` |
| `bot-pr-review` | Auto-review dispatch on bot-authored PRs, or matched by author heuristic | `claude-code` | `sonnet` | `auto` |
| `new-session` | Interactive / QUICK `C-c A n` (its `provider` also feeds `decknix-agent-default-provider`) | `claude-code` | `null` | `auto` |

```nix
{ ... }: {
  programs.emacs.decknix.agentShell.purposes = {
    # Human PR reviews go through Claude with opus for depth.
    pr-review     = { provider = "claude-code"; model = "opus"; mode = "auto"; };
    # Bot diffs are shallow — pin the cheapest capable model.
    bot-pr-review = { provider = "claude-code"; model = "haiku"; mode = "auto"; };
    # Start new interactive sessions on Claude in auto (no per-command prompts).
    new-session   = { provider = "claude-code"; mode = "auto"; };
  };
}
```

**Validation.** All three fields are validated at daemon start:

- `provider` must be a registered provider id (built-ins: `auggie`,
  `claude-code`, `pi`).  Unknown values coerce to
  `decknix-agent-default-provider` with a warning to `*Warnings*`.
- `model` must appear in `decknix-agent-known-models` for the chosen
  provider (or be `null` to defer to the provider default).  Unknown
  values drop to `nil` with a warning.
- `mode` is a session/permission mode honoured only by providers that
  expose one — today `claude-code`, whose ids are `default`, `auto`,
  `acceptEdits`, `bypassPermissions`, and `plan`.  For providers
  without session modes (Auggie, Pi) it drops to `nil` at boot with a
  warning.  Set to `null` to keep the provider's own default.

**Resume semantics.** For launch-flag providers (Auggie) the model is
appended as `--model <id>`; for flagless providers (Claude, Pi) it is
replayed over ACP once the session reports ready.  The permission
`mode` is baked into the session config and applied by agent-shell once
the session reports ready.  Either way, once you switch mid-session
with `C-c C-v` (model) or `C-c C-m` (mode), that per-conversation
choice persists in `~/.config/decknix/agent-sessions.json` and wins
over the purpose default on both resume **and** fork.

**Scope.** The two `*-review` purposes are consulted by the automated
review launchers; `new-session` seeds interactive `C-c A n`.  `C-c A f`
(fork) inherits the source conversation's persisted model/mode (falling
back to the `new-session` defaults), and the sidebar worktree `w s`
action keeps `decknix-agent-default-provider` with no model pin.
See [Model Selection](./agent-shell/foundation.md#model-selection)
for the full override-lever hierarchy.

## Custom Commands

Nix-managed commands are deployed to `~/.claude/commands/` (the shared slash-command location read natively by both Claude Code and Auggie) and also to `~/.pi/agent/prompts/` (where Pi reads them as `/name` prompt templates), so a single source covers every supported agent. User-created commands (regular files) coexist in each directory and are not affected by `decknix switch`.

```nix
# Commands are defined in agent-shell.nix and deployed automatically.
# To add your own at runtime:
# C-c c n  → Create new command (opens template in ~/.claude/commands/)
```

See [Productivity](./agent-shell/productivity.md) for the full command framework.

## Claude Permissions

Claude Code prompts before running any Bash command unless it matches a rule in
`~/.claude/settings.json` (`permissions.allow`). Skills ship executable helper
scripts (deployed `755` via `decknix.cli.agentSync` with `executable = true`),
so without an allow rule Claude asks for permission every session before running
them.

By default decknix auto-allowlists every Nix-installed executable tool it
manages — each executable agent-sync file becomes a narrow
`Bash(<abs-path>:*)` prefix rule (framework- and org-registered scripts alike):

```nix
{ ... }: {
  decknix.ai.claude = {
    enable = true;

    # Auto-allow decknix/Nix-installed executable skill scripts (default: true).
    permissions.allowManagedTools = true;

    # Extra rules merged in alongside the managed-tool rules.
    permissions.allow = [
      "Bash(gh pr view:*)"
    ];

    # DENY rules always win over allow — the backstop for a broad allow-list.
    permissions.deny = [
      "Bash(sudo:*)"
      "Read(~/.config/decknix/**/secrets/**)"
    ];
  };
}
```

Both lists are **deep-merged** into `~/.claude/settings.json` — decknix updates
only `.permissions.allow` and `.permissions.deny` (each union + de-duplicated)
and leaves every other key untouched, because Claude mutates this file at
runtime (e.g. it writes `skipDangerousModePermissionPrompt`). Set
`allowManagedTools = false` to manage the allowlist entirely by hand.

### Allowlist vs. blacklist model

A path-scoped allowlist rots the moment a managed tool moves on disk: every
stale `Bash(<old-abs-path>:*)` rule silently matches nothing, and Claude
re-prompts for the relocated tool every session. Two ways to avoid that:

- **Allowlist (default).** Keep `allowManagedTools = true` and let the
  auto-derived rules track each tool's current absolute path. They regenerate
  on every `decknix switch`, so a move updates the rule automatically —
  provided the tool stays a managed executable agent-sync file.
- **Blacklist.** Allow the common tools *broadly* and lean on `permissions.deny`
  as the backstop:

  ```nix
  decknix.ai.claude.permissions = {
    allowManagedTools = false;              # broad Bash below supersedes them
    allow = [ "Bash" "Read" "Edit" "Write" ];
    deny  = [
      "Read(~/.config/decknix/**/secrets/**)"
      "Bash(sudo:*)"
      "Bash(rm -rf /:*)"
      "Bash(rm -rf ~:*)"
    ];
  };
  ```

  A bare `Bash` allow can't rot when a script moves, so this trades a
  maintained allowlist for a small never-do denylist. Two caveats:

  - `deny` is evaluated before `allow` and always wins, but the host's own
    destructive-command classifier still runs independently — it remains the
    real backstop even under a broad allow.
  - A `Read(...)` deny guards the Read/Edit **tool** path only. Under a broad
    `Bash` allow a shell `cat`/`<` can still reach a denied file, so treat
    secret denies as defence-in-depth (and against accidental whole-dir
    slurps), not a hard boundary. Keep secrets `0600` and out of the Nix
    store regardless.

Leave `defaultMode` at `default` for the blacklist model. `bypassPermissions`
would skip permission evaluation entirely — including your own `deny` rules —
which is the opposite of what a denylist is for.

## Claude MCP Servers

Configure MCP servers for Claude Code globally — every workspace inherits them
without a per-repo `.mcp.json`:

```nix
{ ... }: {
  decknix.ai.claude = {
    enable = true;

    mcpServers = {
      # Atlassian (Jira + Confluence) via the mcp-remote bridge.  First
      # invocation opens a browser flow for OAuth; after that Claude has
      # native Jira/Confluence tools and no longer shells out to
      # `auggie --print --ask` for issue lookups (the previous workaround
      # was ~2 min per call).
      atlassian = {
        type = "stdio";
        command = "npx";
        args = [ "-y" "mcp-remote" "https://mcp.atlassian.com/v1/sse" ];
      };
    };
  };
}
```

The shape mirrors [`decknix.cli.auggie.mcpServers`](#mcp-servers) — stdio
servers use `type` / `command` / `args` / `env`; remote servers use
`type = "http"` (or `"sse"`) plus `url` and optional `headers`.

Entries are **deep-merged** into `~/.claude.json` (`.mcpServers`) on every
`decknix switch`. Claude mutates this file heavily at runtime (`skillUsage`,
`cached*` caches, OAuth tokens, migration flags), so decknix only touches
`.mcpServers` and leaves the ~40 other runtime-managed keys alone:

- Nix-declared entries **win** against runtime-added entries with the same name.
- Runtime-added entries with unrelated names are preserved.
- Removing an entry from Nix does **not** remove it from `~/.claude.json`
  (Claude may have converged on it independently); purge those with
  `/mcp remove <name>` inside Claude.

Reach for a workspace-local `.mcp.json` only when a server should be strictly
project-local (e.g. a repo-scoped test harness). Global config here keeps
personal + org tooling consistent across every project you open.

