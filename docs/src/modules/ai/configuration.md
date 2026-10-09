# AI Configuration

All AI tooling is configured declaratively in Nix and deployed via `decknix switch`.

## Claude Code version

Claude Code is installed by Nix, not by the self-updating native installer.
The framework overlays selected `pkgs.unstable` packages (Claude Code, Pi,
Tabularis, and optional OmniWM) from the separately locked `nixpkgs-current`
input. This lets those tools advance without upgrading every shared unstable
consumer (notably Spec Kit). To move them to a newer nixpkgs release, run
`nix flake update nixpkgs-current` in `decknix`, verify with a full system
build, then run `decknix switch`. `which claude` confirms the Nix profile
takes precedence; `claude --version` confirms the selected version.

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

### Pi ACP startup

Set `decknix.ai.pi.settings.quietStartup = true` when Pi runs through
agent-shell. This suppresses the informational ACP prelude and avoids a redundant
full Pi launch used only to render its version. The Nix-packaged `pi-acp` also
skips its npm update probe because Nix owns package upgrades; normal Pi sessions
remain fully functional and `/changelog` stays available on demand.

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


## Gortex (shared code-intelligence graph)

`decknix.ai.gortex` indexes your repositories into a knowledge graph and serves
it to every configured agent, so a question is answered by one graph query
instead of a fan-out of greps and file reads.

One long-living daemon holds the graph for **all** tracked repos; each agent
connects through a thin `gortex mcp` stdio proxy. Memory therefore scales with
the size of your workspace, not with how many agent sessions are open — which
is what makes it practical with a dozen sessions live.

```nix
decknix.ai.gortex = {
  enable = true;                       # default
  roster.roots = [ "~/Code" ];         # scan here for repositories
  roster.worktrees = "canonical";      # default; see below
  workspaceSlugs = {
    "~/Code/service" = "my-project";   # pin repos into one workspace
    "~/Code/client"  = "my-project";
  };
};
```

The launchd service defaults on only once the roster is non-empty — a daemon
holding an empty graph is a resident process answering nothing. After the
launchd service starts on `decknix switch`, activation stops orphaned Gortex
daemons from older Nix versions owned by the same user. It verifies that the
current-version launchd daemon is running first, leaves MCP clients and the
managed daemon untouched, and escalates from SIGTERM to SIGKILL after three
seconds if an old daemon does not exit. Cleanup is bounded and never deletes
graph data; if the managed daemon is unavailable, it leaves the old process
alone rather than risk taking down the only working daemon. The service
sets `HOME` but does not set `XDG_*`: agents started from Emacs or a shell
usually have no `XDG_*` variables, and Gortex then uses `~/.gortex` for its
graph and daemon socket. Setting `XDG_*` only for launchd creates a second,
empty graph and leaves the clients trying to start a detached daemon on a
different socket. Keep the service and clients on the same store.

Indexing and watching tracked repositories consume CPU and disk even when
agents do not query the graph. Keep `roster.roots` narrow, prefer `canonical`
worktrees, and leave `daemon.enable = false` if you only want the CLI and not a
live MCP service. Set `decknix.ai.gortex.enable = false` to opt out of the
daemon, roster reconciliation, and agent integrations entirely; this does not
delete the existing graph. `gortex savings` shows recorded source-reading
savings, not every possible graph query, so a zero there alone does not prove
no agent uses the graph.

### Worktrees

Repositories with many linked worktrees are the interesting case. Gortex
resolves a worktree back to its canonical repo by reading the `commondir` file
that a worktree's gitdir carries and a submodule's does not.

- `canonical` (default) — one graph per repository, covering every checkout.
  With a worktree-per-branch workflow this is the difference between indexing
  a repo once and indexing it dozens of times for branches that differ by a
  handful of files.
- `independent` — each worktree tracked as its own instance, indexed from its
  own branch. Worth the memory only when you need to query two branches side
  by side.

Discovery keys on `.git` being a *directory*, which is exactly the
primary-vs-linked distinction, so worktrees are skipped structurally rather
than by guessing at a path convention.

### Agent wiring

decknix deliberately does **not** run `gortex init` inside a repository. That
command writes `CLAUDE.md`, `.claude/skills/generated/`, `.claude/settings.json`
hooks and `.mcp.json` — all of which `decknix.cli.agentSync` already owns.
Putting two writers on those files is how you get drift. Instead each agent is
wired through the seam decknix already manages for it:

| Agent | How | Why |
|-------|-----|-----|
| Claude Code | `decknix.ai.claude.mcpServers` | jq-merges only `.mcpServers`, leaving runtime keys alone |
| Augment | `decknix.cli.auggie.mcpServers` | hand-written: gortex ships no Augment adapter, but Augment speaks MCP |
| Pi | `gortex install --agents=pi` | Pi does **not** speak MCP — it loads the `pi-gortex` package |

Pi is the one that surprises people: its help mentions MCP nowhere and its
settings carry no `mcpServers` key, which is why gortex's Pi adapter installs
the `pi-gortex` package and writes `~/.pi/agent/extensions/gortex.json` for
its runtime configuration. That JSON file is not itself an extension; Pi loads
the package's `index.ts`. When launchd manages Gortex, decknix sets the Pi
package's binary to a wrapper that skips its unconditional detached daemon
start but forwards its MCP requests. This prevents Pi session reloads from
creating another daemon while the managed service is still opening its graph.
Declaring an MCP entry for Pi looks right in Nix and does nothing.

### Workspace slugs

By default every tracked repo is its own isolated workspace — a hard graph
boundary — so a server in one repo and the client calling it in another look
like orphans to cross-repo analysis. `workspaceSlugs` pins them together.

Slugs are recorded in `~/.gortex/config.yaml` rather than a `.gortex.yaml`
inside each repo, so nothing lands in a checkout you share with other people.
Decknix normalises the configured repo keys to absolute paths before handing
them to gortex, so writing `"~/Code/..."` in Nix is fine.
A repo that genuinely wants an in-tree `.gortex.yaml` can still commit one —
gortex's precedence chain prefers it.

Note that `~/.gortex/config.yaml` is owned by **gortex**, not by Nix: `track`,
`untrack` and `workspace set` all mutate it. decknix drives it through the CLI
from an activation script rather than generating the file, which would fight
the daemon for ownership. The activation reloads the daemon before assigning
workspace slugs so freshly tracked repos are visible to `workspace set`.
Every roster CLI request has an eight-second deadline and the whole optional
roster step is capped at 60 seconds. If a busy daemon cannot complete an
operation, switch continues and the next switch retries; no configuration
activation should wait indefinitely for an indexer RPC.
