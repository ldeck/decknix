# Integration (Layer 4)

Layer 4 connects the agent shell to external tools and services via the Model Context Protocol (MCP).

## MCP Server Configuration

MCP servers extend the agent's capabilities by providing access to external data sources and APIs. Decknix manages them declaratively:

```nix
{ ... }: {
  decknix.cli.auggie.mcpServers = {
    context7 = {
      type = "stdio";
      command = "npx";
      args = [ "-y" "@upstash/context7-mcp@latest" ];
    };
    "gcp-monitoring" = {
      type = "stdio";
      command = "npx";
      args = [ "-y" "gcp-monitoring-mcp" ];
      env.GOOGLE_APPLICATION_CREDENTIALS = "~/.config/gcloud/credentials.json";
    };
    "nurturecloud-knowledge-base" = {
      type = "stdio";
      command = "npx";
      args = [ "-y" "nurturecloud-kb-mcp" ];
    };
  };
}
```

## Viewing Servers (`C-c A S`)

The MCP server listing shows all configured servers in a formatted buffer:

```
MCP Server Configuration
════════════════════════════════════════════════════════
Source: ~/.augment/settings.json

  context7
    type:    stdio
    command: npx
    args:    -y @upstash/context7-mcp@latest

  gcp-monitoring
    type:    stdio
    command: npx
    args:    -y gcp-monitoring-mcp
    env:
      GOOGLE_APPLICATION_CREDENTIALS=~/.config/gcloud/credentials.json

════════════════════════════════════════════════════════
Runtime changes (auggie mcp add) are temporary.
To persist, edit Nix config and run decknix switch.
Press q to close this buffer.
```

## Declarative vs Runtime

The two-tier model:

1. **Nix-managed** (persistent) — defined in your Nix config, deployed on `decknix switch`. This is the baseline.
2. **Runtime** (temporary) — added via `auggie mcp add` during a session. Lost on next `decknix switch`.

This lets you experiment with new MCP servers without committing to them, while ensuring your team's standard servers are always present.

## How MCP Enhances the Agent

With MCP servers configured, the agent can:

| Server | Capability |
|--------|-----------|
| `context7` | Query up-to-date library documentation |
| `gcp-monitoring` | Search GCP logs, error groups, Datastore entities |
| `nurturecloud-knowledge-base` | Search resolved Jira tickets and internal docs |
| `jira` | Read/create/transition Jira issues |
| `confluence` | Search and create Confluence pages |
| `github` | Full GitHub API access (issues, PRs, code search) |

The agent automatically discovers available MCP servers and uses them when relevant to the conversation.

## Organisation-Specific Servers

Org configs can layer additional MCP servers on top of the framework defaults. See [Organisation Configs](../../configuration/org-configs.md) for how this works.

For NurtureCloud-specific MCP server configuration, see the [NC Agent Shell Workflows](https://github.com/UpsideRealty/decknix-config) documentation.

