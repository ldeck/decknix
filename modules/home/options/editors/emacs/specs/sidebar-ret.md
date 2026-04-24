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

RET on an unpropertized line (placeholder, footer help) gives a **quiet**
`message "No action at point"` — not a `user-error` — so the user can probe
the sidebar with RET without triggering a bell.

### 3.2 Per-row action transients

Every actionable row gets its own transient. The shared verbs (open / browser /
copy URL) have fixed keys across all transients; row-specific verbs are grouped
separately. Every transient's header is the row's one-line label so the user
knows what they're acting on.

**Legend:** `•` always shown · `∘` shown conditionally (noted) · `—` absent.

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
| Show local worktree               | `W`   | —   | —   | —    | —            | •            |
| Reveal in Sessions picker         | `L`   | •   | •   | —    | •            | •            |

Notes:
- `∘ authored` = only when the current user is the PR author. The transient
  hides the suffix when the data says otherwise, so the menu is context-aware
  for authored vs subject-of-review linked PRs.
- `D` (jump to deploy) is conditional on the PR having deploy metadata in
  hub data. Still flagged as an open question (§6.5).
- `L` (reveal) = open the Sessions picker pre-filtered to this PR's owning
  session, useful from a linked-PR row under Live/Previous.
- `R` vs `M` distinguishes "PR review comment" from "generic comment/issue
  comment" — needed because they're different gh subcommands.

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

Notes:
- "Rename" on a live row renames the live buffer; on saved/previous it updates
  the persisted session record.
- "Merge into another session" prompts for a target session via completing-read
  — cross-links the two conv-keys and collapses their linked-item sets.
- `W` changes the session's workspace tag (affects sub-header grouping under
  Sessions).

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

`M-RET` = "Open workspace directory" (the primary action).

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

**Linked repo rows** (live + previous, expanded):
- `decknix-hub-type` = `linked-repo`
- `decknix-hub-repo` (owner/repo)
- `decknix-hub-branch`
- `decknix-hub-sha` (for Copy URL → permalink; feeds `C` for CI on sha)
- `decknix-hub-conv-key`
- `decknix-hub-linked-kind` = `'authored | 'subject`

**Requests rows** already have `decknix-hub-url` + type — add:
- `decknix-hub-repo`, `decknix-hub-number` (needed for `M` / `R` / `C`).

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

## 4. Out of scope for this spec

- Changing the `r` / `w` pickers themselves (already stable).
- `agent-shell-workspace-sidebar-goto`'s non-RET callers (we only wrap via
  advice).
- Column semantics of linked PR/repo rows — orthogonal.
- macOS notification / hub-daemon work.
- New picker implementations (e.g. Tasks picker in §3.2.3) — spec'd here but
  shipped as their own issues.

## 5. Candidate issues (raise after review)

Ordered by dependency. The first three propertise rows so subsequent issues
can land without needing to re-walk the renderer.

1. **`feat(sidebar): propertize linked PR rows for RET dispatch`** (§3.4) —
   no behaviour change, prerequisite for #3/#4.
2. **`feat(sidebar): propertize linked repo rows for RET dispatch`** (§3.4) —
   mirror of #1.
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
9. **`feat(hub): tasks picker (mirrors `r`/`w` for Jira)`** — prerequisite
   for #6's Tasks-header routing; flagged in §4 as out of scope for *this*
   spec but tracked here so the dependency is visible.
10. **`feat(hub): Jira transition / align-with-code / analyze verbs`**
    (§3.2.1 task column) — separable; depends on MCP/Jira tooling already
    wired up for agent-shell.
11. **`docs(agent-shell): document sidebar RET / M-RET contract in AGENTS.md`**
    — ships alongside #4.

## 6. Open questions

1. Task-row `r` vs `i` for "start session" — §3.2.1 currently reserves `r`
   for review-start on PR-ish rows and `i` for investigate-start on
   Task/Linked-Repo. Keeping them separate avoids overloading `r`, but the
   user may prefer a single mnemonic. **Lean: keep split.**
2. Linked-repo `W` "show local worktree" — useful or bloat? Depends on the
   git-worktree integration in #69 landing. **Lean: defer, reintroduce when
   #69 ships.**
3. Jump-to-CI `C` and jump-to-deploy `D` — do we have enough info in hub
   data today to build URLs without a round-trip to `gh`? If not, these
   verbs block on a hub-data extension.
4. Session transient `m` (merge into another session) — semantics of
   "merge": does it combine linked items only, or also fold chat history?
   Proposal: linked items + tags only; chat history stays per-session.
5. Workspace sub-header `A` (edit AI config) — single file or picker between
   `AGENTS.md` / `CLAUDE.md` / `.cursorrules` / `.augment-guidelines`?
   **Lean: picker, falling back to `AGENTS.md` if only one exists.**
6. Should `M-RET` on a linked PR row open **here** (xwidget) or in the
   session's existing review pane if one is open? The latter is more useful
   when you're already mid-review; the former is simpler. **Lean: prefer
   existing review pane when present, else open here.**
7. RET on the `Previous (N)` header — the matrix in §2 doesn't list a
   `Previous` header because sessions are grouped by workspace under
   `Sessions (N)`. Confirm this is still correct (no separate previous
   header needed).
