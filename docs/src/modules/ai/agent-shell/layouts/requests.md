# Requests

PR reviews assigned to me, oldest-first by default. This is the only section
with a **layout cycle** — `D` in the `T` transient steps A → B → C → D. All four
render the same four example PRs below so you can compare:

1. `upside#16570` — 2d, open, CI pass, **approved**, **I'm @-mentioned**, and a
   live review session is already running (gold tint + `◉`).
2. `upside#16568` — 15d, **draft**, **bot-authored**, no local clone.
3. `reapit#123` — 4h, open, **CI failing / changes-requested**, **team** requested.
4. `upside#16571` — 1d, open, CI running, **needs my reply**.

See the [colour legend](./index.md#colour-legend-source-of-truth) and
[shape-family](./index.md#shape-family-glyphs) for glyph/colour meanings.

## Layout A — Full (default)

`wt-badge · age₃ · repo#N · [icon @ activity ◉] · title`. The primary icon folds
CI+review into one shape (`hub.el:2699`).

<pre class="sb-markup">
{hd}Requests (4){/} ⇅
{c}⎇ {/} {y}2d{/} upside{gd}#16570{/} {g}●{/}{gd bd}@{/}{ac}◉{/} {gd}CSE-201: refactor token cache{/}
{dm bd}↓ {/}{r}15d{/} upside#16568 {bo}π{/}   {dm}bump: dependency update{/}
{dm bd}↓ {/} {dm}4h{/} reapit#123 {r}◐{/}{c bd}@{/} CSE-204: fix pubsub timeout
    {y}1d{/} upside#16571 {y}◐{/}{gd}💬{/} CSE-205: retry policy for webhook
</pre>

The row for PR 1 is **gold-tinted** end to end because a live session is
reviewing it; per-column colours (icon green, `@` gold, age yellow) still show
through (`add-face-text-property … append`, `hub.el:2711`).

## Layout B — Scoped

`icon · @activity · title` (`hub.el:2694`). Drops age / repo / number — the
phase-aware minimal signal. `◉` is gone but the active row keeps its gold tint.

<pre class="sb-markup">
{hd}Requests (4){/}
{g}●{/} {gd bd}@{/} {gd}CSE-201: refactor token cache{/}
{bo}π{/}   {dm}bump: dependency update{/}
{r}◐{/} {c bd}@{/} CSE-204: fix pubsub timeout
{y}◐{/} {gd}💬{/} CSE-205: retry policy for webhook
</pre>

## Layout C — Label

`icon · state-label₁₆ · title` (`hub.el:2684`). The label is the human-readable
state (dim, fixed 16-col) from `decknix--hub-format-row-label`.

<pre class="sb-markup">
{hd}Requests (4){/}
{g}●{/} {dm}approved       {/} {gd}CSE-201: refactor token cache{/}
{bo}π{/} {dm}draft          {/} {dm}bump: dependency update{/}
{r}◐{/} {dm}CI failing     {/} CSE-204: fix pubsub timeout
{y}◐{/} {dm}awaiting review{/} CSE-205: retry policy for webhook
</pre>

## Layout D — Minimal

`wt-badge · age₄ · detail · icon · repo#N · title` (`hub.el:2672`). High-signal,
compact; the phase is implied by the glyph. This is what the retired
`sidebar-demo.txt` §5 showed.

<pre class="sb-markup">
{hd}Requests (4){/}
{c}⎇ {/}  {y}2d{/} {gd bd}@{/} {g}●{/} upside{gd}#16570{/} {gd}CSE-201: refactor token cache{/}
{dm bd}↓ {/} {r}15d{/}   {bo}π{/} upside#16568 {dm}bump: dependency update{/}
{dm bd}↓ {/}  {dm}4h{/} {c bd}@{/} {r}◐{/} reapit#123 CSE-204: fix pubsub timeout
     {y}1d{/} {gd}💬{/} {y}◐{/} upside#16571 CSE-205: retry policy for webhook
</pre>

## Section-header badges

The `Requests (N)` header grows badges for active filters (`hub.el:2581`):

<pre class="sb-markup">
{hd}Requests (4){/} {gd bd}@{/}          mention filter = me        (M-… / @)
{hd}Requests (4){/} {c bd}@{/}          mention filter = team
{hd}Requests (4){/} {bo}🤖{/}         bot-authors = show
{hd}Requests (4){/} {bo}🤖{/}{gd bd}@{/}        bot-authors = mentioned-only
{hd}Requests (4){/} ⇅          sort reversed (newest-first)
</pre>

## Toggles (the `T` → Requests group)

| Key | Toggle | Effect |
|-----|--------|--------|
| `D` | Layout | cycle A → B → C → D |
| `@` | Mention | off → me → team → me+team |
| `F` | Age | `all` / `1d` / `3d` / `7d` / `14d` / `30d` |
| `C` | CI | filter by CI state |
| `b` | 🤖 bot-review | hide PRs whose latest activity is a bot (default on) |
| `B` | bot-authors | hide → show → mentioned |
| `c` | 💬 comments | hide PRs whose latest non-bot activity is someone else |
| `M` | ↩ replies-to-me | only PRs where a human replied in my thread |
| `s` | sort ⇅ | flip oldest↔newest (seeds the `r` picker) |
| `X` | ⚠ conflict | hide `mergeable = CONFLICTING` PRs (default on) |

## Source

- Renderer + layout cycle: `agent-shell/hub-bulk/decknix-agent-shell-hub.el:2563`
- Primary icon / age / activity icons: `agent-shell/hub/decknix-hub-icons.el`
- Active-review tint: `decknix--hub-request-tint-active`, `hub.el:2711`
