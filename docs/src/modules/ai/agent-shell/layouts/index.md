# Sidebar Layouts

The Agents workspace sidebar (`C-c A w`) stacks four major sections —
**Requests → WIP → Live → Sessions** — above a Keys/Toggles footer. Each
section has its own row format, glyph set, and (for Requests) a multi-layout
cycle.

These pages mock up the toggle states **in colour**, because colour is
load-bearing in this UI: it encodes CI state, review state, age, and attention.
A plain-text mock-up (the retired `sidebar-demo.txt`) could not carry that, so
the layouts now live here.

One page per section:

- [Global](./global.md) — org filter, width, footer toggle states
- [Requests](./requests.md) — the A/B/C/D layout cycle + column anatomy
- [WIP](./wip.md) — grouping modes today **plus a proposed columnar layout**
- [Live](./live.md) — view modes + linked-PR / linked-repo rows

## How to read these mock-ups

Mock-ups use a custom "sidebar DSL" inside `<pre class="sb-markup">` blocks.
This allows simple tags like `{g}●{/}` to render with the real foreground
colours from the Emacs faces.

The colours are faithful to `agent-shell/hub/decknix-hub-icons.el` and
`agent-shell/hub-bulk/decknix-agent-shell-hub.el` (cited per page). They are
**not** screenshots — spacing is approximate; column *order* and *colour* are
the contract.

## Session-first sidebar: one meaning per colour

Reviews groups, WIP repo headers, PR rows, folds, deploy badges, the ship
queue and Tasks rows share one scale:

| Colour | Means | Examples |
|--------|-------|----------|
| red | failed or blocked | `✗dev`, a conflict `!`, changes requested |
| amber | waiting on you | `⇢prd`, PRs awaiting your review, `close HX-1` |
| green | shipped, done, approved | `✓prd`, `✓none`, `✓` approved |
| grey | quiet or unknown | `?` stage unknown, guessed `~` rows, shipped PRs |
| plain | moving on its own | `→stg`, a working session `◐` |
| purple | a session blocked on you | `⚑` rows; shared with tabs and Requests |

Amber is never "in progress": work moving on its own is plain, so an
amber row always wants something from you. `L` in the sidebar (or `L`
in the `?` menu) shows every glyph and colour with its meaning
(`decknix-sidebar-legend`).

## Colour legend (source of truth)

<table class="sb-legend">
<tr><th>Swatch</th><th>Hex</th><th>Semantic</th><th>Where it appears</th></tr>
<tr><td><span class="g bd">██</span></td><td>#98c379</td><td>success / green</td><td>approved <span class="g">●</span>, merged <span class="g">■</span>, CI pass <span class="g">⟳</span>, approval <span class="g">✓</span>, live worktree <span class="g bd">⎇*</span>, resolved comments</td></tr>
<tr><td><span class="r bd">██</span></td><td>#e06c75</td><td>error / red</td><td>changes-requested <span class="r">◐</span>/<span class="r">✗</span>, CI fail, conflict <span class="r">▣</span>/<span class="r">⚠</span>, age ≥3d</td></tr>
<tr><td><span class="y bd">██</span></td><td>#e5c07b</td><td>warning / yellow</td><td>draft <span class="y">★</span>, CI running, review-required, bot-pending <span class="y bd">b</span>, needs-reply, age &lt;3d, <span class="y">?</span></td></tr>
<tr><td><span class="c bd">██</span></td><td>#61afef</td><td>info / blue</td><td>open state word, team <span class="c bd">@</span>, idle worktree <span class="c">⎇</span>, branch names</td></tr>
<tr><td><span class="sg bd">██</span></td><td>#87d7af</td><td>soft green</td><td>human reply <span class="sg bd">↩</span>, bot reply <span class="sg bd">👽</span>, reply-state comments column</td></tr>
<tr><td><span class="ac bd">██</span></td><td>#87d7ff</td><td>bright cyan</td><td>active-review indicator <span class="ac">◉</span></td></tr>
<tr><td><span class="gd bd">██</span></td><td>#d7af5f</td><td>gold</td><td>me <span class="gd bd">@</span>, active-review row tint, needs-reply <span class="gd">💬</span></td></tr>
<tr><td><span class="bo bd">██</span></td><td>#af5f87</td><td>pink / mauve</td><td>bot author <span class="bo">π</span>, bot-pending <span class="bo">🤖</span></td></tr>
<tr><td><span class="dm bd">██</span></td><td>#5c6370</td><td>dim grey</td><td>no local clone <span class="dm bd">↓</span>, stale <span class="dm">⊘</span></td></tr>
<tr><td><span class="dm">██</span></td><td><em>comment face</em></td><td>dim default</td><td>closed <span class="dm">■</span>, sha7, sub-day ages, <code>(none)</code> placeholders</td></tr>
</table>

## Shape-family glyphs

The **primary status icon** folds PR state + CI + review into one glyph
(`decknix--hub-primary-status-icon`, `decknix-hub-icons.el:83`):

<table class="sb-legend">
<tr><th>Glyph</th><th>Meaning</th><th>Colour rule</th></tr>
<tr><td><span class="dm">○</span></td><td>placeholder / pre-PR / local branch</td><td>shadow</td></tr>
<tr><td><span class="y">★</span></td><td>draft</td><td>CI: <span class="g">pass</span> / <span class="y">running</span> / <span class="r">fail</span> / orange soft-fail</td></tr>
<tr><td><span class="r">◐</span></td><td>open / in-review</td><td><span class="r">blocked</span> / <span class="y">running</span> / cyan commented / else shadow</td></tr>
<tr><td><span class="g">●</span></td><td>open &amp; approved</td><td>success</td></tr>
<tr><td><span class="r">▣</span></td><td>merge conflict</td><td>error</td></tr>
<tr><td><span class="g">■</span> / <span class="dm">■</span></td><td>merged / closed</td><td><span class="g">merged green</span>, closed dim</td></tr>
<tr><td><span class="bo">π</span></td><td>bot author (overrides all above)</td><td>pink</td></tr>
</table>

## Worktree row badge

A fixed 2-column slot at the start of hub rows
(`decknix--hub-worktree-row-badge`, `hub.el:1672`):

<table class="sb-legend">
<tr><th>Badge</th><th>Meaning</th></tr>
<tr><td><span class="g bd">⎇*</span></td><td>branch is checked out in a worktree that is a <em>live</em> session</td></tr>
<tr><td><span class="c">⎇&nbsp;</span></td><td>separate worktree of the local clone, no live session yet</td></tr>
<tr><td><span class="dm bd">↓&nbsp;</span></td><td>no local clone of the repo on this machine</td></tr>
<tr><td><code>··</code></td><td>(two spaces) primary HEAD / branch ref only / no <code>(repo, branch)</code> context</td></tr>
</table>

## Symbol style (`y` toggle)

`y` swaps the **row-level activity icons** (<span class="bo">🤖</span> <span class="bo">👽</span>
<span class="gd">💬</span> <span class="sg">↩</span>) between emoji and an
ASCII fallback (`β`/`β`/`i`/`i`). The Live section count badges (📥 📤) are
always emoji and are not affected by the toggle. The shape-family glyphs and
the columnar `⟳ ✓ ✗` always stay ASCII — Emacs faces cannot tint colour-emoji,
so the colour contract above depends on them being plain glyphs.

## Sections from other packages

An org layer or personal config can put its own section above everything
else, including the board-focus banner, by adding a function to
`decknix-sidebar-top-section-functions`. Each function is called with the
current line number and the usable sidebar width, inserts its lines at point,
and returns the new line number:

```elisp
(defun my-top-section (line-num width)
  (if (null my-pending-items)
      line-num
    (insert (propertize (format " Waiting on you (%d)" (length my-pending-items))
                        'face 'bold)
            "\n\n")
    (+ 2 line-num)))
(add-hook 'decknix-sidebar-top-section-functions #'my-top-section)
```

The hook runs on every paint, so render from data already in memory and fetch
it elsewhere, asynchronously. A function that signals, or returns something
other than a line number, is skipped for that paint: its partial output is
removed and the error is logged once, so a broken section never breaks the
sidebar.
