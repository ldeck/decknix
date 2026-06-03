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

## Colour legend (source of truth)

<table class="sb-legend">
<tr><th>Swatch</th><th>Hex</th><th>Semantic</th><th>Where it appears</th></tr>
<tr><td><span class="g bd">██</span></td><td>#98c379</td><td>success / green</td><td>approved <span class="g">●</span>, merged <span class="g">■</span>, CI pass <span class="g">⟳</span>, approval <span class="g">✓</span>, live worktree <span class="g bd">⎇*</span>, resolved comments</td></tr>
<tr><td><span class="r bd">██</span></td><td>#e06c75</td><td>error / red</td><td>changes-requested <span class="r">◐</span>/<span class="r">✗</span>, CI fail, conflict <span class="r">▣</span>/<span class="r">⚠</span>, age ≥3d</td></tr>
<tr><td><span class="y bd">██</span></td><td>#e5c07b</td><td>warning / yellow</td><td>draft <span class="y">★</span>, CI running, review-required, bot-pending <span class="y bd">b</span>, needs-reply, age &lt;3d, <span class="y">?</span></td></tr>
<tr><td><span class="c bd">██</span></td><td>#61afef</td><td>info / blue</td><td>open state word, team <span class="c bd">@</span>, idle worktree <span class="c">⎇</span>, branch names</td></tr>
<tr><td><span class="sg bd">██</span></td><td>#87d7af</td><td>soft green</td><td>replies-to-me <span class="sg bd">↩</span>, reply-state comments column</td></tr>
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

`y` swaps the **emoji activity icons** (<span class="bo">🤖</span>
<span class="gd">💬</span> <span class="sg">↩</span> 📥 📤) between emoji and an
ASCII fallback. The shape-family glyphs and the columnar `⟳ ✓ ✗` always stay
ASCII — Emacs faces cannot tint colour-emoji, so the colour contract above
depends on them being plain glyphs.
