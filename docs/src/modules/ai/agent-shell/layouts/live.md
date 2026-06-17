# Live

Live agent sessions. Three **view modes** (cycle with the Live display toggle),
plus optional **linked-PR** and **linked-repo** rows expanded beneath each
session. See the [colour legend](./index.md#colour-legend-source-of-truth).

## Session status family

The leading marker uses the lifecycle shape-family (header-line faces): shape =
stage, colour = state.

<pre class="sb-markup">
{dm}○{/} initializing   {y}◐{/} working   {r}◐{/} waiting (needs input)
{g}●{/} ready          {ac}●{/} finished  {r}●{/} killed
</pre>

## View modes

A session row is `sel · marker · name · tile · [N⬆ N✓] · 📥/📤/📬/👽 · progress`.
`>` marks the selected buffer.

### Flat

<pre class="sb-markup">
{hd}Live (3){/}
 > {y}◐{/} feature/foo  {rp}decknix{/}        [2⬆ 1✓] {r bd}📥1{/}
   {g}●{/} feature/bar  {rp}decknix-config{/}
   {r}◐{/} review       {rp}decknix{/}        [1⬆ 0✓] {sg bd}↩{/}
</pre>

### Grouped by workspace

<pre class="sb-markup">
{hd}Live (3){/}
 {dm}~/tools/decknix{/}
   > {y}◐{/} feature/foo   [2⬆ 1✓] {r bd}📥1{/}
     {r}◐{/} review        [1⬆ 0✓] {sg bd}↩{/}
 {dm}~/Code/nurturecloud/decknix-config{/}
     {g}●{/} feature/bar
</pre>

### Grouped by path (last component, tag stripped)

<pre class="sb-markup">
{hd}Live (3){/}
 {rp}decknix{/}
   > {y}◐{/} feature/foo   [2⬆ 1✓] {r bd}📥1{/}
     {r}◐{/} review        [1⬆ 0✓] {sg bd}↩{/}
 {rp}decknix-config{/}
     {g}●{/} feature/bar
</pre>

Attention badges (`hub` enabled): {r bd}📥N{/} linked PRs awaiting
my action, {g bd}📤N{/} ones I've acted on,
{sg bd}📬/👽{/} when any linked PR has replies to me. Terminal
(MERGED/CLOSED) PRs are excluded so stale links don't add noise.

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
| `d` | display mode | flat / grouped-by-workspace / grouped-by-path |
| `H` | hidden | show/hide hidden sessions |
| `N` | repo-name cap | short / medium / full |
| `E` | PRs | off / PR / pipeline / both |
| `y` | symbol style | ascii ↔ emoji |
| `t` | tile | `off → 2 → 3 → 4 → off` |

## Source

- Live renderer: `agent-shell/workspace-bulk/decknix-agent-shell-workspace.el`
- Linked PR / repo formatters: `agent-shell/hub-bulk/decknix-agent-shell-hub.el`
