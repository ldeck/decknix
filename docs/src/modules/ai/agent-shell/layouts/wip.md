# WIP

My own open PRs, grouped by repo. See the
[colour legend](./index.md#colour-legend-source-of-truth) and
[shape-family](./index.md#shape-family-glyphs).

## Session-first WIP: workspaces, teams, individuals

With the session-first layout (the default), WIP lists my live sessions with
their PRs and worktrees nested under each, grouped like this:

```
 WIP (6 — 1 need you)
 ▾ my-org (5)                         ← only when there are 2+ workspaces
 ●  coordinator/team/us   3 lanes ready
 ~ ⚑  us/lane-01                 asking   ← lane, placed by tags (~)
        ↳ Ship it? (yes / no)  · reply yes/no
   ◐  us/lane-02                working   ← lane, placed by a delivery
   ●  lane-03/us                  ready
 ▾ individual (1)
 ●  docs/refresh                  ready
 ▾ tools (1)
 ●  dotfiles                      ready
 ◌  no session              4 unattended
```

- **Workspace** is the session's workspace directory, named by the matching
  `decknix.workspaces` entry, or by its basename.
- **Under control**: a lane sits under the coordinator (a session tagged
  `coordinator`) that sent it the last message the dispatcher delivered. The
  record is kept in memory, so after an Emacs restart a session tagged
  `lane-NN` is placed by sharing most tags with one coordinator in its
  workspace, and marked `~` until a message confirms it. A tie places it
  nowhere.
- **Review sessions** are listed in Reviews, not here. The `0` toggle
  (`T` → Shared → wip reviews) adds them as a last `reviews` group per
  workspace.
- `TAB` collapses a coordinator's lanes or a group; a collapsed group still
  shows its sessions that are blocked on you.

## Now and next under each item

Beneath a session and a merged PR, at most two lines say what it is doing and
what comes next:

```
 ◐  hx-1610/fix-the-thing                working
      ▸ run the integration tests             ← amber: in progress
      next: open the PR                       ← dim blue
    ■ →stg #812 HX-1610 add the thing
        ▸ deploying us-stg
        next: promote us-prd
    ■ shipped #790 HX-1599 ...
        next: close HX-1599                   ← its ticket is not Done yet
```

A session's lines come from its last ACP plan (the in-progress entry, then
the first pending one); a blocked session keeps its question line and adds
only the next step. A merged PR's come from its deploy stage and end with
`close KEY` once shipped, when a Jira key in its title or branch names a
ticket the hub still lists as not Done. Red marks a failed stage, green a
completed one. `decknix-sidebar-item-lines` turns them off.

## Merged PRs: kept until shipped

A merged PR stays under the session that raised it until its last deploy
stage is verified, then shows dimmed as `shipped` for the shipped-retention
window, then drops. In place of its age the row shows the stage:

```
    ■ →stg  #812 HX-1610 add the thing     promoting to stg (amber)
    ■ ·prd  #812 ...                       waiting to be promoted (amber)
    ■ ✗test #812 ...                       failed at test (red)
    ■ merged #90 docs tweak                nothing to deploy (green)
    ■ shipped #77 ...                      shipped, dimmed until retention ends
```

How a repo ships decides what "last stage" means:

- **gitops**: ordered deploy stages from the hub's `kargo-stages.json`;
- **teamcity**: environments from `teamcity-deploys.json`, done once every
  production environment the repo deploys to holds the merge;
- **ci**: a dependency bump in a repo with no deploy data, done when its
  build is green;
- **none**: anything else, done at merge.

`decknix-ship-repo-kinds` forces a kind per repo. A ship progress record,
when present, wins over the deploy feeds: a ship workflow writes
`~/.local/state/decknix/ship/<owner>-<repo>-<number>.json` as

```json
{"repo": "owner/repo", "number": 12, "stage": "us-stg",
 "status": "verified", "verified_at": "2026-11-19T01:02:03Z"}
```

with `status` one of `promoting`, `verified`, `failed` or `done`. The
directory is watched, so a new record repaints the row at once. The retention is the `Y` toggle
(`T` → Shared → shipped): 0, 10m, 20m, 30m, 1h, 2h, 1d or a typed duration,
persisted with the other toggles (default 1d). A merged PR no session claims
is listed under `no session` while it ships and counted as quiet once
shipped.

If a hub WIP query fails (merged or assigned PRs), a `⚠ WIP feed partial`
line under the heading names the first failure; hover for all of them.

The rest of this page describes the PR-centric WIP of the previous layout.

Two things are **orthogonal** here:

- **Grouping** (how rows nest) — shipped today, three modes.
- **Row layout** (what each row shows) — today a single compact format;
  [proposed below](#proposed-columnar-layout-draft) is a layout cycle borrowed
  from Requests.

## Grouping modes (today)

Row format today: `wt-badge · icon · age · kind · #N · branch`.

<!-- Source: wip-today.rtf — edit in TextEdit for WYSIWYG colour authoring,
     then run: python3 docs/scripts/rtf2html.py docs/src/modules/ai/agent-shell/layouts/wip-today.rtf -->
{{#include wip-today.gen.html}}

The **last row** in "Repo-only" is a **worktree placeholder** — a `(repo, branch)` in the
worktree registry with no matching open PR yet (`⎇ … wip`), so freshly-created worktrees
appear before `gh pr create` indexes (`hub.el:2722`).

## Which session a PR belongs to

A PR nests under the session that **created** it for as long as it is open,
however long ago that was. Creations are read from the session's broker log
(`~/.local/state/decknix/agent-sockets/<key>.log`), so a PR raised while the
buffer was detached, or by one of the session's sub-agents, still counts:

- a Bash call running `gh pr create` credits every PR URL in its output (a
  loop raising three PRs credits all three);
- Claude Code's own `code_change_published` event with action `created` is a
  second source;
- an Agent call that merely mentions `gh pr create` in its prompt credits
  nothing.

The log is read incrementally: a byte offset per session is kept in
`~/.local/state/decknix/session-prs-offsets.eld` and advanced at each turn end
and every `decknix-session-assoc-created-interval` seconds (60), one bounded
chunk at a time in a child Emacs. Results go to `session-prs.eld`, and each
newly found PR is also linked to the conversation in `agent-sessions.json`
(`"added": "auto"`), which survives the session being re-brokered. An existing
link, manual or not, is never replaced. `decknix session link-pr` writes the
same link from outside Emacs. Deleting the offsets file makes every live
session's log be read again from the start.

## Proposed columnar layout (draft)

> **Status: proposal for review.** Not implemented. Borrows the Requests layout
> cycle (`D`) and the linked-PR signal zone so WIP carries the same scannable
> pipeline columns as [Live's linked-PR rows](./live.md#linked-pr-rows).

Grouping stays as above; what changes is the **row**. A new `D` cycle:

### Proposed A — Full (columnar)

`wt · #N · age₃ · state₆ · CI · b · c · ✓ · [⚠] · DTSP · branch`
(the [linked-PR signal zone](./live.md#linked-pr-rows), reused verbatim).

<!-- Source: wip-proposed.rtf — edit in TextEdit for WYSIWYG colour authoring,
     then run: python3 docs/scripts/rtf2html.py docs/src/modules/ai/agent-shell/layouts/wip-proposed.rtf -->
{{#include wip-proposed.gen.html}}

### Proposed B/C/D

Mirror Requests so muscle memory transfers:

- **B — Scoped:** `wt · icon · state · branch` (phase-aware, drops the signal zone).
- **C — Label:** `wt · icon · state-label₁₆ · branch` (e.g. `CI failing`).
- **D — Minimal:** today's compact row (`icon · age · kind · #N · branch`) —
  keeps the current default as the floor of the cycle.

### Open questions for review

- Does the signal zone belong on **my own** PRs, or is `b`/`c`/`✓` noise when
  I'm the author? (Requests uses it for PRs I *review*.)
- Placeholder rows have no PR — should they dim the whole signal zone (shown)
  or omit it and left-align the branch?
- Should `D` (layout) and the grouping toggle share one key or stay separate?

## Toggles (the `T` → WIP group, today)

| Key | Toggle | Effect |
|-----|--------|--------|
| `L` | hide linked | hide PRs already live as sessions |
| `m` | stale | hide MERGED/CLOSED (default on); off shows `⊘` stale rows |
| `P` | pipeline | deploy (DTSP) indicators |
| `r` | ↩ replies-to-me | parallel to Requests, own state |
| `n` | 💬 comments | |
| `u` | 🤖 bot-review | |

## Source

- WIP renderer: `agent-shell/hub-bulk/decknix-agent-shell-hub.el`
- Placeholder rows: `decknix--hub-wip-placeholder-rows`, `hub.el:2722`
- Signal-zone formatter (to be reused): `decknix--hub-pr-format-line`, `hub.el:2003`
