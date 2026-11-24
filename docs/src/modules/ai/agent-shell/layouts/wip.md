# WIP

My own open PRs, grouped by repo. See the
[colour legend](./index.md#colour-legend-source-of-truth) and
[shape-family](./index.md#shape-family-glyphs).

## Session-first WIP: workspaces, teams, individuals

With the session-first layout (the default), WIP lists my live sessions with
their PRs and worktrees nested under each, grouped like this:

```
 WIP (6 · 1 need you · 1 ~guessed)
 ▾ my-org (5)                         ← only when there are 2+ workspaces
 ●  coordinator/team/us    3 lanes ready
   ~ ⚑  us/lane-01                ask 1h  ← lane, placed by tags (~)
          ↳ Ship it? (yes / no)  · reply yes/no
     ◐  us/lane-02                  work  ← lane, placed by a delivery
     ●  lane-03/us                 ready
 ▾ individual (1)
 ●  docs/refresh                   ready
 ▾ tools (1)
 ●  dotfiles                       ready
 ▾ unattended (4)                     ← work no live session is on
```

- **Workspace** is the session's workspace directory, named by the matching
  `decknix.workspaces` entry, or by its basename.
- **Under control**: a lane sits under the coordinator (a session tagged
  `coordinator`) that sent it the last message the dispatcher delivered. The
  record is kept in memory, so after an Emacs restart a session tagged
  `lane-NN` is placed by sharing most tags with one coordinator in its
  workspace, and marked `~` until a message confirms it. A tie places it
  nowhere. Lanes are indented four columns under their coordinator; the `~`
  sits inside that indent, beside the glyph, so an inferred lane is nested
  as deep as a confirmed one.
- **Heading**: sessions, how many need you, and how many rows below are
  guesses: `~guessed` counts exactly the rows marked `~` (a lane placed by
  tags, or a repo claimed from a session's name), `?pending` those marked `?`
  (evidence not gathered yet). Both are read off the rendered rows.
- **Unattended** work (dirty worktrees and PRs no live session is on) is the
  last group, under its own `unattended (N)` heading; `TAB` folds it.
- **Status** on the right is a compact word: `ask`, `wait`, `fail`, `upd`
  (blocked on you, with how long while it waits), `work`, `done` (finished,
  unread), `ready`, `close`. Its width is reserved, so a long name is
  truncated rather than the status clipped. Rows are fitted to the window's
  text width; the sidebar turns line numbers off (it is in
  `display-line-numbers-exempt-modes`), so no gutter takes their columns.
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
      ▸ run the integration tests             ← plain: in progress
      next: open the PR                       ← dim blue
    ■ ⇢prd #812 HX-1610 add the thing     ← ready: the badge says promote
    ■ →prd #813 HX-1611 another thing
        ▸ verifying us-prd                    ← the badge alone reads as deploying
    ■ shipped #790 HX-1599 ...
        next: close HX-1599                   ← its ticket is not Done yet
```

A session's lines come from its last ACP plan (the in-progress entry, then
the first pending one); a blocked session keeps its question line and adds
only the next step. A merged PR's come from its deploy stage and end with
`close KEY` once shipped, when a Jira key in its title or branch names a
ticket the hub still lists as not Done. A merged PR's current line is left
out when it only restates the badge on its row; only `verifying` keeps it.
The next line names what a person does: `deploy` a TeamCity environment,
`promote` a Kargo stage, and nothing for a Kargo stage that promotes by
itself. A stage ready for you to promote has no next line: its `⇢` badge
and `ready to promote prd` already say it. Red marks a failed stage, green
a completed one.
`decknix-sidebar-item-lines` turns them off.

### Merged PRs at one stage fold into one row

Merged PRs under one session and repo at an identical stage, with the same
marks (`✗ci` failing CI), fold into one summary row, collapsed by default;
`TAB` or `RET` lists them, and hovering names their numbers and every
region's stage. A fold shows only its state; what to do about it is in the
ship queue:

```
    ▸ 6 PRs · UK: ready to promote prd
    ■ shipped #790 HX-1599 ...                ← its own row: a ticket to close
        next: close HX-1599
```

A PR whose marks differ from its neighbours', or with a ticket to close,
keeps its own row. `↩` (a reply owed) is not shown on merged PRs or folds:
once merged, a PR's threads are history.

### Ship queue

What deploys want of you, gathered from every merged PR in WIP (under a
session or unattended), sits at the top of WIP, below the feed warnings,
and is hidden when empty:

```
 ▾ ship queue (4)
   UK dev ✗ 6 PRs · nct-etl-function                       ← red: failed
   UK prd ⇢ 9 PRs · address-normaliser, staff-user-service, +2   ← amber
   US stg ⇢ 1 PR · upside
   close HX-1273 · upside                                   ← amber
```

Failed stages come first, then stages waiting for you to promote them,
grouped by region and stage, nearest production first, then tickets to
close. A PR shipping several ways joins one group per shipper. Each row
names as many repos as fit, then `+N`. `RET` or `TAB` on a group lists its
PRs; `RET` on a ticket offers the Jira actions. Stages that are unknown,
in flight or done ask nothing and are left out.

## Merged PRs: kept until shipped

A merged PR stays under the session that raised it until its last deploy
stage is verified, then shows dimmed as `shipped` for the shipped-retention
window, then drops. In place of its age the row shows the stage:

```
    ■ →stg  #812 HX-1610 add the thing     deploying or verifying stg (plain)
    ■ ⇢prd  #812 ...                       ready for you to promote (amber)
    ■ ·prd  #812 ...                       waiting for prd, which follows by itself (plain)
    ■ ✗test #812 ...                       failed at test (red)
    ■ merged #90 docs tweak                nothing to deploy (green)
    ■ ✗stg? #812 ...                       failed at stg when Kargo was last read (grey ?)
    ■ US?   #812 ...                       stage unknown: Kargo never read (grey)
    ■ shipped #77 ...                      shipped, dimmed until retention ends
```

How a repo ships decides what "last stage" means:

- **gitops**: ordered deploy stages from the hub's `kargo-stages.json`. A
  stage is `ready` when its promotion policy is manual and `pending` when it
  promotes by itself; `deploying` only while a promotion runs and
  `verifying` while the freight holding the merge is being verified. An
  entry listing several regions' stages under no `region`
  (`uk-dev us-dev uk-stg ...`) is read as one shipper per region;
- **teamcity**: environments from `teamcity-deploys.json`, done once every
  production environment the repo deploys to holds the merge;
- **ci**: a dependency bump in a repo with no deploy data, done when its
  build is green;
- **none**: anything else, done at merge.

`decknix-ship-repo-kinds` forces a kind per repo.

### Several shippers per repo

A repo can ship more than one way at once, for example TeamCity
environments in one region and Kargo stages in two others. Each way is a
*shipper* with its own ordered stages and a region label, set with
`decknix-ship-repo-shippers` (which wins over `decknix-ship-repo-kinds`):

```elisp
(setq decknix-ship-repo-shippers
      '(("\\`my-org/widget-api\\'"
         (:kind teamcity :region "AU" :stages ("development" "testing" "production"))
         (:kind teamcity :region "UK" :stages ("uk_production"))
         (:kind gitops :region "US"))))
```

A `teamcity` shipper follows only its `:stages` and is done once the last
holds the merge. A `gitops` shipper reads the `kargo-stages.json` entry of
the same `region` (list the repo once per region under
`decknix.services.hub.kargo.repos`, each with its `region`); until that
entry exists it shows its own `:stages`, if given, as pending. A Kargo repo
listed per region with no Emacs setting becomes one shipper per region
automatically.

The PR is shipped only when every shipper's last stage is verified. The row
shows the furthest-behind shipper (failed, then least of its stages done),
region first and with the region dropped from stage names it repeats, and
how many other shippers are done; hovering shows every shipper's token:

```
    ■ US→stg +2✓ #812 HX-1610 …   US deploying stg, two others shipped
    ■ US✗prd #812 …               failed in US prd (red), so the PR is failed
```

The badge, current line and next line all come from that one shipper
(`UK⇢stg +1✓`, `UK: ready to promote stg`, `UK: promote stg`), and once all
are done the current line is `shipped to AU, UK, US`. A ship progress
record updates the shipper whose stages name its `stage`.

A ship progress record,
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
is listed under `unattended` while it ships and counted as quiet once
shipped.

If a hub WIP query fails (merged or assigned PRs), a `⚠ WIP feed partial`
line under the heading names the first failure; hover for all of them. A
deploy feed the hub cannot read gets one line of its own with the age of the
data shown, `⚠ Kargo stale 2h · 6 repos · login expired, run kargo login
--sso` (or `TeamCity`). A stage it last read keeps that state with a grey
`?` after its badge, `✗stg?` or `⇢prd?`, and hovering says how old it is,
`(Kargo data stale 2h)`: a stage that had failed or was waiting for you
still wants you, so it stays in the ship queue, whose group gains the same
`?`. A stage that had shipped stays shipped. Only a stage the hub has never
read reads `?`, `stage unknown (Kargo unavailable)`, in grey: unknown,
never `not deployed`. A merge the
hub found changes no runtime file of its repo (see the hub guide's Kargo
section) is done at once: `no deploy needed`, listed as `no deploy` for
the shipped retention.

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
