# WIP

My own open PRs, grouped by repo. See the
[colour legend](./index.md#colour-legend-source-of-truth) and
[shape-family](./index.md#shape-family-glyphs).

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
