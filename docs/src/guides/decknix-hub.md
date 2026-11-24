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

In a system-level module (for example `~/.config/decknix/local/system.nix`, or your org config overlay's darwin module):

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
| `decknix.services.hub.github.wipInterval` | `60` | Seconds between WIP polls |
| `decknix.services.hub.github.mergedRetentionDays` | `7` | Days a merged PR stays in the WIP feed (the 50 most recent merges); the sidebar drops it sooner once shipped |
| `decknix.services.hub.github.reviewRepos` | `[]` | Repos to check (empty = all) |
| `decknix.services.hub.github.mergeReadyNotify` | `false` | Tell the session that raised a PR when it is approved and ready to merge (see [Merge-ready notifications](#merge-ready-notifications)) |

#### Merge-ready notifications

For workflows that pre-authorise agent sessions to merge their own approved
PRs, `mergeReadyNotify = true` makes the WIP adapter classify each open PR
you authored after every poll. A PR is ready when it is approved on its
current head (`review_stale` false), not a draft, CI is `pass`, `mergeable`
is `MERGEABLE` and `merge_state` is `CLEAN` or `HAS_HOOKS`. It is then:

- `clean`: no unresolved threads and no human reply since your last
  activity. The owning session is sent: `PR <url> is approved and clean:
  merge and ship it per the auto-merge policy`.
- `comments`: N unresolved threads, plus one when a human replied (a
  `BLOCKED` merge state is accepted here, since required thread resolution
  blocks until they are handled). The session is sent: `PR <url> approved
  with N comments: classify blocking vs follow-up per the policy, then ship`.

The owner is any conversation that linked the PR (`linked_prs` in
`agent-sessions.json`) or raised it (the created-PR store,
`session-prs.eld`). Its sessions are tried newest first with
`decknix session send <id> --when idle --reason merge-ready`, so the
message lands when the session's turn ends. One message is sent per head
commit and verdict; `merge-ready-state.json` in the hub directory keeps
that across restarts. An undelivered one is retried every five minutes.

The hub never merges. The session does, under the repo's own rules and its
ship flow, and should re-check the live PR first: the WIP feed can be up to
five minutes old. A ready PR no live session took (`delivery` other than
`sent`) is listed in the sidebar [ship queue](../modules/ai/agent-shell/layouts/wip.md#ship-queue)
as `approved · ready to merge` (or `approved · comments to classify`). No
session is spawned for it: the hub has no session identity to sign a spawn
with, and an automatic spawn would spend model credit on every approval.

#### Jira projects

With `projects` set, the adapter runs these queries per poll:

- assigned to me: `project in (...) AND assignee = currentUser() AND statusCategory != Done`
  (written to `items`, at most `maxResults`);
- in progress, counted: `... AND assignee = currentUser() AND statusCategory = "In Progress"`
  (written to `in_progress_total`);
- to pick up, in the pick-up projects (`pickUpProjects`, default
  `projects`): `project in (...) AND assignee is EMPTY AND statusCategory = "To Do" AND sprint in openSprints()`
  (written to `pick_up`, at most 50, with the count in `pick_up_total`). A
  project with no sprints contributes nothing; a failed query is listed in
  `errors` and the rest of the file is kept.

The search endpoint (`/rest/api/3/search/jql`) reports no total, so the
counts come from `/rest/api/3/search/approximate-count`; the sidebar shows
those, never the fetch cap.

Both project lists can be changed without a rebuild or restart:

```bash
decknix hub jira-projects                     # show the current override
decknix hub jira-projects ABC XYZ             # or ABC,XYZ; written to settings.toml
decknix hub jira-projects --clear             # back to the Nix-configured list
decknix hub jira-projects --pick-up ABC       # pick-up projects ([hub.jira] pick_up_projects)
decknix hub jira-projects --pick-up --clear   # pick up from `projects` again
```

That edits `[hub.jira] projects` in `~/.config/decknix/settings.toml`
(keeping the rest of the file), which the daemon re-reads on every Jira poll.
An org overlay sets the default with
`decknix.services.hub.jira.projects = lib.mkDefault [ ... ];`, and its
bootstrap can ask for the list at install time and write the same table.

#### GitHub issues and chores

| Option | Default | Description |
|--------|---------|-------------|
| `decknix.services.hub.github.issuesInterval` | `300` | Seconds between polls of open issues assigned to me (`github-issues.json`); 0 disables |
| `decknix.services.hub.chores.enable` | `false` | Pending Taskwarrior chores (`task-chores.json`) |
| `decknix.services.hub.chores.filter` | `"+chore status:pending"` | Taskwarrior filter |
| `decknix.services.hub.chores.excludeProjects` | `["decknix.perf"]` | Projects (and sub-projects) left out |
| `decknix.services.hub.chores.interval` | `120` | Seconds between polls |

Chores are read with `task rc.gc=off rc.hooks=off ... export`, so a poll
never renumbers or rewrites anything.

#### Kargo

Which deploy stages hold each of your merged PRs, for repos that ship through
[Kargo](https://kargo.io). The adapter reads each stage's current freight with
`kargo get stages --project P NAME... -o json`, takes the git revision the
freight was built from (the OCI `org.opencontainers.image.revision`
annotation, else a sha suffix on the image tag or chart version), and asks
GitHub's compare API whether that revision contains the PR's merge commit.
Freight is built from the newest green build, so the merge is usually an
ancestor rather than the freight revision itself. Answers are cached for the
life of the daemon.

| Option | Default | Description |
|--------|---------|-------------|
| `decknix.services.hub.kargo.enable` | `false` | Enable the Kargo adapter |
| `decknix.services.hub.kargo.interval` | `300` | Seconds between polls |
| `decknix.services.hub.kargo.repos` | `[]` | `{ repo; project; warehouse; stages; stagePattern ? null; region ? null; }` per repo |

```nix
decknix.services.hub.kargo = {
  enable = true;
  repos = [{
    repo = "my-org/widget-api";
    project = "my-org";
    warehouse = "widget-api";
    stages = [ "us-dev" "us-stg" "us-prd" ];   # Kargo stage widget-api-us-dev-deploy, ...
  }];
};
```

A repo that ships through Kargo in several regions, or through Kargo in some
and TeamCity in others, is listed once per region with a `region` label;
each entry becomes its own PR entry in `kargo-stages.json` and its own
shipper in the sidebar (see the WIP layout's *Several shippers per repo*).
When freight bundles images from several repos, the revision comes from the
image whose `org.opencontainers.image.source` names the repo.

The `kargo` CLI must be logged in for the user the daemon runs as
(`kargo login --sso`). Its SSO token lasts about a day and the CLI renews it
silently; when that renewal fails every call fails with `error refreshing
token ... please use kargo login to re-authenticate`.

A poll that cannot read a repo never writes over what the last good poll
said about it. Each of that repo's PR entries is carried forward with
`stale: true` (and `as_of`, when it was read), and the repo is listed under
the file's `stale` key with the error, when the failures began (`since`)
and when it last succeeded (`last_ok`). Failures are classified: an expired
login is not retried and ends the poll's remaining `kargo` calls; a timeout
or connection error is retried twice, after 2s and 8s; a GitHub compare
GitHub could not answer (as opposed to one it answered 404 or 422) also
keeps the previous entry. TeamCity deploys follow the same rule:
`teamcity-deploys.json` carries the last good repo entry with `stale: true`
when a deploy query fails for a reason other than a missing build
configuration (404), and lists the repo under `stale`. The log line for each
poll names the first error.

A merge that changes nothing the repo deploys never gets freight of its
own, so it would wait forever. The hub marks it `no_deploy` (dated by the
merge) in either of two cases:

1. **Its own files touch no runtime path.** Checked as soon as it merges,
   from the PR's file list.
2. **Nothing runtime has merged since the deployed build.** Once
   `noDeployAfterHours` (default 6) have passed with no stage holding the
   merge, every file changed between the revision the first stage runs and
   the merge is checked; if none is a runtime path, the build already
   deployed is equivalent. A compare GitHub truncates (300 files) is never
   taken as proof.

Runtime paths are a repo's `runtimePaths` globs (`*`, `**`, `?`) when set,
typically the path filter of the workflow that builds its freight, for
example `[ "cmd/**" "go.*" "Dockerfile" ".dockerignore" "helm/**" ]`.
Without them every file counts except documentation (`docs/`, `specs/`,
`.specify/`, `*.md`) and repository metadata (`LICENSE*`, `.gitignore`,
`CODEOWNERS`, issue and PR templates), so an unlisted repo errs towards
waiting for a deploy. The sidebar shows such a PR as done, `no deploy
needed`, for the shipped retention, then drops it.

In the sidebar a stale entry with `as_of` keeps the state it was last read
in, marked with a grey `?` (`✗stg?`, `⇢prd?`) and its age on hover, so a
failed stage or one waiting for you to promote stays in the ship queue; a
stage that had shipped stays shipped. A stale entry never read (no
`as_of`) or a missing one reads `stage unknown (Kargo unavailable)` in grey,
never `not deployed`, and asks nothing of you. One line under the WIP
heading says how old the data is, e.g. `⚠ Kargo stale 2h · 6 repos · login
expired, run kargo login --sso`; hover for every repo's error.

#### Jira

| Option | Default | Description |
|--------|---------|-------------|
| `decknix.services.hub.jira.enable` | `false` | Enable Jira adapter |
| `decknix.services.hub.jira.baseUrl` | `""` | Jira base URL (e.g. `https://myorg.atlassian.net`) |
| `decknix.services.hub.jira.email` | `""` | User email for API auth (typically wired from `config.<org>.user.email`) |
| `decknix.services.hub.jira.apiTokenFile` | `~/.config/decknix/local/jira-token` | Path to Jira API token file |
| `decknix.services.hub.jira.projects` | `[]` | Jira project keys for the Tasks section; overridden at runtime by `[hub.jira] projects` in `~/.config/decknix/settings.toml` (see below) |
| `decknix.services.hub.jira.pickUp` | `true` | Also list unassigned To Do issues in open sprints |
| `decknix.services.hub.jira.pickUpProjects` | `[]` | Projects to pick up from; empty means `projects`; overridden by `[hub.jira] pick_up_projects` |
| `decknix.services.hub.jira.project` | `""` | Legacy single project key, used only when `projects` is empty |
| `decknix.services.hub.jira.statuses` | `["Ready" "In Progress" "Blocked" "Code Review"]` | Statuses for the legacy single-project query only |
| `decknix.services.hub.jira.interval` | `120` | Seconds between polls |
| `decknix.services.hub.jira.maxResults` | `50` | Max tasks per poll |

#### TeamCity

| Option | Default | Description |
|--------|---------|-------------|
| `decknix.services.hub.teamcity.enable` | `false` | Enable TeamCity adapter |
| `decknix.services.hub.teamcity.proxyUrl` | `http://localhost:58080` | IAP proxy URL |
| `decknix.services.hub.teamcity.interval` | `60` | Seconds between polls |
| `decknix.services.hub.teamcity.repos` | `[]` | Repos to cross-link with WIP branches |
| `decknix.services.hub.teamcity.recentFinishedCount` | `1` | Recent finished builds per branch |

#### Identity Wiring

Org configs typically wire identity from `config.<org>.user.email` (set via `identity.nix`):

```nix
# In org config system.nix:
decknix.services.hub.jira.email = lib.mkDefault config.my-org.user.email;
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

What there is to do, in four collapsible groups, each capped at
`decknix-sidebar-tasks-per-group` rows (default 5) with the rest named:

```
 Tasks (82)
 ▾ In progress (12)                        ← the true total, not the fetch cap
   ● ABC-1610 Ship the importer            ← a live session works it
   · ABC-1588 Tidy the schema              ← colour: plain in progress, red blocked
     … 10 more
 ▾ To pick up (64)
   · XYZ-42 Rotate the key                 ← unassigned To Do in an open sprint (grey)
 ▾ Chores (2)
   ◦ 4 Renew the certificate
 ▾ Issues (1)
   · widget#12 Fix the flaky test
```

In progress is the Jira status category In Progress only (To Do and Done
are left out). A Jira group's count is the hub's total, so `… N more`
counts everything not listed; listing them all (`RET`) shows what was
fetched and ends with `… N more in Jira` for the rest.

A session works a key when the key is in its name or tags, or in the title or
branch of a PR it owns; those rows come first. `RET` on a Jira row opens the
task menu (open, browser, start a session); on an issue it opens the issue;
on a chore it shows `task info` (fetched in a child process). `TAB` on a group
header collapses it; `RET` on `… N more` lists the rest.

### Org Filter (`O`)

Press `O` in the sidebar to cycle through GitHub owners/orgs:
`all` → each owner in your feeds (for example `you` → `my-org`) → `all`. Filters both Requests and WIP.

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

**A section is showing stale data (e.g. a Request for a PR that already merged)**

Check `meta.json` first — it is the only place a wedged adapter is visible:

```bash
python3 -m json.tool ~/.config/decknix/hub/meta.json
```

Compare each adapter's `last_poll` against now. `last_poll` is stamped on
**every** outcome including errors, so:

- **`last_poll` current, `ok: false`** — the adapter is alive and retrying;
  read `last_error` (auth expiry, rate limit, an unreachable proxy).
- **`last_poll` frozen minutes/hours in the past** — the adapter is *not
  looping at all*. It is parked inside a call that never returned, so it will
  never record an error or reach its next cycle. The section it feeds keeps
  serving whatever it last wrote, silently.

Every outbound call is now bounded (`GH_TIMEOUT`, `HTTP_TIMEOUT`,
`HTTP_CONNECT_TIMEOUT`), so a frozen `last_poll` should no longer be
reachable — the call fails, the error is recorded, and the loop continues. If
you do see one, look for an orphaned child holding the loop open:

```bash
# gh children of the hub, with elapsed time
ps -eo pid,ppid,etime,command | grep "[g]h "
pgrep -f decknix-hub          # the parent pid to match against
```

Killing the hung child releases the loop immediately; the adapter records the
failure and resumes on its next cycle. This was a real 24h outage on
2026-08-27: a dropped link left two `gh` children hung, freezing
`github-reviews.json` and `github-wip.json` while TeamCity kept updating
normally.

## Data Files

All state is stored in `~/.config/decknix/hub/`:

| File | Content |
|------|---------|
| `github-reviews.json` | PR reviews needing your attention (per-PR attention signals — `my_review`, `others_reviewed`, `re_requested`, `comment_mentioned`, `review_stale`, `review_decision` — drive the sidebar's [reviewed filter](../modules/ai/agent-shell/layouts/requests.md#the-reviewed-filter-r)) |
| `github-wip.json` | Your open PRs, and merged ones within `mergedRetentionDays`, with CI status and branches. `state` is upper case (`OPEN`, `MERGED`). `errors` lists queries that failed this poll without failing it. Each PR carries `author`, `head_sha` and `merge_state` (GitHub's `mergeStateStatus`), and with `mergeReadyNotify` a `merge_ready` object (`verdict`, `comments`, `delivery`: `sent`, `no-session`, `no-receiver` or `failed`, and `session` once sent) |
| `merge-ready-state.json` | With `mergeReadyNotify`: which (head SHA, verdict) each open PR was already sent for, and the last undelivered attempt |
| `jira-tasks.json` | Jira issues assigned to you and not Done (`items`), to pick up (`pick_up`), their true counts (`in_progress_total`, `pick_up_total`), the `projects` and `pick_up_projects` used, and `errors` |
| `github-issues.json` | Open GitHub issues assigned to you |
| `task-chores.json` | Pending Taskwarrior chores |
| `teamcity-builds.json` | TeamCity build status for WIP branches |
| `kargo-stages.json` | Per merged PR in a Kargo repo (one entry per `region` when configured per region): `stages`, `reached` (holding the merge and verified, now or by the freight verified before the current one), `promoting` (a promotion running), `verifying` (holding the merge, verification not passed yet), `failed`, `manual` (stages without auto-promotion in the project's ProjectConfig; absent when the policies could not be read), and `verified_at` once the last stage verified it; `errors` when kargo failed |
| `meta.json` | Adapter health: last poll time, errors |

Each adapter writes independently — a slow Jira poll won't block GitHub
data from refreshing.

That independence is per-adapter only: within one adapter, a single call that
never returns stops that adapter's whole loop. Every outbound call is therefore
bounded — `gh` invocations by `GH_TIMEOUT` (with `kill_on_drop`, so a timed-out
child is killed rather than leaked), and HTTP by `HTTP_TIMEOUT` /
`HTTP_CONNECT_TIMEOUT`. `reqwest::Client::new()` applies no timeout by default,
so adapters must build their client via `crate::http_client()`.

## Future Adapters (Planned)

- **Slack** — unread mentions requiring follow-up
- **macOS notifications** — new reviews, CI failures
