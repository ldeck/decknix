# Live

Live agent sessions. Five **view modes** (cycle with `v` / the Live view toggle),
plus optional **linked-PR** and **linked-repo** rows expanded beneath each
session. See the [colour legend](./index.md#colour-legend-source-of-truth).

## Session status family

The leading marker uses the lifecycle shape-family (header-line faces): shape =
stage, colour = state.

<pre class="sb-markup">
{dm}○{/} initializing   {y}◐{/} working   {r}◐{/} waiting (needs input)
{g}●{/} ready          {ac}●{/} finished  {r}●{/} killed
</pre>

## Provider glyph

Every live-session row is prefixed with a **provider glyph** — a single letter
that identifies the AI backend running in that buffer:

| Glyph | Provider |
|-------|---------|
| `A`   | Auggie (Augment Code) |
| `C`   | Claude Code (Anthropic) |
| `P`   | Pi |
| `?`   | Unknown / unregistered provider |

The glyph is coloured with the same status face as the lifecycle marker so it
reads as part of the same signal group. Additional providers registered via
`decknix-agent-register-provider` automatically appear here using their `:glyph`
field.

## View modes

A session row is `sel · glyph · marker · name · tile · [N⬆ N✓] · 📥/📤/📬/👽 · progress`.
`>` marks the selected buffer. Tags are capped at 3 for readability; full tags
are always visible in the header-line of the buffer itself.

### Flat

<pre class="sb-markup">
{hd}Live (3){/}
 > {y}A{/} {y}◐{/} feature/foo  {rp}decknix{/}        [2⬆ 1✓] {r bd}📥1{/}
   {g}A{/} {g}●{/} feature/bar  {rp}decknix-config{/}
   {g}C{/} {g}●{/} review/auth  {rp}decknix{/}        [1⬆ 0✓] {sg bd}↩{/}
</pre>

### Grouped by workspace

<pre class="sb-markup">
{hd}Live (3){/}
 {dm}~/tools/decknix{/}
   > {y}A{/} {y}◐{/} feature/foo   [2⬆ 1✓] {r bd}📥1{/}
     {g}C{/} {g}●{/} review/auth
 {dm}~/Code/nurturecloud/decknix-config{/}
     {g}A{/} {g}●{/} feature/bar
</pre>

### Grouped by path (last component, tag stripped)

<pre class="sb-markup">
{hd}Live (3){/}
 {rp}decknix{/}
   > {y}A{/} {y}◐{/} feature/foo   [2⬆ 1✓] {r bd}📥1{/}
     {g}C{/} {g}●{/} review/auth
 {rp}decknix-config{/}
     {g}A{/} {g}●{/} feature/bar
</pre>

### Grouped by shared tags

<pre class="sb-markup">
{hd}Live (5){/}
 {dm}nurturecloud/CONN{/}
   > {y}A{/} {y}◐{/} #10861/ARC
     {g}A{/} {g}●{/} #7/#202
 {dm}Other{/}
     {g}C{/} {g}●{/} review/auth
     {r}A{/} {r}◐{/} nurturecloud
     {g}A{/} {g}●{/} decknix-config
</pre>

### Grouped by first tag (tree)

<pre class="sb-markup">
{hd}Live (5){/}
 {dm}nurturecloud{/}
   > {y}A{/} {y}◐{/} CONN/#10861
     {g}A{/} {g}●{/} CONN/#7
 {dm}review{/}
     {g}C{/} {g}●{/} auth
 {dm}Other{/}
     {g}A{/} {g}●{/} decknix-config
</pre>

Attention badges (`hub` enabled): {r bd}📥N{/} linked PRs awaiting
my action, {g bd}📤N{/} ones I've acted on,
{sg bd}📬/👽{/} when any linked PR has replies to me. Terminal
(MERGED/CLOSED) PRs are excluded so stale links don't add noise.

## Sub-agent rows

When a session has spawned sub-agents (Claude Code sub-agents are stored in a
`subagents/` directory next to the session transcript), they are shown as child
rows beneath the parent, indented by 4 characters and dimmed:

<pre class="sb-markup">
   {g}C{/} {g}●{/} review/auth
     {dm}↳ C claude-3-5-sonnet{/}
     {dm}↳ C computer-use{/}
</pre>

The provider glyph on sub-agent rows always matches the parent session's
backend. The name is the sub-agent's slug (model identifier or tool name).

## Linked-PR rows

Shown under a session when the PRs toggle (`E`) is on. Fixed-width columns so
pipeline progress stays scannable across expand modes
(`decknix--hub-pr-format-line`, `hub.el:2003`):

`#N · age₃ · state₆ · CI · b · c · ✓ · [⚠] · DTSP`

<pre class="sb-markup">
   {rp}decknix{/}
     #123  {dm}2d{/} {c bd}open  {/}  {g}⟳{/} {dm}b{/} {sg bd}c{/} {g bd}✓{/}           feature/foo
     #118  {dm}5d{/} {g}merged{/}  {g}⟳{/} {dm}·{/} {dm}·{/} {dm}·{/}           hotfix/login
     {dm}⊳{/} #99 {dm}1d{/} {y bd}draft {/}  {r}⟳{/} {y bd}b{/} {dm}·{/} {y bd}?{/} {r}⚠{/}        fork/patch
</pre>

- **state** (6-wide, left-pad): {c}open{/} /
  {y}draft{/} / {g}merged{/} / {dm}closed{/}.
- **CI** `⟳`: {g}pass{/} / {y}running{/} /
  {r}fail{/} / {dm}idle{/} — always shown.
- **b** bot, **c** comments, **✓** approval — see the legend. Merged rows
  collapse review columns to dim `·`; closed rows stop at the state word.
- **⚠** appears only on OPEN conflicting rows (`mergeable = CONFLICTING`).
- `⊳` prefixes a **subject** PR (I was added as reviewer).

## Linked-repo rows

For repos worked by pushing directly to a branch (linked via `C-c A c L`).
Intermixed with PR rows under the same repo header
(`decknix--hub-repo-format-line`, `hub.el:2208`):

`branch · sha7 · age₃ · CI · DTSP`

<pre class="sb-markup">
   {rp}decknix-config{/}
     {br}main{/}      {dm}a1b2c3d{/} {dm}3h{/}  {g}⟳{/}
     {br}staging{/}   {dm}9f8e7d6{/} {dm}1d{/}  {r}⟳{/}
</pre>

Repo rows intentionally have no state/bot/comment/approval columns — there's no
PR to review.

## Toggles (the `T` → Live group)

| Key | Toggle | Effect |
|-----|--------|--------|
| `v` | view mode | flat → workspace → path → tags → tree → flat |
| `d` | display mode (linked PRs) | off / PR / pipeline / both |
| `H` | hidden | show/hide hidden sessions |
| `N` | repo-name cap | short / medium / full |
| `E` | PRs | off / PR / pipeline / both |
| `y` | symbol style | ascii ↔ emoji |
| `t` | tile | `off → 2 → 3 → 4 → off` |

## Source

- Live renderer: `agent-shell/workspace-bulk/decknix-agent-shell-workspace.el`
- Linked PR / repo formatters: `agent-shell/hub-bulk/decknix-agent-shell-hub.el`
