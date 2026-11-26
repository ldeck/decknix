# CLI reference

<!-- Generated from the clap definitions in cli/src by the `cli_reference` test. Do not edit by hand. -->

Every built-in `decknix` command and its flags. Extensions registered through
`extensions.json` are listed by `decknix help` on each machine and are not shown here.

## `decknix`

```text
The Decknix Framework CLI

Usage: decknix [COMMAND]

Commands:
  update              Update flake inputs
  switch              Switch system configuration
  wt                  Manage git worktrees
  session             Find, create, and resume Claude sessions (workspace + tag aware)
  repos               Keep local clones fresh: fetch + fast-forward each repo's default branch
  hub                 Settings the decknix-hub daemon reads at runtime (no rebuild needed)
  secrets             Store credentials in the OS keychain (never inside ~/.config/decknix)
  pull-local-changes  Pull local changes to agent skills/commands back into repositories
  help

Options:
  -h, --help
          Print help
```

## `decknix update`

```text
Update flake inputs

Usage: decknix update [INPUT]

Arguments:
  [INPUT]
          Specific input to update

Options:
  -h, --help
          Print help
```

## `decknix switch`

```text
Switch system configuration

Usage: decknix switch [OPTIONS]

Options:
      --dry-run
          Build only — don't activate (uses darwin-rebuild build instead of switch)

      --force
          Bypass the preflight equality check and always run darwin-rebuild switch. Useful when you want to re-run activation scripts even though the built system derivation is already the currently-active one

      --override <INPUT=PATH>
          Override flake input(s) with local paths (repeatable, INPUT=PATH). Example: --override decknix=~/Code/me/decknix --override my-org=~/Code/my-org/my-org-config

      --no-overrides
          Ignore the [switch.overrides] table in ~/.config/decknix/settings.toml. Only overrides supplied on the CLI (if any) will be applied, so the switch resolves against the published flake inputs

      --restart-emacs
          Also restart the Emacs daemon and bring every window and agent session back: saves the layout first, switches, restarts the daemon (only if the switch succeeded and Emacs is behind the profile), opens a frame, restores without prompting and prints what came back

  -h, --help
          Print help
```

## `decknix wt`

```text
Manage git worktrees

Usage: decknix wt <COMMAND>

Commands:
  list                List all worktrees from the registry
  refresh             Re-probe worktrees and update the cache
  prune-metadata      Prune git worktree metadata (only)
  prune               Expunge stale worktrees (full sweep: directory + branch + metadata + fork-remotes)
  clean-fork-remotes  Sweep orphan fork remotes
  registry            Dump the registry
  audit               Dry-run report: stale / dirty / orphan-fork / branch-deleted-upstream
  orphans             List worktrees whose upstream branch has been deleted
  finished            Remove worktrees whose PR is merged or closed (by GitHub's PR state)
  clean               Clean up old merged worktrees

Options:
  -h, --help
          Print help
```

## `decknix wt list`

```text
List all worktrees from the registry

Usage: decknix wt list [OPTIONS]

Options:
      --repo <REPO>
          Filter by owner/repo

  -h, --help
          Print help
```

## `decknix wt refresh`

```text
Re-probe worktrees and update the cache

Usage: decknix wt refresh [OPTIONS]

Options:
      --repo <REPO>
          Specific repo to refresh

  -h, --help
          Print help
```

## `decknix wt prune-metadata`

```text
Prune git worktree metadata (only)

Usage: decknix wt prune-metadata [OPTIONS]

Options:
      --repo <REPO>
          Specific repo to prune metadata

  -h, --help
          Print help
```

## `decknix wt prune`

```text
Expunge stale worktrees (full sweep: directory + branch + metadata + fork-remotes)

Usage: decknix wt prune [OPTIONS]

Options:
      --apply
          Actually perform the deletion

      --paths-file <PATHS_FILE>
          Only include these worktree paths (file with one path per line)

      --safe-delete-branch
          Use 'git branch -d' instead of '-D'

      --force
          Pass --force to 'git worktree remove' (removes a dirty or locked worktree)

  -r, --regex <REGEX>
          Regex matched against repo identifier or worktree path

      --older-than <OLDER_THAN>
          Only include worktrees whose mtime is older than this (e.g. 7d, 12h, 30m)

  -h, --help
          Print help
```

## `decknix wt clean-fork-remotes`

```text
Sweep orphan fork remotes

Usage: decknix wt clean-fork-remotes [OPTIONS]

Options:
      --dry-run
          Don't actually delete

  -h, --help
          Print help
```

## `decknix wt registry`

```text
Dump the registry

Usage: decknix wt registry [OPTIONS]

Options:
      --json
          Output in JSON format

  -h, --help
          Print help
```

## `decknix wt audit`

```text
Dry-run report: stale / dirty / orphan-fork / branch-deleted-upstream

Usage: decknix wt audit [OPTIONS]

Options:
      --json
          Output in JSON format

  -r, --regex <REGEX>
          Regex matched against repo identifier or worktree path

      --older-than <OLDER_THAN>
          Only include worktrees whose mtime is older than this (e.g. 7d, 12h, 30m)

      --clean
          Remove matching worktrees (use --apply to actually delete; otherwise dry-run)

      --apply
          Actually perform the deletion (only meaningful with --clean)

  -h, --help
          Print help
```

## `decknix wt orphans`

```text
List worktrees whose upstream branch has been deleted

Usage: decknix wt orphans [OPTIONS]

Options:
      --json
          Output in JSON format

  -r, --regex <REGEX>
          Regex matched against repo identifier or worktree path

      --older-than <OLDER_THAN>
          Only include worktrees whose mtime is older than this (e.g. 7d, 12h, 30m)

      --clean
          Remove matching orphan worktrees (use --apply to actually delete)

      --apply
          Actually perform the deletion (only meaningful with --clean)

  -h, --help
          Print help
```

## `decknix wt finished`

```text
Remove worktrees whose PR is merged or closed (by GitHub's PR state)

Covers review worktrees (`pr-N`, detached) and squash- or rebase-merged or closed PRs of your own, which the git-based verbs cannot see.  Keeps anything with uncommitted changes, commits not in the PR, or an open session.  Previews unless --apply is given.

Usage: decknix wt finished [OPTIONS]

Options:
      --json
          Output the plan as JSON

  -r, --regex <REGEX>
          Regex matched against repo identifier or worktree path

      --older-than <OLDER_THAN>
          Only include worktrees whose mtime is older than this (e.g. 7d, 12h, 30m)

      --apply
          Actually remove the worktrees marked for removal

  -h, --help
          Print help (see a summary with '-h')
```

## `decknix wt clean`

```text
Clean up old merged worktrees

Usage: decknix wt clean [OPTIONS]

Options:
  -r, --regex <REGEX>
          Regex matched against repo identifier or worktree path

      --older-than <OLDER_THAN>
          Only include worktrees whose mtime is older than this (e.g. 7d, 12h, 30m)

      --orphans
          Restrict to orphan worktrees (upstream branch deleted), ignoring --older-than default

      --apply
          Actually perform the deletion

  -h, --help
          Print help
```

## `decknix session`

```text
Find, create, and resume Claude sessions (workspace + tag aware)

Usage: decknix session <COMMAND>

Commands:
  list      List sessions in a workspace (default: current directory)
  find      Find sessions by tag(s), buffer name, id or id prefix, or workspace; live first. Lists every match; on a miss, the closest sessions
  status    Show what a live session is doing: state, busy time, last activity, current tool, closing text, queue
  send      Send a message to a live session (delivered by the Emacs dispatch receiver)
  spawn     Start a lane in Emacs in the background, or report the live session already carrying these tags, or resume the saved one (idempotent)
  retire    Quit one live lane once it is idle; its saved record stays, so a later spawn with the same tags resumes it
  dispatch  Inspect or switch the Emacs dispatch receiver
  message   Show a sent message's receipt chain (queued, delivered, answered, or why not)
  watch     Block until messages are delivered or answered (run it in the background)
  inbox     Notices about messages this session sent with --notify
  archive   Archive matching sessions: compress + index, then remove the original
  restore   Restore an archived session (decompress back to its original location)
  gc        Apply the retention policy: archive stale sessions, trash very old archives
  resume    Resume a session (exec into the agent by default)
  new       Start a new session (exec into the agent by default)
  tag       Add or remove tags on a session's conversation
  link-pr   Link a GitHub PR to a session's conversation, as the sidebar's "linked PRs" (idempotent: an existing link of that PR is kept)
  tags      List every tag with its session count, live count and sessions; spellings that differ only in case or separators are grouped
  engines   List available engine rooms (capability/cost tiers) and live quota status

Options:
  -h, --help
          Print help
```

## `decknix session list`

```text
List sessions in a workspace (default: current directory)

Usage: decknix session list [OPTIONS]

Options:
      --agent <AGENT>
          Which agent(s): claude, auggie, pi, or all

          [default: all]

      --workspace <WORKSPACE>
          Workspace to list (default: current directory, or every workspace when --tag or --grep is given)

      --all
          List across every workspace instead of just one

      --tag <TAGS>
          Only sessions carrying this tag (repeatable or comma-separated; all must match; case, `#`, separators and leading zeros are ignored)

      --grep <GREP>
          Only sessions whose transcript matches this regex

      --since <SINCE>
          Only sessions touched within this window (e.g. 7d, 12h, 30m)

      --limit <LIMIT>
          Cap the number of rows

      --archived
          Show only archived sessions (from the compressed archive index)

      --include-archived
          Include archived sessions alongside active ones

      --json
          Emit JSON instead of aligned columns

      --live
          List the sessions live in Emacs right now, with their state (working, background, asking, idle, ...), from the exported state files

  -h, --help
          Print help
```

## `decknix session find`

```text
Find sessions by tag(s), buffer name, id or id prefix, or workspace; live first. Lists every match; on a miss, the closest sessions

Usage: decknix session find [OPTIONS] <QUERY>...

Arguments:
  <QUERY>...
          Tags (`lane-04,PLAT-1342`, `lane-04/PLAT-1342`, or several words, all must match), a buffer name, an id or 6+ char id prefix, or a path

Options:
      --live
          Live sessions only (exit 22 when only saved sessions match)

      --all
          Live and saved sessions together (default: saved only when no live one matches)

      --id
          Print only the full id of the single match (exit 21 when ambiguous)

      --json
          Emit JSON

  -h, --help
          Print help
```

## `decknix session status`

```text
Show what a live session is doing: state, busy time, last activity, current tool, closing text, queue

Usage: decknix session status [OPTIONS] <TARGET>

Arguments:
  <TARGET>
          Session id, id prefix, buffer name, or tag(s) only one live session carries

Options:
      --json
          Emit JSON

  -h, --help
          Print help
```

## `decknix session send`

```text
Send a message to a live session (delivered by the Emacs dispatch receiver)

Usage: decknix session send [OPTIONS] <TARGET>

Arguments:
  <TARGET>
          Session id, id prefix, buffer name, or tag(s) only one live session carries

Options:
  -m, --message <MESSAGE>
          The message text

      --message-file <MESSAGE_FILE>
          Read the message from a file

      --stdin
          Read the message from stdin

      --when <WHEN>
          idle: deliver when the session's turn ends (default); now: only if idle, else print its state and exit 13; interrupt: cancel its turn first (needs --reason, subject to the interrupt policy)

          [default: idle]

      --ttl <TTL>
          Expiry (e.g. 30m, 24h, 7d). Defaults: idle 24h, interrupt 1h, now 60s

      --from <FROM>
          Sender session id (default: $DECKNIX_SESSION_ID or $CLAUDE_CODE_SESSION_ID)

      --reason <REASON>
          Why; shown in the receiving session's transcript (required for interrupt)

      --engine <ENGINE>
          Engine room tier to switch the target lane to before sending (e.g. flagship/v12, workhorse/v8, fast/v6, vertex, codex, utility/v4, local)

      --model <MODEL>
          Model to switch the target lane to before sending (overrides --engine)

      --notify
          Leave notices in the sender's inbox on delivered, answered and failure

      --wait-receipt <SECS>
          Wait up to this many seconds for delivery (or a refusal)

      --force
          Queue even when the receiver looks off (it refuses requests older than its arming) or the full id names no live session

      --json
          Emit JSON

  -h, --help
          Print help
```

## `decknix session spawn`

```text
Start a lane in Emacs in the background, or report the live session already carrying these tags, or resume the saved one (idempotent)

Usage: decknix session spawn [OPTIONS] --workspace <WORKSPACE> --tag <TAGS> [-- <BRIEF>...]

Arguments:
  [BRIEF]...
          The brief (everything after `--`)

Options:
      --workspace <WORKSPACE>
          Workspace directory the session starts in (must exist)

      --tag <TAGS>
          Tags the lane carries (comma-separated or repeated); all must match for an existing session to count as this lane

      --engine <ENGINE>
          Engine room tier (flagship/v12, workhorse/v8, fast/v6, vertex, vertex-fast, utility/v4, codex, codex-fast, local)

      --agent <AGENT>
          Which agent: claude, auggie or pi (defaults to --engine's agent, else claude)

      --name <NAME>
          Buffer name (default: the tags joined with `/`)

      --model <MODEL>
          Model the session starts on (defaults to --engine's model)

      --mode <MODE>
          Permission/session mode (e.g. Claude `auto` or `bypassPermissions`)

      --brief-file <BRIEF_FILE>
          Read the brief (the first message) from a file

      --stdin
          Read the brief from stdin

      --queue
          Write the request even while the receiver is off; it runs after `decknix session dispatch on --release-queued`

      --no-resume
          Start a fresh session even when a saved one carries the tags

      --wait <SECS>
          Seconds to wait for the session id (0: print the request id and return)

          [default: 180]

      --ttl <TTL>
          Request expiry (e.g. 30m, 1h, max 24h)

          [default: 1h]

      --from <FROM>
          Sender session id (default: $DECKNIX_SESSION_ID or $CLAUDE_CODE_SESSION_ID)

      --json
          Emit JSON

  -h, --help
          Print help
```

## `decknix session retire`

```text
Quit one live lane once it is idle; its saved record stays, so a later spawn with the same tags resumes it

Usage: decknix session retire [OPTIONS] <TARGET>

Arguments:
  <TARGET>
          Full session id, buffer name, or the exact tags only it carries

Options:
      --reason <REASON>
          Why; recorded with the request

      --force
          Do not wait for the turn to end (unsent typed input still refuses)

      --wait <SECS>
          Seconds to wait for the outcome

          [default: 60]

      --json
          Emit JSON

  -h, --help
          Print help
```

## `decknix session dispatch`

```text
Inspect or switch the Emacs dispatch receiver

Usage: decknix session dispatch <COMMAND>

Commands:
  status  Is the Emacs dispatch receiver on? Heartbeat age, who armed it, whether the control watcher runs, lanes against the spawn cap, request counts (exit 0 on, 14 off, 15 no fresh heartbeat)
  on      Turn the receiver on through the control watcher (ask the human first)
  off     Turn the receiver off; waiting messages are settled `not-sent`

Options:
  -h, --help
          Print help
```

## `decknix session dispatch status`

```text
Is the Emacs dispatch receiver on? Heartbeat age, who armed it, whether the control watcher runs, lanes against the spawn cap, request counts (exit 0 on, 14 off, 15 no fresh heartbeat)

Usage: decknix session dispatch status [OPTIONS]

Options:
      --json
          Emit JSON

  -h, --help
          Print help
```

## `decknix session dispatch on`

```text
Turn the receiver on through the control watcher (ask the human first)

Usage: decknix session dispatch on [OPTIONS]

Options:
      --release-queued
          Also release spawns queued with `spawn --queue` before arming

      --wait <SECS>
          Seconds to wait for the watcher to apply it

          [default: 15]

  -h, --help
          Print help
```

## `decknix session dispatch off`

```text
Turn the receiver off; waiting messages are settled `not-sent`

Usage: decknix session dispatch off [OPTIONS]

Options:
      --wait <SECS>
          Seconds to wait for the watcher to apply it

          [default: 15]

  -h, --help
          Print help
```

## `decknix session message`

```text
Show a sent message's receipt chain (queued, delivered, answered, or why not)

Usage: decknix session message [OPTIONS] <ID>

Arguments:
  <ID>
          Message id printed by `send`

Options:
      --json
          Emit JSON

  -h, --help
          Print help
```

## `decknix session watch`

```text
Block until messages are delivered or answered (run it in the background)

Usage: decknix session watch [OPTIONS] [IDS]...

Arguments:
  [IDS]...
          Message ids printed by `send`

Options:
      --until <UNTIL>
          delivered or answered

          [default: answered]

      --timeout <TIMEOUT>
          Give up after this long (e.g. 30m, 2h)

          [default: 2h]

      --json
          Emit JSON lines

  -h, --help
          Print help
```

## `decknix session inbox`

```text
Notices about messages this session sent with --notify

Usage: decknix session inbox [OPTIONS]

Options:
      --session <SESSION>
          Whose inbox (default: $DECKNIX_SESSION_ID or $CLAUDE_CODE_SESSION_ID)

      --json
          Emit JSON

      --clear
          Remove the notices shown

  -h, --help
          Print help
```

## `decknix session archive`

```text
Archive matching sessions: compress + index, then remove the original

Usage: decknix session archive [OPTIONS]

Options:
      --agent <AGENT>
          Which agent(s): claude, auggie, pi, or all

          [default: all]

      --older-than <OLDER_THAN>
          Only sessions older than this (e.g. 4w, 3mo, 30d). Default: [session].archive_after

      --larger-than <LARGER_THAN>
          Only sessions larger than this (e.g. 50M, 500k)

      --tag <TAGS>
          Only sessions carrying this tag (repeatable; all must match)

      --workspace <WORKSPACE>
          Only sessions in this workspace

      --from <FROM>
          Ingest session files from this directory instead of the agent's live dir

      --dry-run
          Show what would be archived without doing it

      --json
          Emit JSON

  -h, --help
          Print help
```

## `decknix session restore`

```text
Restore an archived session (decompress back to its original location)

Usage: decknix session restore [OPTIONS] <ID>

Arguments:
  <ID>
          Session id or unique prefix

Options:
      --agent <AGENT>
          Which agent(s) to search: claude, auggie, pi, or all

          [default: all]

      --json
          Emit the restored session as JSON (id, provider, restoredPath, workspace, tags) so callers (e.g. the Emacs picker) can act on it

  -h, --help
          Print help
```

## `decknix session gc`

```text
Apply the retention policy: archive stale sessions, trash very old archives

Usage: decknix session gc [OPTIONS]

Options:
      --dry-run
          Show the plan without changing anything

      --json
          Emit JSON

  -h, --help
          Print help
```

## `decknix session resume`

```text
Resume a session (exec into the agent by default)

Usage: decknix session resume [OPTIONS] [ID]

Arguments:
  [ID]
          Session id or unique prefix; else tag(s) or a buffer name only one session carries

Options:
      --agent <AGENT>
          Which agent(s) to resolve within: claude, auggie, pi, or all

          [default: all]

      --tag <TAGS>
          Resume the latest session carrying this tag (repeatable; all must match)

      --last
          Resume the most recently touched session in scope

      --workspace <WORKSPACE>
          Workspace to resolve within (default: current directory)

      --all
          Resolve across every workspace

  -n, --print
          Print the resolved command instead of exec-ing it

  -h, --help
          Print help
```

## `decknix session new`

```text
Start a new session (exec into the agent by default)

Usage: decknix session new [OPTIONS] [-- <PROMPT>...]

Arguments:
  [PROMPT]...
          Initial prompt (everything after `--`)

Options:
      --agent <AGENT>
          Which agent: claude, auggie or pi

          [default: claude]

      --tag <TAGS>
          Pre-tag the conversation (requires an initial prompt to key it)

      --workspace <WORKSPACE>
          Workspace to start in (default: current directory)

      --model <MODEL>
          Per-conversation model override

  -n, --print
          Print the resolved command instead of exec-ing it

  -h, --help
          Print help
```

## `decknix session tag`

```text
Add or remove tags on a session's conversation

Usage: decknix session tag [OPTIONS] <ID>

Arguments:
  <ID>
          Session id or unique prefix; else tag(s) or a buffer name only one session carries

Options:
      --agent <AGENT>
          Which agent(s) to resolve within: claude, auggie, pi, or all

          [default: all]

      --add <ADD>
          Tag to add (repeatable)

      --remove <REMOVE>
          Tag to remove (repeatable)

  -h, --help
          Print help
```

## `decknix session link-pr`

```text
Link a GitHub PR to a session's conversation, as the sidebar's "linked PRs" (idempotent: an existing link of that PR is kept)

Usage: decknix session link-pr [OPTIONS] <SESSION> <URL>

Arguments:
  <SESSION>
          Session id or unique prefix; else tag(s) or a buffer name only one session carries

  <URL>
          The PR URL (https://github.com/OWNER/REPO/pull/N)

Options:
      --agent <AGENT>
          Which agent(s) to resolve within: claude, auggie, pi, or all

          [default: all]

      --added <ADDED>
          Provenance recorded on the link: auto, hook or manual

          [default: auto]

  -h, --help
          Print help
```

## `decknix session tags`

```text
List every tag with its session count, live count and sessions; spellings that differ only in case or separators are grouped

Usage: decknix session tags [OPTIONS]

Options:
      --live
          Only tags carried by live sessions

      --json
          Emit JSON instead of aligned columns

  -h, --help
          Print help
```

## `decknix session engines`

```text
List available engine rooms (capability/cost tiers) and live quota status

Usage: decknix session engines [OPTIONS]

Options:
      --json
          Emit JSON

  -h, --help
          Print help
```

## `decknix repos`

```text
Keep local clones fresh: fetch + fast-forward each repo's default branch

Usage: decknix repos <COMMAND>

Commands:
  sync      Fetch + fast-forward the default branch of every clone in the configured workspaces (never touches dirty trees or the checked-out feature branch)
  fix-lock  Remove an abandoned `.git/index.lock', but only when it is provably abandoned: older than the staleness threshold AND with no git process live in the repo. Refuses otherwise, because deleting a live lock corrupts the index of whatever holds it
  list      List the clones that `sync` would consider, with current branch + status. Local only — does not touch the network

Options:
  -h, --help
          Print help
```

## `decknix repos sync`

```text
Fetch + fast-forward the default branch of every clone in the configured workspaces (never touches dirty trees or the checked-out feature branch)

Usage: decknix repos sync [OPTIONS]

Options:
      --workspace <[ORG=]PATH>
          Workspace root(s) to scan (repeatable). Accepts `PATH` or `org=PATH`. Defaults to the `[repos].workspaces` setting

      --org <ORG>
          Only sync clones under the workspace labelled with this org

      --dry-run
          Report what would happen without fetching or updating anything

      --json
          Emit machine-readable JSON instead of a human summary

      --jobs <JOBS>
          Max concurrent repos (default: min(8, CPUs))

      --depth <DEPTH>
          Directory depth to scan under each root for `.git` clones (default 2)

      --only <NAME>
          Only sync clones whose directory name or path contains this string. Lets the sidebar retry one repo after clearing a lock, instead of waiting up to the 3h launchd interval for the whole sweep

  -h, --help
          Print help
```

## `decknix repos fix-lock`

```text
Remove an abandoned `.git/index.lock', but only when it is provably abandoned: older than the staleness threshold AND with no git process live in the repo. Refuses otherwise, because deleting a live lock corrupts the index of whatever holds it

Usage: decknix repos fix-lock [OPTIONS] <PATH>

Arguments:
  <PATH>
          Repository path (the working tree, not the `.git' dir)

Options:
      --older-than <OLDER_THAN>
          Seconds after which a lock counts as abandoned

          [default: 3600]

      --dry-run
          Report the decision without removing anything

      --json
          Emit machine-readable JSON

  -h, --help
          Print help
```

## `decknix repos list`

```text
List the clones that `sync` would consider, with current branch + status. Local only — does not touch the network

Usage: decknix repos list [OPTIONS]

Options:
      --workspace <[ORG=]PATH>


      --org <ORG>


      --depth <DEPTH>


      --json


  -h, --help
          Print help
```

## `decknix hub`

```text
Settings the decknix-hub daemon reads at runtime (no rebuild needed)

Usage: decknix hub <COMMAND>

Commands:
  jira-projects  Show or set the Jira project keys the Tasks section lists

Options:
  -h, --help
          Print help
```

## `decknix hub jira-projects`

```text
Show or set the Jira project keys the Tasks section lists

Usage: decknix hub jira-projects [OPTIONS] [KEYS]...

Arguments:
  [KEYS]...
          Project keys (space- or comma-separated); omit to show the current value

Options:
      --clear
          Remove the override and go back to the Nix-configured default

      --pick-up
          Act on the projects offered to pick up (`pick_up_projects`) instead

  -h, --help
          Print help
```

## `decknix secrets`

```text
Store credentials in the OS keychain (never inside ~/.config/decknix)

Usage: decknix secrets <COMMAND>

Commands:
  set      Store a secret, reading the value from stdin (or a hidden prompt on a terminal)
  get      Print a secret to stdout (no trailing newline unless stdout is a terminal)
  list     List the secrets known for an org and whether each is set (never values)
  rm       Remove a secret from the backend
  exec     Run a command with the named secrets in ITS environment only
  backend  Show the backend and keychain service an org uses
  migrate  Move raw secret files out of ~/.config/decknix into the backend

Options:
  -h, --help
          Print help
```

## `decknix secrets set`

```text
Store a secret, reading the value from stdin (or a hidden prompt on a terminal)

Usage: decknix secrets set [OPTIONS] <NAME>

Arguments:
  <NAME>


Options:
      --org <ORG>
          Org the secret belongs to (default $DECKNIX_SECRETS_ORG, else `local`)

  -h, --help
          Print help
```

## `decknix secrets get`

```text
Print a secret to stdout (no trailing newline unless stdout is a terminal)

Usage: decknix secrets get [OPTIONS] <NAME>

Arguments:
  <NAME>


Options:
      --org <ORG>


      --no-legacy
          Do not fall back to the deprecated file inside ~/.config/decknix

  -h, --help
          Print help
```

## `decknix secrets list`

```text
List the secrets known for an org and whether each is set (never values)

Usage: decknix secrets list [OPTIONS]

Options:
      --org <ORG>


  -h, --help
          Print help
```

## `decknix secrets rm`

```text
Remove a secret from the backend

Usage: decknix secrets rm [OPTIONS] <NAME>

Arguments:
  <NAME>


Options:
      --org <ORG>


  -h, --help
          Print help
```

## `decknix secrets exec`

```text
Run a command with the named secrets in ITS environment only

Usage: decknix secrets exec [OPTIONS] --secret <[VAR=]NAME> -- <COMMAND>...

Arguments:
  <COMMAND>...
          The command and its arguments, after `--`

Options:
      --org <ORG>


      --secret <[VAR=]NAME>
          Secret to inject, as NAME (variable NAME upper-snake-cased) or VAR=NAME; repeatable

  -h, --help
          Print help
```

## `decknix secrets backend`

```text
Show the backend and keychain service an org uses

Usage: decknix secrets backend [OPTIONS]

Options:
      --org <ORG>


  -h, --help
          Print help
```

## `decknix secrets migrate`

```text
Move raw secret files out of ~/.config/decknix into the backend

Usage: decknix secrets migrate [OPTIONS] --org <ORG>

Options:
      --org <ORG>
          Org to migrate; reads ~/.config/decknix/<org>/secrets/ by default

      --file <[NAME=]PATH>
          Also migrate one file, as PATH (name = file name) or NAME=PATH; repeatable

      --env-file <PATH>
          Also migrate a KEY=value env file; each KEY becomes a kebab-case name

      --keep
          Keep the old files after a verified copy

      --overwrite
          Replace a value already in the backend that differs from the file

      --dry-run
          Report what would move without writing or deleting anything

  -h, --help
          Print help
```

## `decknix pull-local-changes`

```text
Pull local changes to agent skills/commands back into repositories

Usage: decknix pull-local-changes [OPTIONS]

Options:
      --apply
          Actually perform the copies and commits

      --message <MESSAGE>
          Commit message (generated if not provided)

      --to <TO>
          Destination for new files (defaults to the org overlay for files in its workspace, else decknix)

      --force
          Pull files even when their content looks STALE (matches an older committed revision of the source, i.e. pulling would regress it)

  -h, --help
          Print help
```

## `decknix help`

```text
Usage: decknix help [SUBCOMMAND]

Arguments:
  [SUBCOMMAND]
          The command to look up

Options:
  -h, --help
          Print help
```
