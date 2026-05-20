# Worktree CLI (`decknix wt`) — cross-editor companion to the sidebar registry

> Owns: `cli/` `wt` subcommand. Shares state with the Emacs registry defined
> in [`sidebar-ret.md`](./sidebar-ret.md) §3.6.1.
> Tracks: #69. Depends on: #128 (registry).

## 1. Goal

Surface the same worktree operations the Emacs `w` submenu (#129) exposes to
**non-Emacs editors and the bare shell**, without duplicating state, so a vim
user, a `tmux` user, or an `emacsclient -e` script gets the same view of the
world Emacs sees in the sidebar.

The Emacs sidebar is the discovery surface; the CLI is the headless surface.
Both read from and update the same `~/.config/decknix/hub/worktrees.el`
cache so a worktree created via `decknix wt new` shows up in the sidebar on
the next file-notify tick (≤2 s) without an Emacs round-trip.

## 2. Non-goals

- **Daemon.** Worktree IO is on-demand. The polling daemon is `decknix-hub`'s
  job (PRs, CI, tasks); worktrees aren't network-bound and don't need it.
- **Replacing `git worktree`.** `wt` is a thin convenience layer that knows
  about the registry and the per-row defaults from §3.6.4. Power users keep
  using `git worktree` directly; the registry self-heals on next refresh.
- **Hosting fork-checkout logic in two places.** `wt new` shells out to
  `gh pr checkout` for fork PRs (same as the Emacs path) — no parallel
  reimplementation of GitHub auth.

## 3. Packaging

Land as a subcommand of the existing `decknix` Rust CLI in `cli/` (next to
`switch`, `update`). Rationale:

- One binary, one install, one PATH entry.
- Reuses the existing flake / nix-darwin module wiring.
- Discoverability: `decknix --help` lists `wt` next to the other ops.
- Sidesteps the "second flake" friction the user already pays elsewhere.

A bare `wt` shim alias gets installed when
`programs.decknix.wt.shortAlias = true` (default `true` for ergonomics).

## 4. Command surface

| Command                          | What it does                                                                  |
|----------------------------------|-------------------------------------------------------------------------------|
| `wt list [--repo OWNER/REPO]`    | All worktrees from the registry, optionally filtered.                         |
| `wt show [PATH]`                 | Detail for the worktree at PATH (defaults to `cwd`): branch, primary, status. |
| `wt new BRANCH [--repo R] [--from URL]` | Create a worktree at the §3.6.4 default sibling path.                  |
| `wt rm [PATH] [--force]`         | Remove worktree; runs the Q10 session-interlock check first.                  |
| `wt cd BRANCH`                   | Print the worktree path so `cd "$(wt cd BRANCH)"` works in shells.            |
| `wt status`                      | Combined `git status --porcelain=v2 --branch` for cwd worktree.               |
| `wt prune [--repo R]`            | `git worktree prune` for one repo or all.                                     |
| `wt clean-fork-remotes [--dry-run]` | Sweep orphan fork remotes (Q9, mirrors `M-x decknix-clean-fork-remotes`).  |
| `wt clean [--older-than D] [--apply]` | Remove worktrees with no session activity for D days, clean state, and merged branch.  Default `--dry-run`; `--apply` to act.  Always runs the §3.6.6 session-interlock per worktree. |
| `wt audit [--json]`              | Dry-run report: stale / dirty / orphan-fork-remote / branch-deleted-upstream / session-stranded worktrees across all clones. |
| `wt orphans [--json]`            | List worktrees whose branch is deleted upstream; safe-to-remove candidates.   |
| `wt refresh [--repo R]`          | Force re-probe (bypass 60 s TTL); useful after external `git worktree add`.   |
| `wt registry [--json]`           | Dump the registry; default elisp form, `--json` for shell consumers.          |

Every command exits non-zero on error and prints a single-line diagnostic to
`stderr` so it composes in shell pipelines.

## 5. Shared state

Single file, single owner per write — last-writer-wins is fine because the
file is a *cache*, not source of truth. Source of truth is always
`git worktree list --porcelain` per clone.

```
~/.config/decknix/hub/worktrees.el        # the cache (elisp s-expr, §3.6.1)
~/.config/decknix/hub/worktrees.lock      # advisory flock during writes
```

- **Format.** Elisp s-expression per §3.6.1 — Emacs reads it directly.
  `wt registry --json` converts on the fly for non-Emacs consumers; no
  separate JSON file is maintained, so there is no drift.
- **Locking.** Writes take an `flock` on the `.lock` file (≤500 ms) so two
  concurrent `wt new` invocations cannot corrupt the cache. Emacs uses the
  same lock when persisting from the registry refresh path.
- **Notification.** Writes `touch` the file even when contents are unchanged
  so the Emacs file-notify watcher (already running per §3.6.1) re-renders
  the sidebar.

## 6. Integration points

- **Shell completion.** `wt` ships completions for bash / zsh / fish derived
  from the registry (branches per repo) so `wt cd <TAB>` lists known
  branches with worktrees.
- **emacsclient.** `decknix wt cd BRANCH` works inside the Emacs daemon via
  `emacsclient -e`; the CLI is also safe to call from `M-x compile`.
- **`hx` / `nvim` plugin hook.** A trivial `wt cd` invocation is enough for
  vim users to wire `:Wt branch` in their config; no plugin is shipped, but
  `docs/` gets a one-paragraph snippet covering vim + tmux integration.
- **decknix-hub daemon.** Independent. Hub never writes the worktree cache.
  The CLI never reads hub JSON. They co-exist in the same dir for one
  reason: a single file-notify watcher covers both.

## 7. Failure modes

| Mode                                      | Behaviour                                                                |
|-------------------------------------------|--------------------------------------------------------------------------|
| Stale NFS mount / unresponsive `git`      | 5 s timeout per probe, registry entry marked `:stale t`, exit 2.         |
| Lock contention                           | Wait up to 1 s; on timeout, exit 75 (`EX_TEMPFAIL`) — caller can retry.  |
| Branch not in any worktree                | `wt cd` exits 1 with `no worktree for BRANCH; try: wt new BRANCH`.       |
| Removal blocked by live session           | Exits 1, lists offending session paths; `--force` opts into rewire path. |
| Fork-remote add fails                     | Worktree creation aborts, no partial state; remote left untouched.       |

## 8. Out of scope (deferred)

- TUI mode (`wt --tui`). The Emacs sidebar is the rich UI; `wt list | fzf`
  covers the terminal need without owning a TUI library.
- Cross-machine registry sync. The cache is per-machine — that is a feature.
- Auto-creating worktrees for `gh pr checkout` invoked outside `wt`. Detection
  on next refresh is sufficient; no shim around `gh`.

## 9. Spec linkage

- §3.6.1 — registry shape and TTL (Emacs side, also consumed here).
- §3.6.4 — verb semantics (CLI mirrors them 1:1).
- §3.6.6 — lifecycle hooks (CLI invokes the same fork-remote rule).
- §6 Q9 / Q10 — fork-remote and session-interlock resolutions.

## 10. Issues this spec creates

- **`feat(cli): wt subcommand — list / show / cd`** — read-only first slice
  off the registry. No git mutation. Lands after #128.
- **`feat(cli): wt new / rm / status`** — write path with the same
  session-interlock rule as #129 `x`. Lands after #129.
- **`feat(cli): wt prune / clean-fork-remotes / refresh`** — hygiene
  commands; mirrors #133.
- **`feat(cli): wt clean / audit / orphans — cross-worktree hygiene`** —
  surfaces the three audit verbs the Emacs side exposes via the
  `decknix-worktree-hygiene` transient (sidebar-ret.md §3.6.11).
  `wt clean` defaults to `--dry-run` and requires `--apply` to act;
  always runs the session-interlock per worktree.  `audit` and
  `orphans` are read-only and support `--json` for shell pipelines.
- **`docs(cli): wt integration — vim / tmux / shell snippets`** — picks up
  the README updates.
