# Guided Tour

A "screencast" of the Agent Shell, grouped by topic — from the welcome screen to
opening the sidebar and running the everyday flows. Each step shows the **keys
pressed** and a **mock of what appears**. Colours are the real Emacs face colours
(same palette as the [Sidebar Layouts](./layouts/index.md)); the frames are
mock-ups, so spacing is approximate — colour and layout are the contract.

**Legend** — provider glyph `A` Auggie · `C` Claude · `P` Pi. Session state:

<pre class="sb-markup">{dm}○{/} initializing   {y}◐{/} working   {r}◐{/} waiting (needs input)
{g}●{/} ready          {ac}●{/} finished  {r}●{/} killed</pre>

---

# Getting oriented

## The welcome screen

Emacs opens on the `*decknix*` buffer. Press `C-c w` to return to it any time.

<span class="keys"><kbd>emacs</kbd></span>

<pre class="sb-markup">  {hd}       __     _   __  __  _   ___ ___{/}
  {ac}   __| |___ / | | ' \|  \/  || | / __/ __| {/}
  {c}  / _` / -_) || |  ' <| |\/| || || \__ \__ \ {/}
  {br}  \__,_\___|_||_|_|\_\_|  |_||_|/_|___/___/ {/}

  {bd}Welcome to dEckMACS{/} — a modern, batteries-included Emacs config
  {dm}Vertico • Consult • Marginalia • Corfu • Embark • Magit{/}

  {c bd}1{/} Navigation & Search   {dm}C-s   M-s r   C-x b{/}
  {c bd}2{/} Editing               {dm}C-/   C-?     C-x u{/}
  {c bd}3{/} Completion & Code     {dm}TAB   C-.     M-n/p{/}
  {c bd}4{/} Git (Magit)           {dm}C-x g C-x M-g s / u{/}
  {c bd}5{/} Buffers & Windows     {dm}C-x C-f C-x k C-x 1{/}
  {c bd}6{/} Help & Discovery      {dm}C-h f C-h k  C-h t{/}

  {dm}Press 1-6 for full cheat sheets • r refresh • q quit{/}
  {dm}C-h ? help • C-x b buffers • C-x C-f files • C-c w this screen{/}</pre>
<p class="sb-cap">The shipping welcome buffer. Numbers <code>1</code>–<code>6</code> open per-topic cheat sheets.</p>

### …with agents surfaced *(proposed)*

The welcome screen is a natural home for a **live agent summary** and quick-actions
into the Agent Shell. A proposed addition — a category `7` plus a status strip that
mirrors the sidebar's Live section:

<pre class="sb-markup">  {c bd}6{/} Help & Discovery      {dm}C-h f C-h k  C-h t{/}
  {c bd}7{/} {ac bd}AI Agents{/}            {dm}C-c A a start  C-c A w sidebar  C-c A s sessions{/}

  {dm}Agents{/}  {y}◐ 2 working{/}   {r}◐ 1 waiting{/}   {g}● 3 ready{/}   {dm}·  C-c A w to open{/}</pre>
<p class="sb-cap"><em>Proposed</em>, not yet shipped — mocked to show the intent (see <a href="./comparison.html">How It Compares → roadmap</a>).</p>

## Open the Agents sidebar

<span class="keys"><kbd>C-c A w</kbd></span>

The four-section workspace sidebar opens on the right: **Requests → WIP → Live →
Sessions**.

<pre class="sb-markup">{hd}Requests (3){/} ⇅
{c}⎇ {/} {y}2d{/} upside{gd}#16570{/} {g}●{/}{gd bd}@{/}{ac}◉{/} {gd}CSE-201: refactor token cache{/}
{dm bd}↓ {/}{r}15d{/} upside#16568 {bo}π{/}   {dm}bump: dependency update{/}
{dm bd}↓ {/} {y}1d{/} reapit#123 {r}◐{/}{c bd}@{/} CSE-204: fix pubsub timeout

{hd}WIP (2){/}
{g bd}⎇*{/} {g}●{/} decknix{gd}#812{/}       [3⬆ 2✓]
{c}⎇ {/} {y}★{/} decknix-config#77  {y}draft{/}

{hd}Live (2){/}
 > {y}A{/} {y}◐{/} feature/token-cache  {rp}decknix{/}   [2⬆ 1✓] {r bd}📥1{/}
   {g}C{/} {g}●{/} review/auth          {rp}decknix{/}   {sg bd}↩{/}

{hd}Sessions (18){/}  {dm}…recent by tag / date{/}</pre>
<p class="sb-cap">Colour is load-bearing: <span class="g">green</span> approved/ready, <span class="r">red</span> needs-you/CI-fail, <span class="y">yellow</span> draft/working, <span class="c">blue</span> branch, <span class="bo">pink</span> bot. <code>⎇*</code> = branch live in a session; <code>◉</code> = a review session is already open on that PR.</p>

---

# Running a session

## Start a session

<span class="keys"><kbd>C-c A n</kbd></span>

A provider picker appears (Vertico). Choose the agent to launch.

<pre class="sb-markup">{dm}Start agent (provider):{/}
 {ac}>{/} {g}C{/}  Claude Code        {dm}(default · claude-code){/}
   {y}A{/}  Auggie             {dm}(Augment Code){/}
   {c}P{/}  Pi                 {dm}(Contextual AI){/}
   {dm}?{/}  Gemini             {dm}(Google){/}</pre>
<p class="sb-cap">Pick <code>C</code> and a fresh Claude session buffer opens; the Live section gains a <span class="dm">○</span>→<span class="y">◐</span> row.</p>

## Watch its sub-agents

<span class="keys"><kbd>C-c A w</kbd></span>

As the agent spins up sub-agents, the Live section shows each with its own state —
colour tells you at a glance who needs you and who's done.

<pre class="sb-markup">{hd}Live (1 · 3 sub){/}
 > {g}C{/} {y}◐{/} feature/token-cache   {rp}decknix{/}
     {dm}├─{/} {g}●{/} explore   {dm}mapped cache call-sites{/}
     {dm}├─{/} {y}◐{/} implement {dm}editing cache.rs …{/}
     {dm}└─{/} {r}◐{/} verify    {r bd}needs input{/} {dm}approve test run?{/}</pre>
<p class="sb-cap">Per-sub-agent status + colour + a fold toggle for completed ones is the near-term build (Feature 1 of the resourcing roadmap); mocked as the target UX.</p>

## Compose a multi-line prompt

<span class="keys"><kbd>C-c A e</kbd></span>

A dedicated compose buffer opens — write freely, then submit.

<pre class="sb-markup">{dm}─ *compose: feature/token-cache* ──────────────{/}
 Refactor the token cache to expire entries lazily
 on read instead of a background sweep. Keep the
 public API stable; add a test for the 410 path.

{dm}────────────────────────────────────────────────{/}
 {ac}C-c C-c{/} submit   {dm}C-c C-k cancel   M-p/M-n history   M-r search{/}</pre>
<p class="sb-cap"><kbd>C-c C-c</kbd> sends it; <kbd>M-p</kbd>/<kbd>M-n</kbd> walk prompt history, <kbd>M-r</kbd> searches it (consult).</p>

---

# Reviewing & shipping

## Review a PR

<span class="keys"><kbd>C-c A c</kbd><span class="then">→</span><kbd>r</kbd></span>

From a Requests row (or the quick-action), launch a review session pre-linked to
the PR.

<pre class="sb-markup">{hd}Requests (3){/}
 {ac}>{/} {c}⎇ {/} {y}2d{/} upside{gd}#16570{/} {g}●{/}{gd bd}@{/} {gd}CSE-201: refactor token cache{/}
       {dm}review session launching…{/} {ac}◉{/}
   {dm bd}↓ {/}{r}15d{/} upside#16568 {bo}π{/} {dm}bump: dependency update{/}</pre>
<p class="sb-cap">The <span class="ac">◉</span> marks the row now has a live review session. <kbd>C-c s l</kbd> links another PR to the current session; <kbd>C-c s u</kbd> unlinks.</p>

## Inspect · tag · link

<span class="keys"><kbd>C-c s i</kbd></span>

`C-c s i` prints a one-line session summary; `C-c s t a` adds a tag; `C-c s l`
links a PR.

<pre class="sb-markup">{dm}Session:{/} 3f9a1c2e…  {dm}Conv:{/} b71e…  {dm}Model:{/} {g}opus{/}  {dm}Mode:{/} {y}auto{/}
{dm}Tags:{/} {c}#token-cache #CONN-473{/}   {dm}Exchanges:{/} 14
{dm}Workspace:{/} ~/tools/decknix
{dm}Created:{/} 2026-07-08 09:12   {dm}Modified:{/} 2026-07-08 13:47</pre>
<p class="sb-cap">Tags, workspace, model, permission-mode and linked PRs all persist per-conversation and survive resume/fork.</p>

## Copy a region as Slack / HTML / PDF

<span class="keys"><kbd>C-c x s</kbd></span>

Select any Markdown in the buffer and export it — `s` Slack mrkdwn, `h` HTML,
`P` PDF, `t` plain / re-align table.

<pre class="sb-markup">{dm}region (Markdown):{/}
  **Root cause:** the `/rest/api/2/search` endpoint was removed.
  See [the changelog](https://x/CHANGE-20).

{ac}C-c x s{/}  {dm}→ clipboard (Slack mrkdwn):{/}
  {g}*Root cause:* the `/rest/api/2/search` endpoint was removed.
  <https://x/CHANGE-20|the changelog>{/}</pre>
<p class="sb-cap">Fence- and table-aware, pure-string transforms — paste straight into Slack, a PR comment, or a doc.</p>

---

# Managing many sessions

## Resume a past session

<span class="keys"><kbd>C-c A s</kbd></span>

One picker spans **live + saved + new**. Live rows are coloured, saved ones dimmed;
`M-a` / `M-c` / `M-p` toggle Auggie / Claude / Pi rows, `C-u C-c A s` expands every
saved snapshot.

<pre class="sb-markup">{dm}Sessions — live + saved  (M-a/M-c/M-p filter · C-u expand):{/}
 {ac}>{/} {g}C{/} {g}●{/} review/auth          {dm}decknix · 2m{/}      {c}#auth{/}
     {y}A{/} {y}◐{/} feature/token-cache   {dm}decknix · now{/}
     {dm}C{/} {dm}·{/}  CONN-473 spike        {dm}decknix · 3d{/}      {c}#spike{/}
     {dm}A{/} {dm}·{/}  proptrack timeout     {dm}nurturecloud · 5d{/}</pre>
<p class="sb-cap">Selecting a saved row resumes it with its history window restored and input ring rebuilt. <kbd>C-c A f</kbd> forks a session instead — the fork keeps the source's tags, workspace and conversation identity.</p>

## Search every session

<span class="keys"><kbd>C-c A g</kbd></span>

Full-text ripgrep across *all* transcripts, with the match in context. `RET` jumps
straight to the matching turn.

<pre class="sb-markup">{dm}Grep all sessions:{/} {c}pubsub timeout{/}
 {gd}proptrack timeout{/}   {dm}nurturecloud · 5d{/}
   {dm}…the {/}{y}pubsub timeout{/}{dm} was an unacked message redelivery …{/}
 {gd}CONN-473 spike{/}      {dm}decknix · 3d{/}
   {dm}…retry policy on a {/}{y}pubsub timeout{/}{dm} should back off …{/}</pre>
<p class="sb-cap">Never lose a decision — find the conversation where you made it.</p>

## Jump to what needs you

<span class="keys"><kbd>C-c A j</kbd></span>

Cycle straight to the next session carrying red/amber attention — the agent-shell
answer to cmux's "which one needs me?"

<pre class="sb-markup">{dm}Jump to attention →{/}  {r}◐{/} feature/token-cache  {dm}(verify: “approve test run?”){/}</pre>
<p class="sb-cap">Repeated presses walk the attention queue: waiting sessions first, then CI failures and review requests.</p>

## Batch one prompt to several sessions

<span class="keys"><kbd>C-c A s</kbd><span class="then">→</span><kbd>C-SPC</kbd><span class="then">…</span><kbd>B</kbd></span>

Mark rows in the picker with `C-SPC`, then batch a single prompt to all of them —
handy for "rebase onto main" or "add the new lint" across several worktrees.

<pre class="sb-markup">{dm}Sessions  (C-SPC mark · B batch):{/}
 {g}✓{/} {g}C{/} {g}●{/} review/auth           {rp}decknix{/}
 {g}✓{/} {g}A{/} {g}●{/} feature/token-cache   {rp}decknix{/}
   {dm}A{/} {dm}·{/}  proptrack timeout      {rp}nurturecloud{/}
 {dm}2 marked{/} {ac}· B → send one prompt to both{/}</pre>
<p class="sb-cap">Marked sessions each receive the composed prompt; results stream back into their own buffers.</p>

---

## Keys used in this tour

| Keys | Does |
|---|---|
| <kbd>C-c w</kbd> | Open the `*decknix*` welcome screen |
| <kbd>C-c A w</kbd> | Open the Agents sidebar (workspace) |
| <kbd>C-c A a</kbd> / <kbd>C-c A n</kbd> | Start / switch · force a new session |
| <kbd>C-c A s</kbd> | Session picker (live + saved + new); <kbd>M-a</kbd>/<kbd>M-c</kbd>/<kbd>M-p</kbd> filter, <kbd>C-SPC</kbd> mark |
| <kbd>C-c A g</kbd> | Grep across every session |
| <kbd>C-c A j</kbd> | Jump to the next session needing attention |
| <kbd>C-c A e</kbd> | Compose a multi-line prompt |
| <kbd>C-c A c</kbd> <kbd>r</kbd> / <kbd>l</kbd> / <kbd>u</kbd> | Review PR · link PR · unlink |
| <kbd>C-c x</kbd> <kbd>s</kbd> / <kbd>h</kbd> / <kbd>P</kbd> / <kbd>t</kbd> | Copy region as Slack · HTML · PDF · plain |
| <kbd>C-c s i</kbd> / <kbd>t a</kbd> / <kbd>l</kbd> | Session info · add tag · link PR |

Inside an agent-shell buffer the `A` prefix is dropped — `C-c s`, `C-c e`, `C-c ?`.
Full reference: [Keybindings](./keybindings.md).
