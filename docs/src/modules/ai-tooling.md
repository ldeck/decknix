# AI Tooling

Decknix includes declarative configuration for the [Augment Code](https://www.augmentcode.com/) AI agent.

## Auggie CLI

The `auggie` module wraps the Augment Code agent CLI with Nix-managed settings.

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

### MCP Servers

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

## Agent Shell (Emacs)

The Emacs `agent-shell` module provides an interactive AI agent interface inside Emacs:

- **Sessions** — create, switch, resume agent conversations
- **Commands** — run Nix-managed or project-local auggie commands
- **Tags** — label and filter sessions
- **Keybindings:**
  - `C-c A s` → Start/switch agent session
  - `C-c A c` → Pick and run a command
  - `C-c A T` → Tag management
  - `C-c A M l` → List configured MCP servers
  - `C-c ?` → Full keybinding help

This module is included in the `full` Emacs profile.

