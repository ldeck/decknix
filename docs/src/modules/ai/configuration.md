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

## Custom Commands

Nix-managed commands are deployed to `~/.augment/commands/` as symlinks. User-created commands (regular files) coexist in the same directory and are not affected by `decknix switch`.

```nix
# Commands are defined in agent-shell.nix and deployed automatically.
# To add your own at runtime:
# C-c c n  → Create new command (opens template in ~/.augment/commands/)
```

See [Productivity](./agent-shell/productivity.md) for the full command framework.

