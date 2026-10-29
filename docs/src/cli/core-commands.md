# Core Commands

## `decknix switch`

Build and activate your configuration.

```
Usage: decknix switch [OPTIONS]

Options:
    --dry-run                    Build only — don't activate
    --force                      Bypass the preflight equality check and always activate
    --override <INPUT=PATH>      Override a flake input with a local path (repeatable)
    --no-overrides               Ignore [switch.overrides] in settings.toml
```

### Examples

```bash
# Normal switch (skips sudo activation if nothing changed)
decknix switch

# Dry run (check for errors without activating)
decknix switch --dry-run

# Force re-activation even when the built system matches the current one
decknix switch --force

# Test a local framework checkout
decknix switch --override decknix=~/path/to/decknix

# Override multiple inputs (repeat the flag)
decknix switch --override decknix=~/path/to/decknix --override my-org=~/Code/my-org/my-org-config
```

### How It Works

1. `cd ~/.config/decknix`
2. **Preflight** (unless `--dry-run` or `--force`): evaluates the system
   derivation via `nix build --no-link --print-out-paths` and compares the
   resulting store path with `readlink /run/current-system`.
   - **Match** → skips `sudo darwin-rebuild switch` entirely, verifies user
     LaunchAgents (`org.nixos.*`) are running, kickstarts any that are down,
     and exits.
   - **Differ** → prints old/new store paths and proceeds with activation.
3. Runs `sudo darwin-rebuild switch --flake .#default --impure` (reusing the
   cached preflight build).
4. For each active override (CLI or `settings.toml`), adds
   `--override-input <INPUT> path:<PATH>`.
5. With `--dry-run`, uses `build` instead of `switch` and skips the preflight.
6. After a successful switch (including a no-op), checks the running Emacs
   daemon against the active profile. A changed Emacs binary **or Elisp**
   triggers a prominent restart recommendation. Automatic hot reload is
   disabled because unloading native-compiled code while timers are active
   crashed a live daemon. If the daemon does not answer within five seconds,
   the status is unknown rather than claiming that a restart is needed. This
   check never restarts the daemon or interrupts agent sessions. A dry run
   does not perform this check.

If a restart is actually required, the output prints the launchctl command.
After installing a new version of the `decknix` CLI, the *next* invocation
will display this status because the invocation that installed it is still
running the old CLI binary.

### Why the preflight

Once you've applied a configuration, re-running `decknix switch` with no code
changes should be a fast no-op. The preflight lets Nix's evaluation cache do
the work (typically 1–3s) instead of paying for a full `sudo darwin-rebuild
switch` (30–90s of activation scripts). The `--force` flag is there for when
you deliberately want to re-run activation — for example, after manually
editing a launchd plist or when debugging an activation script.

### Persistent overrides via `settings.toml`

If you routinely run `decknix switch` with the same `--override` flags (e.g.
you keep local checkouts of the framework and your org config), you can pin
them once in `~/.config/decknix/settings.toml`:

```toml
[switch.overrides]
decknix = "~/path/to/decknix"
my-org = "~/Code/my-org/my-org-config"
```

Every `decknix switch` then applies those overrides by default. Precedence,
from highest to lowest:

1. `--override INPUT=PATH` on the command line (per-input; wins over config)
2. `[switch.overrides]` in `settings.toml`
3. The published flake inputs (from `flake.lock`)

The status line annotates each override with `[config]` when it came from
`settings.toml`, so it's always clear where a given path was sourced from:

```
🔄 Switching (decknix=/Users/you/path/to/decknix [config], my-org=/Users/you/Code/my-org/my-org-config [config])...
```

To force a switch against the published inputs (ignoring `settings.toml`
entirely), pass `--no-overrides`:

```bash
# Ignore settings.toml — use whatever is pinned in flake.lock
decknix switch --no-overrides

# Ignore settings.toml but apply one one-off override
decknix switch --no-overrides --override decknix=~/experiments/decknix
```

`settings.toml` lives alongside your user config; it is a personal file and
should not be checked into a shared config repository. If your
user flake is a git repository and doesn't already ignore it, add it:

```gitignore
settings.toml
```

## `decknix update`

Update flake inputs (dependencies).

```
Usage: decknix update [INPUT]

Arguments:
    [INPUT]  Specific input to update (optional)
```

### Examples

```bash
# Update all inputs
decknix update

# Update only decknix
decknix update decknix

# Update only nixpkgs
decknix update nixpkgs
```

Runs `nix flake update [input]` under the hood. After updating, run `decknix switch` to apply.

## `decknix session`

Find, create, resume, and tag agent sessions from the terminal — the
workspace- and tag-aware CLI companion to the in-editor session tooling. It
resolves against the same session store the Emacs sidebar and pickers use
(Claude and Auggie), so a session you spawn in Emacs can be resumed here and
vice versa, and tags are shared both ways.

```
Usage: decknix session <COMMAND>

Commands:
  list     List sessions in a workspace (default: current directory)
  archive  Archive matching sessions: compress + index, then remove the original
  restore  Restore an archived session (decompress back to its original location)
  gc       Apply the retention policy: archive stale sessions, trash very old archives
  resume   Resume a session (exec into the agent by default)
  new      Start a new session (exec into the agent by default)
  tag      Add or remove tags on a session's conversation
  tags     List all known tags with usage counts
```

### `decknix session list`

List sessions (newest first), scoped to a workspace by default.

```
Options:
      --agent <AGENT>          claude, auggie, or all [default: all]
      --workspace <WORKSPACE>  Workspace to list (default: current directory)
      --all                    List across every workspace instead of just one
      --tag <TAGS>             Only sessions carrying this tag (repeatable; all must match)
      --grep <GREP>            Only sessions whose transcript matches this regex
      --since <SINCE>          Only sessions touched within a window (e.g. 7d, 12h, 30m)
      --limit <LIMIT>          Cap the number of rows
      --json                   Emit JSON instead of aligned columns
```

```bash
# Sessions in this workspace, all agents
decknix session list

# Claude sessions tagged #triage touched in the last day, as JSON
decknix session list --agent claude --tag triage --since 1d --json

# Everything across every workspace whose transcript matches a regex
decknix session list --all --grep "replay.dlq"
```

### `decknix session resume`

Resume a session — by id/prefix, by tag (the latest match), or the most recent
in scope. Execs into the agent by default; `-n`/`--print` prints the resolved
command instead of running it.

```
Usage: decknix session resume [OPTIONS] [ID]

Arguments:
  [ID]  Session id or unique prefix

Options:
      --agent <AGENT>          claude, auggie, or all [default: all]
      --tag <TAGS>             Resume the latest session carrying this tag (repeatable)
      --last                   Resume the most recently touched session in scope
      --workspace <WORKSPACE>  Workspace to resolve within (default: current directory)
      --all                    Resolve across every workspace
  -n, --print                  Print the resolved command instead of exec-ing it
```

```bash
# Resume by id prefix
decknix session resume d8df9eb9

# Resume the latest session tagged #triage in this workspace
decknix session resume --tag triage

# Resume the most recent session anywhere — just print the command
decknix session resume --last --all --print
```

### `decknix session new`

Start a new session, optionally with an initial prompt (everything after `--`)
and pre-applied tags.

```
Usage: decknix session new [OPTIONS] [-- <PROMPT>...]

Arguments:
  [PROMPT]...  Initial prompt (everything after `--`)

Options:
      --agent <AGENT>          claude or auggie [default: claude]
      --tag <TAGS>             Pre-tag the conversation (requires an initial prompt to key it)
      --workspace <WORKSPACE>  Workspace to start in (default: current directory)
      --model <MODEL>          Per-conversation model override
  -n, --print                  Print the resolved command instead of exec-ing it
```

```bash
# New Claude session in this workspace
decknix session new

# New session pre-tagged and seeded with a prompt
decknix session new --tag triage --tag incident -- "Investigate INC-123"
```

### `decknix session tag` / `decknix session tags`

Add or remove tags on a conversation, or list every known tag with usage counts.

```bash
# Tag / untag a conversation (by id or unique prefix)
decknix session tag d8df9eb9 --add triage --add day5
decknix session tag d8df9eb9 --remove day5

# List all known tags with counts (--json for machine output)
decknix session tags
decknix session tags --json
```

> Tags are shared with the Emacs session tooling (`C-c A T`), so a session
> tagged here appears under that tag in the sidebar and pickers, and agents
> spawned from a board on a ticket can be found and resumed later by tag.

## `decknix wt`

Manage git worktrees across all your repos from one place. decknix keeps a
registry of every worktree it knows about (used by the Emacs sidebar too), and
`decknix wt` inspects and cleans that set — handy when agent work spins up many
short-lived worktrees.

```
Usage: decknix wt <COMMAND>

Commands:
  list                List all worktrees from the registry
  refresh             Re-probe worktrees and update the cache
  audit               Dry-run report: stale / dirty / orphan-fork / branch-deleted-upstream
  orphans             List worktrees whose upstream branch has been deleted
  clean               Clean up old merged worktrees
  prune               Expunge stale worktrees (directory + branch + metadata + fork-remotes)
  prune-metadata      Prune git worktree metadata only
  clean-fork-remotes  Sweep orphan fork remotes
  registry            Dump the registry
  finished            Remove worktrees whose PR is merged or closed (by GitHub's PR state)
```

Most cleanup verbs are **dry-run by default** — they report what they would do
and only act when you add `--apply`.

```
Common options (audit / clean / orphans / prune):
  -r, --regex <REGEX>            Match against repo identifier or worktree path
      --older-than <OLDER_THAN>  Only worktrees older than a window (e.g. 7d, 12h, 30m)
      --apply                    Actually perform the deletion (else dry-run)
      --json                     Machine-readable output (list / audit / orphans)
```

```bash
# See every worktree decknix tracks (optionally one repo)
decknix wt list
decknix wt list --repo my-org/my-service

# Dry-run health report: stale, dirty, orphaned, upstream-branch-deleted
decknix wt audit
decknix wt audit --json

# Worktrees whose upstream branch was deleted (e.g. after a merged PR)
decknix wt orphans

# Remove old, MERGED worktrees — preview, then apply
decknix wt clean --older-than 7d
decknix wt clean --older-than 7d --apply

# Full sweep of stale worktrees (dir + branch + metadata + fork remotes)
decknix wt prune --apply --safe-delete-branch
```

`decknix wt finished` complements the git-based verbs: it asks GitHub for each
worktree's PR state, so it also catches review worktrees (`pr-N`, detached) and
squash- or rebase-merged PRs that `clean` cannot see. It keeps anything with
uncommitted changes, commits not in the PR, or an open session.

```bash
decknix wt finished            # preview
decknix wt finished --apply
```

## `decknix session archive` / `restore` / `gc`

Session transcripts grow without bound. `archive` compresses matching sessions
into an indexed archive and removes the originals; `restore` puts one back
where it came from; `gc` applies the retention policy from the `[session]`
table of `~/.config/decknix/settings.toml` (archive stale sessions, trash very
old archives). The weekly `decknix-session-gc` launchd agent runs `gc` for you
(see [Background Services](../modules/services.md)).

```bash
decknix session archive --older-than 4w --dry-run
decknix session archive --larger-than 50M
decknix session restore d8df9eb9
decknix session gc --dry-run
```

## `decknix repos`

Keeps the primary checkout of every clone in your workspaces fresh: fetches
and fast-forwards each repo's default branch, never touching dirty trees or a
checked-out feature branch. Workspaces come from `--workspace [ORG=]PATH`,
then `[repos].workspaces` in `settings.toml`, then the Nix option
`decknix.cli.repos.workspaces` (an org config can declare its workspace
there), and failing all three, `~/Code`. The `decknix-repo-sync` launchd
agent runs `sync` every three hours.

```bash
decknix repos list             # local only: what sync would consider
decknix repos sync --dry-run
decknix repos sync --workspace my-org=~/Code/my-org
decknix repos fix-lock ~/Code/my-org/my-service   # remove index.lock only when provably abandoned
```

## `decknix pull-local-changes`

Agent skills and commands are deployed as real, editable copies (see
[agent-sync](../modules/ai/configuration.md)). When you edit a deployed copy,
`pull-local-changes` copies the edit back to the source repository it came
from. It previews by default; `--apply` copies and commits, and `--force`
pulls even when the deployed copy looks older than the committed source.

Each file names its repository; the checkout for that name comes from
`decknix.cli.agentSync.repoRoots`, then a `[switch.overrides]` entry of the
same name in `settings.toml`. `decknix` itself defaults to `~/tools/decknix`
(or `$DECKNIX_DEV`).

```bash
decknix pull-local-changes
decknix pull-local-changes --apply --message "docs(skills): clarify the review step"
```

## `decknix help`

Show help for all commands, including dynamically discovered extensions.

```bash
# Show all commands
decknix help

# Help for a specific command or extension
decknix help switch
decknix help board
```

Extensions show their description and underlying command.

