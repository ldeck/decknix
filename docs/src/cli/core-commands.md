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
decknix switch --override decknix=~/tools/decknix

# Override multiple inputs (repeat the flag)
decknix switch --override decknix=~/tools/decknix --override nc-config=~/Code/my-org/decknix-config
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
   daemon against the active profile. A changed Emacs binary requires a
   restart; changed Elisp is hot-reloaded without restarting. If the reload
   has not completed yet, the status says so and suggests `C-c D r` if it
   stays stale. If the daemon does not answer within five seconds, the
   status is unknown rather than claiming that a restart is needed. This
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
decknix = "~/tools/decknix"
nc-config = "~/Code/my-org/decknix-config"
```

Every `decknix switch` then applies those overrides by default. Precedence,
from highest to lowest:

1. `--override INPUT=PATH` on the command line (per-input; wins over config)
2. `[switch.overrides]` in `settings.toml`
3. The published flake inputs (from `flake.lock`)

The status line annotates each override with `[config]` when it came from
`settings.toml`, so it's always clear where a given path was sourced from:

```
🔄 Switching (decknix=/Users/you/tools/decknix [config], nc-config=/Users/you/Code/foo/decknix-config [config])...
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
should not be checked into a shared `decknix-config` repo. If your
`decknix-config` doesn't already ignore it, add it:

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
  list    List sessions in a workspace (default: current directory)
  resume  Resume a session (exec into the agent by default)
  new     Start a new session (exec into the agent by default)
  tag     Add or remove tags on a session's conversation
  tags    List all known tags with usage counts
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

# Claude sessions tagged #dos touched in the last day, as JSON
decknix session list --agent claude --tag dos --since 1d --json

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

# Resume the latest session tagged #dos in this workspace
decknix session resume --tag dos

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
decknix session new --tag dos --tag triage -- "Investigate ALR-5752"
```

### `decknix session tag` / `decknix session tags`

Add or remove tags on a conversation, or list every known tag with usage counts.

```bash
# Tag / untag a conversation (by id or unique prefix)
decknix session tag d8df9eb9 --add dos --add day5
decknix session tag d8df9eb9 --remove day5

# List all known tags with counts (--json for machine output)
decknix session tags
decknix session tags --json
```

> Tags are shared with the Emacs session tooling (`C-c A T`), so a session
> tagged here appears under that tag in the sidebar and pickers — and the agents
> the DoS board spawns on a ticket can be found and resumed later by tag.

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
decknix wt list --repo UpsideRealty/pubsub-dlq-forwarder

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

