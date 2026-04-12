# Decknix Hub

> Background work-item aggregator — surfaces PR reviews, WIP PRs, Jira tasks,
> and CI status in your Emacs sidebar without blocking the editor.

## Overview

`decknix-hub` is a lightweight Rust daemon managed by launchd. It polls
external services (GitHub, Jira, TeamCity) on independent timers and writes
per-adapter JSON files to `~/.config/decknix/hub/`. Emacs watches this
directory with `file-notify` and refreshes the sidebar instantly when data
changes — zero polling from Emacs, zero main-thread blocking.

```
┌──────────────────────────────────────────────────────┐
│              decknix-hub (launchd)                    │
│  ┌──────────┐  ┌──────────┐  ┌──────┐  ┌─────────┐ │
│  │  GitHub   │  │  GitHub  │  │ Jira │  │TeamCity │ │
│  │  Reviews  │  │   WIP    │  │ 120s │  │  60s    │ │
│  │  60s poll │  │  120s    │  │ poll │  │  poll   │ │
│  └─────┬────┘  └─────┬────┘  └──┬───┘  └────┬────┘ │
│        ▼              ▼          ▼            ▼      │
│  github-reviews  github-wip  jira-tasks  teamcity-  │
│      .json         .json       .json    builds.json  │
│        └──────────┬──────────────┘            │      │
│          ~/.config/decknix/hub/               │      │
└───────────────────┬───────────────────────────┘
                    │ file-notify
                    ▼
           Emacs sidebar refresh
```

## Quick Start

### 1. Enable the daemon

In your `decknix-config` (e.g., `~/.config/decknix/configuration.nix`):

```nix
decknix.services.hub.enable = true;
```

### 2. Apply the configuration

```bash
decknix switch
```

This starts a launchd user agent (`com.decknix.hub`) that runs in the
background. The Emacs sidebar integration is enabled by default — once the
daemon writes its first data, the **Requests** and **WIP** sections appear
automatically.

### 3. Verify it's running

```bash
# Check the launchd agent
launchctl list | grep decknix-hub

# One-shot test (doesn't need launchd)
decknix-hub --once

# Check the data
ls ~/.config/decknix/hub/
cat ~/.config/decknix/hub/meta.json
```

## Configuration Options

### Darwin (daemon)

#### GitHub

| Option | Default | Description |
|--------|---------|-------------|
| `decknix.services.hub.enable` | `false` | Start the launchd daemon |
| `decknix.services.hub.github.enable` | `true` | Enable GitHub adapter |
| `decknix.services.hub.github.reviewsInterval` | `60` | Seconds between review polls |
| `decknix.services.hub.github.wipInterval` | `120` | Seconds between WIP polls |
| `decknix.services.hub.github.reviewRepos` | `[]` | Repos to check (empty = all) |

#### Jira

| Option | Default | Description |
|--------|---------|-------------|
| `decknix.services.hub.jira.enable` | `false` | Enable Jira adapter |
| `decknix.services.hub.jira.baseUrl` | `""` | Jira base URL (e.g. `https://myorg.atlassian.net`) |
| `decknix.services.hub.jira.email` | `""` | User email for API auth (typically wired from `config.<org>.user.email`) |
| `decknix.services.hub.jira.apiTokenFile` | `~/.config/decknix/local/jira-token` | Path to Jira API token file |
| `decknix.services.hub.jira.project` | `""` | Jira project key (e.g. `NC`) |
| `decknix.services.hub.jira.statuses` | `["Ready" "In Progress" "Blocked" "Code Review"]` | Statuses to poll |
| `decknix.services.hub.jira.interval` | `120` | Seconds between polls |
| `decknix.services.hub.jira.maxResults` | `50` | Max tasks per poll |

#### TeamCity

| Option | Default | Description |
|--------|---------|-------------|
| `decknix.services.hub.teamcity.enable` | `false` | Enable TeamCity adapter |
| `decknix.services.hub.teamcity.proxyUrl` | `http://localhost:8080` | IAP proxy URL |
| `decknix.services.hub.teamcity.interval` | `60` | Seconds between polls |
| `decknix.services.hub.teamcity.repos` | `[]` | Repos to cross-link with WIP branches |
| `decknix.services.hub.teamcity.recentFinishedCount` | `1` | Recent finished builds per branch |

#### Identity Wiring

Org configs typically wire identity from `config.<org>.user.email` (set via `identity.nix`):

```nix
# In org config system.nix:
decknix.services.hub.jira.email = lib.mkDefault config.nurturecloud.user.email;
```

See [Config Loader — Identity Files](../architecture/config-loader.md#identity-files) for details.

### Emacs (sidebar integration)

| Option | Default | Description |
|--------|---------|-------------|
| `programs.agent-shell.decknix.hub.enable` | `true` | Show hub data in sidebar |

## Sidebar Sections

### Requests

PR reviews assigned to you, ordered oldest first. Each line shows:

```
 Requests (8)
  72d repo#142 ✓ Fix payment widget
   3d repo#219 ⟳ Refactor extract
```

- **Age** — colour-coded: ≥3 days = red, <3 days = yellow
- **CI** — `✓` pass, `✗` fail, `⟳` running
- **RET** on a line opens the PR in the browser

### WIP

Your open PRs grouped by repository, with TeamCity build status:

```
 WIP (3)
   my-repo
  5h #221  ✓ ✓ feat: new thing
  3d #219  ⟳ ⟳42% refactor: extract
   other-repo
  1d #37   ✗ ✗ fix: update deps
```

The first icon is GitHub CI, the second is TeamCity (when enabled).
TeamCity running builds show progress percentage.

### Tasks

Jira tasks assigned to you, grouped by status:

```
 Tasks (4)
  ● NC-1234 In Progress  Implement hub daemon
  ◐ NC-1235 Code Review  Fix payment widget
  ✕ NC-1236 Blocked      Waiting for API access
  ○ NC-1237 Ready        Update documentation
```

Status icons: `●` In Progress, `◐` Code Review, `✕` Blocked, `○` Ready.
Press `RET` on a task to open it in Jira.

### Org Filter (`O`)

Press `O` in the sidebar to cycle through GitHub owners/orgs:
`all` → `ldeck` → `UpsideRealty` → `all`. Filters both Requests and WIP.

## Troubleshooting

**Sidebar shows "not running — ? O for setup"**

The daemon isn't running. Enable it:
```nix
decknix.services.hub.enable = true;
```
Then `decknix switch`.

**Sidebar shows "waiting for data…"**

The hub directory exists but no JSON files yet. The daemon may have just
started. Check logs:
```bash
cat /tmp/decknix-hub.log
```

**`gh` authentication issues**

The daemon uses the `gh` CLI for GitHub access. Ensure you're authenticated:
```bash
gh auth status
```

## Data Files

All state is stored in `~/.config/decknix/hub/`:

| File | Content |
|------|---------|
| `github-reviews.json` | PR reviews needing your attention |
| `github-wip.json` | Your open PRs with CI status and branches |
| `jira-tasks.json` | Jira tasks assigned to you |
| `teamcity-builds.json` | TeamCity build status for WIP branches |
| `meta.json` | Adapter health: last poll time, errors |

Each adapter writes independently — a slow Jira poll won't block GitHub
data from refreshing.

## Future Adapters (Planned)

- **Slack** — unread mentions requiring follow-up
- **macOS notifications** — new reviews, CI failures
