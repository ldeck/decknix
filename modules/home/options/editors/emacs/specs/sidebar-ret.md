# Sidebar RET behaviour — spec (draft)

> Working draft. Review, mark rows ✅ / ❌ / ⚠️ / defer, and we'll fan out into
> one GitHub issue per accepted change. Not shipped docs.

## 1. Current state

The sidebar goes through `agent-shell-workspace-sidebar-goto`, wrapped by an
`:around` advice (`agent-shell.nix` line 6887) that dispatches by text property
on the line. Every row that should be actionable is expected to carry one of:

| Property                                                   | Set at                       | Dispatch                                                           |
|------------------------------------------------------------|------------------------------|--------------------------------------------------------------------|
| `decknix-hub-url` + `decknix-hub-type=review`              | Requests rows (11502)        | `decknix--open-url`                                                |
| `decknix-hub-url` + `decknix-hub-type=wip` + repo + number | WIP rows (11632)             | `decknix--nav-hub-item-actions` (rich transient)                   |
| `decknix-hub-url` + `decknix-hub-type=task`                | Tasks rows (11797)           | `decknix--open-url` (falls through to the `hub-url` branch)        |
| `decknix-previous-session`                                 | Previous-session rows (8834) | `decknix--sidebar-restore-previous-session`                        |
| `decknix-sidebar-saved-session`                            | Saved-session rows (6864)    | `decknix--agent-session-resume`                                    |
| `agent-shell-workspace-buffer`                             | Live-session rows (6776)     | original `agent-shell-workspace-sidebar-goto` (switches to buffer) |

## 2. Gap matrix

Row types actually produced by the render, with current RET outcome and the
**desired** RET outcome after your review pass. `M-RET` is reserved for a
quick "primary action" shortcut where relevant.

| Row                                                      | Today                                     | Desired RET                                              | Desired M-RET              | Status |
|----------------------------------------------------------|-------------------------------------------|----------------------------------------------------------|----------------------------|--------|
| Requests row                                             | Open URL                                  | Action menu (same as `r` picker → RET on item)           | Open here                  | ❌     |
| WIP row                                                  | Rich action transient                     | Action menu (keep current verbs, extend per §3.2)        | Open here                  | ⚠️     |
| Tasks (Jira) row                                         | Open URL                                  | Action menu (transition, align, comment, analyze, spec)  | Open here                  | ❌     |
| Live session row                                         | Switch to buffer                          | Action menu (session ops)                                | Switch to buffer           | ❌     |
| Live → linked PR (expanded)                              | **Nothing**                               | Action menu (authored vs subject aware)                  | Open here                  | ❌     |
| Live → linked repo (expanded)                            | **Nothing**                               | Action menu (repo ops, authored vs subject)              | Open branch on GitHub      | ❌     |
| Previous session row                                     | Restore session                           | Action menu (restore, delete, archive, merge, rename)    | Restore session            | ❌     |
| Previous → linked PR/repo (expanded)                     | **Nothing**                               | Action menu (same as live linked rows)                   | Open here                  | ❌     |
| Saved session row                                        | Resume session                            | Action menu (same as previous-session ops + resume)      | Resume session             | ❌     |
| Section header `Requests (N)`                            | Nothing                                   | Open `r` picker (same as footer `r` quick-key)           | —                          | ❌     |
| Section header `WIP (N)`                                 | Nothing                                   | Open `w` picker                                          | —                          | ❌     |
| Section header `Tasks (N)`                               | Nothing                                   | Open tasks picker (new)                                  | —                          | ❌     |
| Section header `Live (N)`                                | Nothing                                   | `C-c A b` (MRU buffer switcher)                          | —                          | ❌     |
| Section header `Sessions (N)`                            | Nothing                                   | `C-c A s` (session picker)                               | —                          | ❌     |
| Section header `Previous (N)`                            | Nothing                                   | `C-c A s` (session picker, previous group focused)       | —                          | ❌     |
| Workspace sub-header under Sessions                      | Nothing                                   | Action menu (AI config, open dir, project.el, scope…)    | Open workspace dir         | ❌     |
| `(none)` placeholder                                     | Nothing                                   | Quiet no-op                                              | —                          | ✅     |
| Footer keys / toggles lines                              | Nothing                                   | Quiet no-op                                              | —                          | ✅     |

**Decision collapsed out of the matrix:** RET on every actionable row opens an
action menu. `M-RET` (and the equivalent `C-u RET`) runs that row's primary
action directly — preserving the muscle memory of users who just want to open
a PR or switch to a live session. This supersedes the Option A / Option B
debate in §3.3.

## 3. Proposed spec

### 3.1 Unified RET contract

Every actionable row MUST carry enough text properties to resolve an action
**without re-scanning the rendered text**. The dispatcher becomes a thin
pattern-match that opens the row's action transient:

```
(cond
 ;; Hub rows — each type has its own transient (§3.2.1)
 ((wip-row-p)          (decknix--row-transient 'wip          …))
 ((review-row-p)       (decknix--row-transient 'review       …))
 ((task-row-p)         (decknix--row-transient 'task         …))
 ((linked-pr-row-p)    (decknix--row-transient 'linked-pr    …))
 ((linked-repo-row-p)  (decknix--row-transient 'linked-repo  …))
 ;; Session rows — shared transient, differ by :kind (§3.2.2)
 ((live-row-p)         (decknix--row-transient 'session :kind 'live …))
 ((previous-row-p)     (decknix--row-transient 'session :kind 'previous …))
 ((saved-row-p)        (decknix--row-transient 'session :kind 'saved …))
 ;; Section headers — route to the existing picker (§3.2.3)
 ((section-header-p)   (decknix--section-header-dispatch …))
 ;; Workspace sub-header — short transient (§3.2.4)
 ((workspace-header-p) (decknix--row-transient 'workspace …))
 (t (message "No action at point")))
```

**Primary-action shortcut.** `M-RET` (and `C-u RET`) bypasses the transient and
runs the row's primary action directly — for every row type this is what used
to happen on plain RET before this spec. The mapping is explicit in §2
(column "Desired M-RET"). This preserves muscle memory for "open the thing"
and "switch to the session" without the cost of a transient keystroke.

**Stable menu shape.** Two rows of the same type MUST open transients with the
same verbs in the same key positions, regardless of the row's current state
(worktree present or not, PR open or merged, session live or saved).
State-conditional verbs are **dimmed** (`transient`'s `:inapt-if`), not
hidden, so the user's muscle memory survives across rows and the menu doubles
as a discoverability aid: a dimmed `o` Open worktree on a no-worktree row
still teaches the user that `o` is the verb to remember once a worktree
exists. Verbs that are **categorically inapplicable** for a row type
(e.g. `m` Merge on a Linked Repo row) are absent from the matrix and from
the rendered transient — that is a row-type decision, not a state decision.
The row itself carries visual cues (§3.6.3) that advertise state at a
glance, so the dimmed verbs corroborate rather than reveal.

RET on an unpropertized line (placeholder, footer help) gives a **quiet**
`message "No action at point"` — not a `user-error` — so the user can probe
the sidebar with RET without triggering a bell.

### 3.2 Per-row action transients

Every actionable row gets its own transient. The shared verbs (open / browser /
copy URL) have fixed keys across all transients; row-specific verbs are grouped
separately. Every transient's header is the row's one-line label so the user
knows what they're acting on.

**Legend:** `•` always shown and enabled · `∘ <cond>` always shown,
**dimmed** unless `<cond>` is true · `—` absent from this row type's matrix
(hidden because categorically irrelevant, not state-dependent).

#### 3.2.1 Hub rows (Requests, WIP, Task, Linked PR, Linked Repo)

| Verb                              | Key   | Req | WIP | Task | LPR          | LRepo        |
|-----------------------------------|-------|-----|-----|------|--------------|--------------|
| Open here (xwidget/EWW)           | `o`   | •   | •   | •    | •            | •            |
| Open in browser                   | `b`   | •   | •   | •    | •            | •            |
| Copy URL                          | `c`   | •   | •   | •    | •            | •            |
| Start review session              | `r`   | •   | •   | —    | •            | —            |
| Start review (split)              | `s`   | •   | •   | —    | •            | —            |
| Start investigate session         | `i`   | —   | —   | •    | —            | •            |
| Merge                             | `m`   | —   | •   | —    | ∘ authored   | —            |
| Close                             | `x`   | —   | •   | —    | ∘ authored   | —            |
| Comment                           | `M`   | •   | •   | •    | •            | —            |
| Review-comment on PR              | `R`   | •   | •   | —    | •            | —            |
| Jump to CI run                    | `C`   | •   | •   | —    | •            | •            |
| Jump to deploy                    | `D`   | —   | ∘   | —    | ∘            | ∘            |
| Unlink from session               | `u`   | —   | —   | —    | •            | •            |
| Copy Jira key                     | `k`   | —   | —   | •    | —            | —            |
| Transition status                 | `t`   | —   | —   | •    | —            | —            |
| Align Jira status with code       | `A`   | —   | —   | •    | —            | —            |
| Analyze (AI)                      | `y`   | —   | —   | •    | —            | —            |
| Define/update spec                | `S`   | —   | —   | •    | —            | —            |
| Worktree… (nested transient)      | `w`   | •   | •   | —    | •            | •            |
| Reveal in Sessions picker         | `L`   | •   | •   | —    | •            | •            |

Notes:
- `∘ authored` = only enabled when the current user is the PR author. The
  suffix is rendered **dimmed** (not hidden) on subject-of-review linked PRs
  so the menu shape stays identical between authored and subject rows; the
  row's visual cues (§3.6.3) and the transient header tell the user which
  variant they are looking at.
- `C` (jump to CI run) and `D` (jump to deploy) live **inside** the row
  transient, not as top-level sidebar keys.  Capitalised to avoid colliding
  with the row's `c` Copy URL; the mnemonic stays "C for CI, D for
  deployment" once the transient is open.  `D` is conditional on the PR
  having deploy metadata in hub data — dimmed when absent per §3.1's
  stable-menu-shape rule.
- `L` (reveal) = open the Sessions picker pre-filtered to this PR's owning
  session, useful from a linked-PR row under Live/Previous.
- `R` vs `M` distinguishes "PR review comment" from "generic comment/issue
  comment" — needed because they're different gh subcommands.
- `w` opens the **worktree submenu** (§3.6) — unified across every row that
  carries a branch. Supersedes the earlier linked-repo-only `W` "show local
  worktree" verb; `W` is now free on hub rows.
- Tasks deliberately skip `w`: a Jira ticket has no branch of its own. If the
  ticket is linked to a PR the relevant row to act on is the linked PR, not
  the task.

#### 3.2.2 Session rows (Live, Previous, Saved)

| Verb                              | Key   | Live | Prev | Saved |
|-----------------------------------|-------|------|------|-------|
| Switch to buffer / resume / restore | (M-RET) | primary | primary | primary |
| Rename                            | `r`   | •    | •    | •     |
| Kill / close buffer               | `k`   | •    | —    | —     |
| Restart                           | `R`   | •    | —    | —     |
| Archive                           | `a`   | —    | •    | •     |
| Delete (with confirm)             | `D`   | —    | •    | •     |
| Merge into another session        | `m`   | —    | •    | •     |
| Tag / untag                       | `t`   | •    | •    | •     |
| Toggle hidden                     | `h`   | •    | •    | •     |
| Change workspace                  | `W`   | •    | •    | •     |
| Change mode                       | `M`   | •    | —    | —     |
| Copy conv-key                     | `c`   | •    | •    | •     |
| Reveal in Sessions picker         | `L`   | •    | •    | •     |
| Open session dir                  | `o`   | •    | •    | •     |
| Worktree… (nested transient)      | `w`   | ∘    | ∘    | ∘     |

Notes:
- "Rename" on a live row renames the live buffer; on saved/previous it updates
  the persisted session record.
- "Merge into another session" prompts for a target session via completing-read
  — cross-links the two conv-keys and collapses their linked-item sets.
- `W` changes the session's workspace tag (affects sub-header grouping under
  Sessions).
- `w` surfaces the **worktree submenu** (§3.6) scoped to the session's workspace.
  `∘` = only offered when the session's `workspace` directory is inside a git
  checkout (the common case). If the workspace is plain (no `.git`, not a
  worktree) the verb is hidden, not greyed. When the workspace *is* a git
  checkout the submenu exposes worktree ops for **that repo's branches**, not
  just the current one — so you can jump to the merged-branch worktree from a
  feature-branch session without leaving the sidebar.

#### 3.2.3 Section-header rows

These route to the equivalent footer quick-key, rather than defining a new
transient — the existing picker is already the action menu.

| Header           | RET action                         |
|------------------|------------------------------------|
| `Requests (N)`   | `decknix-sidebar-nav-requests-consult` (same as footer `r`) |
| `WIP (N)`        | `decknix-sidebar-nav-wip-consult`      (same as footer `w`) |
| `Tasks (N)`      | `decknix-sidebar-nav-tasks-consult`    (new; §5)            |
| `Live (N)`       | `C-c A b` — MRU buffer switcher                             |
| `Sessions (N)`   | `C-c A s` — session picker                                  |
| `Previous (N)`   | `C-c A s` — session picker (Previous group focused)         |

The `Previous (N)` header is rendered when sessions were live before the
daemon last restarted; the rows beneath it carry the same action menu as
saved-session rows (resume / rename / delete / archive / merge / tag) — see
§3.2.2.  Routing the header to `C-c A s` keeps a single canonical entry
point for resuming previous work.

#### 3.2.4 Workspace sub-header

RET opens a short transient:

| Verb                                 | Key   |
|--------------------------------------|-------|
| Open workspace directory             | `o`   |
| Open in Finder                       | `f`   |
| project.el: switch to project        | `p`   |
| project.el: find file in project     | `F`   |
| project.el: grep in project          | `g`   |
| Edit AI config (AGENTS.md / CLAUDE.md) | `A`   |
| Scope Sessions picker to workspace   | `L`   |
| Copy workspace path                  | `c`   |
| Worktree… (nested transient)         | `w`   |

`M-RET` = "Open workspace directory" (the primary action).

The sub-header label itself grows a `⎇` badge when the workspace is a git
worktree rather than the repo's primary checkout (detection in §3.6.2).  The
`w` submenu is always offered on this row — unlike session rows, the
sub-header is only rendered for git-backed workspaces to begin with.

### 3.3 RET vs M-RET (resolved)

Resolved in your review pass (see §2): **RET opens the action transient** for
every actionable row. **M-RET** (and `C-u RET`) runs the row's primary action
directly, matching today's RET behaviour. The Option A / Option B debate is
superseded; the transient is the discoverable surface, M-RET is the power-user
shortcut.

`.` is no longer needed as an action-menu key (RET is already the action-menu
key). `.` stays free for a future use.

### 3.4 Properties to add

Rows that currently have no properties need them. Minimum set per row type:

**Linked PR rows** (live + previous, expanded):
- `decknix-hub-type` = `linked-pr`
- `decknix-hub-url`, `decknix-hub-repo`, `decknix-hub-number`
- `decknix-hub-conv-key` (so `L` can reveal in Sessions picker)
- `decknix-hub-linked-kind` = `'authored | 'subject` (drives conditional verbs)
- `decknix-hub-pr-state` (OPEN / MERGED / CLOSED — hides merge/close when moot)
- `decknix-hub-ci-status` (feeds `C` jump-to-CI)
- `decknix-hub-deploy-url` when present (feeds `D`)
- `decknix-hub-head-repo` (owner/repo of the PR head — may differ from
  `decknix-hub-repo` for forks; feeds `w` worktree submenu)
- `decknix-hub-head-branch` (branch name on the head repo; feeds `w`)

**Linked repo rows** (live + previous, expanded):
- `decknix-hub-type` = `linked-repo`
- `decknix-hub-repo` (owner/repo)
- `decknix-hub-branch`
- `decknix-hub-sha` (for Copy URL → permalink; feeds `C` for CI on sha)
- `decknix-hub-conv-key`
- `decknix-hub-linked-kind` = `'authored | 'subject`
- `decknix-hub-head-repo` = `decknix-hub-repo` (mirrored so the worktree
  submenu has a uniform key to read on any row type).
- `decknix-hub-head-branch` = `decknix-hub-branch` (same rationale).

**Requests rows** already have `decknix-hub-url` + type — add:
- `decknix-hub-repo`, `decknix-hub-number` (needed for `M` / `R` / `C`).
- `decknix-hub-head-repo`, `decknix-hub-head-branch` (feeds `w` — for
  requests these usually point at a fork; the worktree submenu handles the
  fork-vs-upstream distinction at action time).

**Tasks (Jira) rows** already have key + status — add:
- `decknix-hub-jira-type` (Story / Bug / Task — feeds transition targets).

**Session rows** already have their parent property — the session dispatcher
reads the alist already attached to `decknix-previous-session` /
`decknix-sidebar-saved-session`. Live rows already have
`agent-shell-workspace-buffer`. No new properties required; the session
transient reads everything from the row's existing alist.

**Section headers** (new):
- `decknix-sidebar-section` = `'requests | 'wip | 'tasks | 'live | 'sessions`

**Workspace sub-header** (new):
- `decknix-sidebar-workspace` = workspace name (string)

### 3.5 Discoverability

Every actionable row must survive being discoverable through:

- `M-x describe-key` on RET at point → shows the dispatcher advice and the
  transient prefix it will invoke.
- `which-key` popup when the transient opens → lists every verb.
- Footer `K` (toggle keys) documents `RET` = action menu and `M-RET` = primary
  action; no per-row memorisation required.
- Each transient's header renders the row label so the user always knows what
  they are acting on, including whether a linked PR is authored vs subject.
- Menu shape is **stable across state** (§3.1): the same row type always
  shows the same verbs in the same positions; state-conditional verbs are
  dimmed rather than hidden. The row's badges (§3.6.3) advertise state on
  the row itself so the user can read it without opening the transient.

### 3.6 Worktree awareness

Many rows the sidebar surfaces are, one way or another, about a **branch in a
repo** — WIP PRs, Requests, Linked PRs, Linked Repos, and session workspaces
rooted at a clone.  Git worktrees let that branch live in its own checkout
alongside the primary one, so the user can review a PR or run an agent session
without disturbing whatever is in the main working copy.  The sidebar should
treat worktrees as first-class: show whether a branch already has a local
worktree, and let the user create / jump to / remove one from the same action
menu that opens the PR.

This section defines the data model and the `w` submenu those rows share.

#### 3.6.1 Clone registry and cache

The submenu needs to answer two questions:

1. **Is there a local clone of `owner/repo` on this machine?**  If not,
   "open worktree" is moot and the submenu collapses to "create worktree".
2. **For a given clone, is `branch` checked out in a worktree?  Where?**

Both answers come from a small cache Emacs maintains at
`~/.config/decknix/hub/worktrees.el`:

```elisp
;; keyed by (owner/repo) — canonicalised lowercase
((\"raywhite/decknix\"
  :primary \"/Users/ldeck/tools/decknix\"
  :worktrees ((\"main\"                . \"/Users/ldeck/tools/decknix\")
              (\"spec/sidebar-ret\"    . \"/Users/ldeck/tools/decknix-spec-sidebar-ret\")))
 ...)
```

The registry is seeded three ways, in priority order:

- **Explicit** `decknix-hub-clones` defcustom — an alist the user maintains in
  their personal `decknix-config`.
- **Sessions** — every persisted `agent-sessions.json` workspace is probed
  once and, if a git checkout, folded in.
- **project.el / projectile** known projects — same probe, same folding.

Entries are refreshed lazily: the first time a row with `decknix-hub-head-repo`
needs worktree data the registry is consulted, and each entry is revalidated
against `git worktree list --porcelain` with a 60 s TTL.  All IO is
`make-process`-based so a stale NFS mount can't wedge redisplay.

A `decknix.sidebar.eager-clone-probe` defcustom (default `nil`) opts into a
hybrid seeding strategy for users with many sessions: when `t`, the daemon
schedules an idle-time pass (after startup completes) that probes every
`agent-sessions.json` workspace and folds the result into the registry, so
the first sidebar render already has a warm cache.  Lazy per-row probing
remains the fallback when the eager pass hasn't run yet.

#### 3.6.2 Workspace-is-worktree detection

For a session row's workspace path `$P`:

- `git -C $P rev-parse --git-common-dir` vs `git -C $P rev-parse --git-dir` —
  different paths ⇒ `$P` is a worktree, not the primary checkout.
- `git -C $P rev-parse --show-toplevel` gives the worktree root (so the
  label's `⎇` badge can tag **this** session's workspace).
- Result is memoised on the session's workspace entry in the registry
  alongside the worktree list.

#### 3.6.3 Row badges and visual cues

Branch state is communicated **on the row** so the user does not have to open
the worktree submenu to know where a branch lives.  The badge occupies a
fixed two-column slot at the start of every hub row (Linked PR, Linked Repo,
Requests, WIP) so columns downstream line up regardless of state — the slot
exists even when no badge applies and is then filled with two spaces.

The slot consumes part of the existing leading indent (PR/Repo rows shrink
from 3/5-space indent to 1/3-space indent + the 2-char badge) so total row
width is unchanged on no-badge rows; rows that *do* badge protrude exactly
two columns to the left of where the same row would otherwise start.

| Badge | Meaning                                                                                       | Face                                                |
|-------|-----------------------------------------------------------------------------------------------|-----------------------------------------------------|
| `⎇*`  | Branch is checked out in a worktree **and** that worktree is a live session's workspace.      | green (`#98c379`) + bold                           |
| `⎇ ` | Branch is checked out in a **separate worktree** of the local clone (no live session yet).   | blue (`#61afef`)                                    |
| `↓ ` | No local clone of the repo on this machine yet (worktree submenu collapses to "create+clone"). | dim (`#5c6370`) + bold                              |
| `  ` (two spaces) | No badge — branch is the primary clone's HEAD, exists only as a ref, or row has no `(repo, branch)` context. | —                                                   |

Notes:

- The Workspace sub-header (§3.2.4) reuses the same `⎇` glyph so the convention
  is uniform across sections; that earlier reference resolves to this table.
- Detection is cheap enough to run on every render: the registry already knows
  `(repo, branch) → worktree-path` and live workspaces are read from each
  agent-shell buffer's `default-directory` (a hash-set built once per render),
  so the badge is a hash lookup, not a process invocation.  Stale clone-presence
  answers come from the §3.6.1 60 s TTL and never block.
- Badges never replace the existing draft `#` marker on Linked-PR rows or the
  state-word colour — they sit *before* the existing leading content so both
  signals coexist.
- Requests rows have no `(branch)` context (review items expose the repo only),
  so the badge resolves to either `↓ ` (no clone) or `  ` (clone present);
  it surfaces the "would need to clone first" signal without claiming branch
  state.
- The asterisk in `⎇*` deliberately costs the second column rather than
  rendering as a face mark, so muscle-memory parsing of the row's leading
  glyphs stays unambiguous on non-emoji terminals.

#### 3.6.4 The `w` submenu

Opened from any row that resolves a `(head-repo, head-branch)` pair, or from
a session workspace that lives in a git checkout.  Verbs:

| Verb                             | Key | Always shown? | Enabled when                                              |
|----------------------------------|-----|---------------|-----------------------------------------------------------|
| Open worktree                    | `o` | yes           | a worktree exists for `(repo, branch)`                    |
| Create worktree                  | `n` | yes           | clone exists locally **and** branch has no worktree yet   |
| Start session in worktree        | `s` | yes           | always (creates worktree first if missing)                |
| Remove worktree                  | `x` | yes           | a worktree exists; `C-u` to override "dirty" guard        |
| Reveal worktree in Finder        | `r` | yes           | a worktree exists                                          |
| Prune stale worktrees (for repo) | `p` | yes           | clone exists locally                                       |
| Status summary                   | `d` | yes           | clone exists locally (operates on worktree if present)     |
| Copy worktree path               | `c` | yes           | a worktree exists                                          |

Per the §3.1 stable-menu-shape rule, every verb above is **always rendered**;
verbs that are not currently enabled are **dimmed** via `transient`'s
`:inapt-if`, not hidden.  This keeps the submenu shape constant across rows
and states so muscle memory survives, and the dimmed verbs continue to teach
the user what is reachable once state changes (e.g. a dimmed `o` Open on a
no-worktree row signals "this is the verb to remember; use `n` first").

The header of the nested transient echoes `owner/repo @ branch — <state>` so
the user can see at a glance which combination of badges applies; the state
string mirrors the badge palette (§3.6.3): `in worktree`, `primary HEAD`,
`branch ref only`, or `no local clone`.

Verbs do **not dispatch** when dimmed — they show a one-line minibuffer
explanation pointing to the next reachable verb (e.g. `o`: "no worktree yet —
press `n` to create one").  This is `transient`'s standard inapt behaviour
and matches how Magit handles state-dependent verbs in its own menus.

**Fork-remote cleanup on `x`.** When the worktree being removed was created
via `gh pr checkout` against a fork, `x` deletes the per-fork remote *iff*
no other worktree on the same clone references it; otherwise the remote is
left in place.  This keeps clones tidy without surprising users mid-review
when a sibling worktree on the same fork still depends on the remote.  A
separate `decknix-clean-fork-remotes` hygiene command (§5) handles batch
cleanup for the leftover cases the automatic rule could not safely remove.

#### 3.6.5 What worktrees mean for each row type

- **Request rows** — head is usually a fork.  Creating a worktree uses
  `gh pr checkout` under the hood so the fork's remote is configured
  correctly; the worktree branch is named `pr/<number>` by default to avoid
  colliding with the user's own branches.
- **WIP / authored Linked-PR rows** — head is owned by the user.  Worktree
  branch name is the PR head branch verbatim; `x` warns if the branch is
  also the primary checkout's current HEAD.
- **Subject Linked-PR rows** (I was added as reviewer from a session) — same
  fork handling as Request rows, but "Start session in worktree" pre-populates
  the session tags `review #<number>` for symmetry with `C-c A c r`.
- **Linked-Repo rows** — simplest case: the branch exists on the upstream
  and `gh pr checkout` is not involved.  `n` does a plain `git worktree add`.
- **Session workspace rows (via sub-header and session `w`)** — scope is the
  repo that owns the workspace, but the submenu lists *all* that repo's
  worktrees, not only the current one, so you can jump from a feature-branch
  session to the `main` worktree without leaving the sidebar.
- **Tasks rows** — deliberately excluded (§3.2.1).  A Jira ticket has no
  branch of its own; the linked PR row is the right place to act.

#### 3.6.6 Worktree lifecycle hooks

Worktree creation/removal needs to stay consistent with the Sessions state so
stale workspace paths don't accumulate:

- When `s` "Start session in worktree" creates a new worktree it records the
  workspace in `agent-sessions.json` as usual — no new path.
- When `x` removes a worktree that is referenced by any saved session's
  workspace, removal is **aborted by default** with a one-line minibuffer
  explanation listing the affected sessions; the user resolves them
  manually (rename / archive / change-workspace) and reissues `x`.  A
  prefix arg (`C-u x`) opens the alternative path: a prompt offering
  **rewire** (point the session at the primary clone) or **archive** (mark
  the session archived) per affected entry.  Power users opt in; everyone
  else stays safe by default.
- The fork-remote rule from §3.6.4 fires here too: after a successful `x`
  the per-fork remote is dropped iff no other worktree references it.
- `git worktree prune` is plumbed through so Emacs notices externally
  removed worktrees on the next registry refresh; affected session rows
  render with the workspace path struck through and a `⚠ stale` hint until
  the user resolves them.

This dovetails with the planned #69 "worktree-aware sessions" work — that
issue can build on this registry rather than introduce its own.

#### 3.6.7 WIP placeholder rows for worktrees without a PR

The WIP section is fed by the hub daemon's `github-wip.json`, which only
contains PRs the user has already authored on GitHub.  When a fresh
worktree is created (`C-c A n` or the `w n` submenu), the user expects
to see it in WIP **immediately** — but `gh pr create` may not have run
yet, and even after it does, GitHub's Search index lags by 30 seconds
to a couple of minutes before the row appears.

To close that gap, the WIP section is augmented with **placeholder
rows** synthesised from the local worktree registry (§3.6.1).  For
every `(repo, branch)` in the registry that is *not* the primary
clone path *and* does not have a matching open PR in `decknix--hub-wip`,
the section emits one placeholder row under the same repo sub-header
as a real PR would use:

```
⎇  2h wip  feature/CONN-18
```

- The first 2 columns are the standard worktree badge (§3.6.3) so a
  branch in a live session badges `⎇*`.
- The age column shows the worktree directory's mtime as a relative
  age, mirroring the format of real WIP rows (`now`, `5m`, `2h`, `3d`).
- The state-word column reads `wip` in `font-lock-comment-face`,
  taking the slot a real row would use for `#NNN` + CI signals.  The
  signal zone is collapsed because none of those signals exist for a
  branch-without-a-PR.
- The branch name takes the title slot.  Long names elide with `…`.

Placeholder rows carry text properties `decknix-hub-type 'wip-placeholder`,
`decknix-hub-repo`, `decknix-hub-branch`, and `decknix-hub-worktree-path`,
but **no** `decknix-hub-url` (there is no PR yet).  The `RET` dispatch
routes them through `decknix-sidebar-wip-menu` so the worktree submenu
(`w`) is reachable; URL-dependent verbs (`o`, `b`, `c`, `r`, `s`, `M`,
`R`, `m`, `x`, `C`, `D`) gracefully no-op with a "No URL" minibuffer
message rather than crashing, preserving the §3.1 stable-shape contract.

When a placeholder's PR finally lands in `github-wip.json`, the
deduplication filter drops the placeholder on the next render and the
real PR row takes its place — the visual continuity is preserved
because both rows live under the same repo sub-header and use the
same column layout.  Repos with **only** placeholder rows (no real
PRs in WIP yet) appear at the bottom of the WIP section with their
own sub-header, so a brand-new worktree on a clone the user hasn't
otherwise touched today still surfaces.

The org-visibility filter (§3.5) applies uniformly to placeholder
rows, so users who scope WIP to a single org don't see worktrees from
others.  The `L hide-linked` toggle is a no-op on placeholder rows
because there is no PR to link.

## 4. Out of scope for this spec

- Changing the `r` / `w` pickers themselves (already stable).
- `agent-shell-workspace-sidebar-goto`'s non-RET callers (we only wrap via
  advice).
- Column semantics of linked PR/repo rows — orthogonal.
- macOS notification / hub-daemon work.
- New picker implementations (e.g. Tasks picker in §3.2.3) — spec'd here but
  shipped as their own issues.

## 5. Candidate issues (raise after review)

Ordered by dependency.  The first three propertise rows so subsequent issues
can land without needing to re-walk the renderer; the worktree work forms a
short, optional track that can slot in after the dispatcher (#4) lands.

1. **`feat(sidebar): propertize linked PR rows for RET dispatch`** (§3.4) —
   no behaviour change, prerequisite for #4.  Includes `decknix-hub-head-repo`
   and `decknix-hub-head-branch` so the worktree submenu can read them later.
2. **`feat(sidebar): propertize linked repo rows for RET dispatch`** (§3.4) —
   mirror of #1.  Sets `decknix-hub-head-repo` / `-head-branch` as aliases of
   the row's repo/branch.
3. **`feat(sidebar): propertize section + workspace headers`** (§3.4) —
   prerequisite for #6.
4. **`feat(sidebar): unified RET opens action transient for every actionable
   row`** — implements §3.1, §3.2.1, §3.2.2, §3.3. The main behaviour change.
   Needs #1 and #2 landed first.
5. **`feat(sidebar): M-RET / C-u RET runs row primary action`** (§3.3) —
   ships with #4 or immediately after.
6. **`feat(sidebar): RET on section headers routes to section picker`**
   (§3.2.3) — needs #3.
7. **`feat(sidebar): workspace sub-header action transient`** (§3.2.4) —
   needs #3. Introduces project.el and AI-config shortcuts.
8. **`feat(sidebar): session row action transient (rename/kill/archive/…)`**
   (§3.2.2) — can land independently of the hub-row work; session rows
   already carry enough data.
9. **`feat(hub): worktree registry + cache`** (§3.6.1) — clone discovery,
   `git worktree list --porcelain` probe via `make-process`,
   `~/.config/decknix/hub/worktrees.el`.  No UI surface yet; sets up the
   data layer for #10.  Independent of #4 — can land first or last.
10. **`feat(sidebar): worktree submenu on hub + session rows`** (§3.6.4,
    §3.6.5) — the shared `w` transient with the dim-not-hide policy from
    §3.1.  Needs #9 for the registry and #4 for the dispatcher plumbing.
    Builds on but does **not** block #69.
11. **`feat(sidebar): row badges for worktree / HEAD / no-clone state`**
    (§3.6.3) — cheap, depends only on the registry (#9); ships
    independently of the submenu so users get the visual cue first.
    Subsumes the earlier "workspace-is-worktree badge on sub-header"
    item by generalising it to every branch-bearing row, with the
    sub-header reusing the same `⎇` glyph.
12. **`feat(hub): tasks picker (mirrors `r`/`w` for Jira)`** — prerequisite
    for #6's Tasks-header routing; flagged in §4 as out of scope for *this*
    spec but tracked here so the dependency is visible.
13. **`feat(hub): Jira transition / align-with-code / analyze verbs`**
    (§3.2.1 task column) — separable; depends on MCP/Jira tooling already
    wired up for agent-shell.
14. **`feat(hub): clean-fork-remotes hygiene command`** (§3.6.4, §6 Q9)
    — `M-x decknix-clean-fork-remotes` walks every clone in the registry,
    lists fork-derived remotes (`pr/<owner>` style or detected via
    `gh pr checkout` markers) with no live worktree referencing them, and
    offers a multi-select for batch deletion.  Complements the automatic
    rule from #10's `x` verb: that rule runs eagerly per removal, this
    command sweeps the leftovers.
15. **`docs(agent-shell): document sidebar RET / M-RET + worktree contract
    in AGENTS.md`** — ships alongside #4 and #10.

## 6. Resolutions

The fourteen open questions raised across earlier drafts have been
resolved as follows.  Picks recorded against §6 itself rather than
inlined into the affected sections so the trail of decisions stays
auditable.  Numbering mirrors the original Q1–Q14 so prior commits
still reference the same items.

1. **Task-row `r` vs `i`** — Resolved: **A (keep split)**.  `r` is
   review-start on PR-ish rows; `i` is investigate-start on Task /
   Linked-Repo rows.  Both verbs live inside the RET transient, not as
   top-level sidebar keys, so users meet them through the action menu
   and don't have to pre-memorise the split.
2. *(retired in `d42821d`)* — the earlier "show local worktree" verb
   was absorbed into the §3.6 worktree submenu on every branch-bearing
   row, including linked repos.
3. **Jump-to-CI `C` and jump-to-deploy `D`** — Resolved: **in-transient,
   not top-level**.  Both verbs surface only after RET on the row.
   Capitalised because lowercase `c` is `Copy URL` on hub rows; the
   user's "C for CI / D for deployment" mnemonic is preserved by the
   menu layout.  Hub-data sufficiency for building URLs without a `gh`
   round-trip remains a sub-question for #10's implementation.
4. **Session merge semantics** — Resolved: **B (linked items + tags
   only; chat history stays per-session)**.  Avoids destroying
   chronology and keeps merge reversible.
5. **AI-config picker** — Resolved: **C (picker on ≥ 2 files,
   auto-open when only one exists, quietly create `AGENTS.md` when
   none exist)**.  First-run users get a useful default; veterans get
   a chooser.
6. **`M-RET` on linked PR row** — Resolved: **B (reuse existing review
   pane if one is open for this session, else open here in xwidget)**.
   Mid-review context is preserved without making the behaviour
   silently mode-dependent.
7. **`Previous (N)` header** — Resolved: **header exists today and is
   now in the matrix**.  Confirmed against `agent-shell.nix:8812`: the
   `Previous (%d)` block surfaces sessions that were live before the
   daemon last restarted (greyed) so they can be resumed quickly.
   §2 and §3.2.3 now route RET on the header to `C-c A s` (session
   picker, Previous group focused); rows beneath inherit the
   saved-session transient from §3.2.2 (resume / rename / delete /
   archive / merge / tag).
8. **Worktree default path** — Resolved: **C (sibling by default with
   a `decknix.worktree.root` defcustom for users who want a central
   `~/worktrees/<owner>/<repo>/<slug>` layout)**.  Best of both.
9. **Fork-remote cleanup on `x`** — Resolved: **B + C hybrid**.  When
   `x` removes a fork-checkout worktree, the per-fork remote is
   deleted *iff* no other worktree on the same clone references it;
   otherwise it stays.  In addition, a separate
   `decknix-clean-fork-remotes` hygiene command (§5 issue #14) sweeps
   leftover remotes for batch cleanup.  Spec details in §3.6.4 and
   §3.6.6.
10. **Worktree removal interlocked with sessions** — Resolved: **A
    (abort by default)**.  `C-u x` opts in to the prompt path
    (rewire / archive) for power users.  The user's saved state is
    worth more than removal convenience.
11. **Clone registry seeding** — Resolved: **B by default + opt-in
    C**.  Lazy per-row with a 60 s TTL is the default seed strategy;
    a `decknix.sidebar.eager-clone-probe` defcustom (default `nil`)
    flips the registry into "probe known sessions on daemon idle"
    mode for users with many sessions who want a warm cache up front.
    Spec detail folded into §3.6.1.
12. **NFS / cloud-mount staleness badge** — Resolved: **A (surface on
    demand via the `d` status summary)**.  No ambient "stale" glyph;
    `make-process` IO in §3.6.1 already keeps the UI responsive.
13. **Row badge palette** — Resolved: **B (lean) for now**, with the
    door open for **A (full)** or **D (verbose)** as enhancements.
    Initial implementation lights up `⎇` (worktree) and `⎇*` (worktree
    = current session's workspace); `●` (primary HEAD) and `↓` (no
    local clone) are not rendered, and the dirty (`⎇⚠`) / stale
    (`⎇⊘`) extensions from D are deferred until use confirms they're
    worth the extra column.  A `decknix.sidebar.show-no-clone-badge`
    defcustom (default `nil`) re-enables `↓` for users who want it
    now; the full palette graduates once feedback validates the
    column cost.  Spec detail in §3.6.3 unchanged — only the initial
    rendering set is reduced.
14. **Stable menu shape vs verb sprawl** — Resolved: **feature**.
    Dimming inapplicable verbs is the right trade: predictable
    layout, every key teaches, `transient`'s inapt rationale in the
    echo area explains why a key is greyed.  Revisit only if user
    feedback says the noise outweighs the consistency.
