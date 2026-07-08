# How It Compares

The Agent Shell is not another terminal multiplexer, IDE, or cloud agent — it is
an **editor-native coordination framework**. This page is a **candid assessment,
not a scorecard**: it compares the Agent Shell with the tools teams reach for when
running AI coding agents to find (a) where those tools have better ideas worth
**borrowing**, (b) where decknix genuinely **leads**, and (c) the **gaps nobody
fills yet** that decknix is positioned to bridge. They solve overlapping problems
on very different substrates.

> **Legend:** ✅ native / first-class · ◐ partial or via workflow · ✗ absent
>
> _Competitor features move quickly. This snapshot was compiled **July 2026**;
> verify specifics against each tool's current docs (linked below)._

## The tools, in one line each

| Tool | What it fundamentally is |
|------|--------------------------|
| **decknix / deckmacs Agent Shell** | An **Emacs-native, Nix-configured** framework that *coordinates* multiple AI agents (over ACP) and *ties their work to your project's real state* — issues, PRs, CI, worktrees. |
| **[cmux](https://cmux.com)** | A native macOS **terminal multiplexer** (Ghostty) that turns parallel agents and their sub-agents into panes/splits with attention rings. |
| **[supacode](https://supacode.sh)** | A native macOS **"command center" app** (libghostty) for running 50+ CLI agents in parallel, each in its own worktree. |
| **[Cursor](https://cursor.com)** | An **AI IDE**; its *Agents Window* launches up to 8 parallel agents, each in an isolated worktree, emitting PRs. |
| **[OpenAI Codex](https://openai.com/codex/)** | A **multi-surface agent** (CLI + IDE + web + cloud) on one execution model; runs parallel cloud tasks in sandboxes and proposes PRs. |
| **[Augment Intent](https://www.augmentcode.com/blog/intent-a-workspace-for-agent-orchestration)** | A **web workspace for agent orchestration**: a coordinator drafts a living spec, implementor agents run in parallel worktrees, a verifier checks. |
| **[Claude Code](https://www.anthropic.com/claude-code)** | A multi-surface agent (terminal · IDE · desktop · web) with subagents, agent-teams, worktrees and an `agent view` dashboard — **one of the agents decknix drives**, not a competitor to it. |

## Substrate & parallelism

| Capability | Agent Shell | cmux | supacode | Cursor | Codex | Intent | Claude Code |
|---|---|---|---|---|---|---|---|
| Runs **inside your existing editor** | ✅ Emacs | ✗ terminal | ✗ app | ◐ its own IDE | ◐ IDE/CLI | ✗ desktop app | ◐ CLI/IDE ext |
| **Multi-vendor** agents (not one model) | ✅ ACP: Claude Code · Auggie · Pi · Gemini | ✅ any TTY agent | ✅ any CLI agent | ◐ Cursor-managed | ✗ OpenAI only | ✅ BYOA | ✗ Anthropic |
| Run **many agents in parallel** | ◐ many sessions + sub-agents | ✅ panes | ✅ 50+ | ✅ up to 8 | ✅ cloud queue | ✅ roles | ✅ background agents |
| **Sub-agents made visible** | ◐ shown (status: roadmap) | ✅ as panes | ✗ independent, not nested | ✅ Agents Window | ✅ collected results | ✅ coord/impl/verify | ✅ agent view / teams |
| Auto **worktree-per-agent** isolation | ◐ worktree-*aware* | ◐ scripted | ✅ native | ✅ | ✅ | ✅ | ✅ `--worktree` |

The right-hand tools win the *"fan out eight agents and race them"* game — decknix's
model is deliberately **one focused session per unit of work, coordinated and
tracked**, with parallelism through additional sessions, provider sub-agents, and
the `pr-implementer` / `pr-shepherd` workflow. Fan-out-per-worktree is a roadmap
direction (see [Sidebar Layouts → WIP](./layouts/wip.md)), not the current centre
of gravity.

## Coordination, provenance & attention

| Capability | Agent Shell | cmux | supacode | Cursor | Codex | Intent | Claude Code |
|---|---|---|---|---|---|---|---|
| Persistent **sidebar / overview** | ✅ Requests · WIP · Live · Sessions | ✅ tabs | ✅ worktree list | ✅ Agents Window | ✅ app 3-pane | ✅ workspace | ✅ agent view |
| **Attention state as colour** | ✅ red/amber/green tied to CI · review · age | ✅ blue "needs you" ring | ✅ busy / awaiting / idle badges | ✅ push / iOS | ✅ app + iOS | ◐ verifier | ✅ agent-view state icons |
| **PR** create / review | ✅ link · review mode · hub reviews | ◐ shows PR # / status | ✅ GitHub-native | ✅ emits PRs | ✅ proposes PRs | ✅ | ✅ commits · PRs · `@claude review` |
| **Cross-service provenance** — Jira · Confluence · CI · Slack | ✅✅ hub aggregates Jira · Confluence · GitHub · TeamCity CI (Slack / email / data / support: roadmap) | ✗ git/PR only | ✗ GitHub/CI | ◐ Slack · Linear · GitHub triggers | ◐ Linear · Slack · Jira (MCP) | ◐ Context Engine (MCP) | ◐ Jira · Slack · Linear (MCP) |
| **Timeline / history** of what happened | ◐ session history · grep · nav (full timeline: roadmap) | ✗ live panes only | ✗ | ✗ | ✗ | ◐ living spec | ✗ |
| **Per-conversation** resource tracking (PRs authored vs reviewed, tags, worktree, model, mode) | ✅✅ | ✗ | ✗ | ◐ per-agent | ◐ per-task | ◐ per-spec | ◐ per-session |

This is the row that matters most — and note the honest ◐s: several tools now
surface attention and can *act on* Jira/Slack/Linear through MCP connectors. But
they reach each service **on demand, per connector**. Agent Shell instead
**aggregates and attributes** that external state: the [hub](../../../hub.md) polls
Jira, Confluence, GitHub and CI into one store; the [progress layer](./context.md)
rolls it up into a red/amber/green attention model; and
[per-conversation linking](./context.md) attributes PRs (authored vs. reviewed),
worktrees and tickets to the session that produced them — answering not just
*"which agent needs me?"* but *"what has this session actually **done**, across
every service, and when?"*

## Openness & extensibility

| | Agent Shell | cmux | supacode | Cursor | Codex | Intent | Claude Code |
|---|---|---|---|---|---|---|---|
| **Config-as-code** | ✅✅ Nix — declarative, reproducible, org-shareable | ✗ | ✗ | ✗ | ◐ config.toml | ✗ | ◐ CLAUDE.md / settings |
| **Extension surface** | ✅ Elisp + Nix options + MCP | ✅ socket API / CLI / skills | ◐ CLI / deeplinks | ◐ extensions / MCP | ✅ SDK / MCP / skills / Action | ◐ MCP / Context Engine | ✅ SDK / MCP / hooks / skills |
| **Open source** | ✅ | ✅ GPL-3.0 | ◐ source-available (FSL) | ✗ | ◐ CLI only (Apache-2.0) | ✗ | ✗ proprietary |
| **Cost model** | Free / OSS | Free / OSS | Free beta | Paid IDE | Subscription / API | Paid (credits) | Subscription / API |
| **Session persistence / resume** | ✅✅ resume + fork carry model, permission-mode, tags | ◐ contested | ✅ zmx reattach | ✅ | ✅ resume + fork | ✅ | ✅ resume + fork |

## Where it genuinely leads

Pulling the matrix together, four things are **rare or absent** everywhere else —
these are real strengths today, not aspirations:

1. **It lives in your editor.** Every other tool is a terminal, an app, a web
   workspace, or *its own* IDE. Agent Shell is a first-class Emacs citizen —
   agents sit next to your buffers, magit, and org files, driven by the same
   keybinding muscle memory. (See [Keybindings](./keybindings.md).)
2. **Config-as-code, org-shareable.** Providers, models, MCP servers, sidebar
   layout, and review defaults are declared in **Nix** and rolled out with
   `decknix switch` — reproducible per machine and inheritable across a team's
   org config. No other tool here ships its coordination setup as version-controlled,
   composable configuration. (See [Integration](./integration.md).)
3. **Vendor-neutral by protocol.** ACP lets one interface drive Claude Code,
   Auggie, Pi, or Gemini — and pin a different model/mode *per purpose* (e.g.
   Opus for reviews, a cheaper tier elsewhere). You are not married to one model
   or one company's roadmap.
4. **Structured cross-service provenance.** Others can *act on* external services
   via MCP connectors; the hub + progress layer instead **aggregate and attribute**
   them — issues, PRs, CI, reviews (and, on the roadmap, Slack/email, data and
   support activity) — into a colourised, per-conversation ledger. The competitors
   stay largely **git/PR-centric**; decknix models the *whole* footprint of a piece
   of work.

## Where it falls short — and what to borrow

The honest weak spots, and where a competitor already has the better idea:

- **Emacs-native is a floor *and* a ceiling.** It's the point for Emacs users, but
  real onboarding friction for everyone else — the IDE/terminal tools have a gentler
  on-ramp. Nothing to borrow here; just a cost to own.
- **No one-command fan-out.** "Spawn N agents, each in its own worktree, then diff
  and pick the winner" is the home turf of Cursor, Codex, Conductor, supacode and
  Claude Code's `agent view`. decknix is worktree-*aware* but doesn't yet fan out.
  **Borrow:** the worktree-per-agent launch plus a side-by-side diff/pick flow.
- **Sub-agent status is invisible.** Sub-agents are discovered but carry no
  lifecycle state. Team feedback from trialling cmux specifically praised its
  per-session **"needs input vs still running"** indicator and **auto-rename by
  conversation progress**. **Borrow both:** colourise sub-agents by state (the
  progress layer's red/amber/green already models it) and generate a one-line
  progress summary (à la Claude Code's agent-view summaries) to auto-name sessions.
  This is Feature 1 of the resourcing roadmap.
- **No in-editor verification surface.** cmux's embedded browser for PR review and
  rendered docs is genuinely handy. decknix already ships `xwidget-webkit` and the
  `/verify` skill — **borrow** the idea of surfacing them as a first-class
  review/verify affordance beside the session.
- **Sub-agents can't talk to each other.** Claude Code's experimental *agent teams*
  give teammates a mailbox and a shared task list; decknix's sub-agents are
  report-only. **Borrow** inter-agent coordination if multi-agent workflows deepen.
- **Sessions aren't shareable.** Amp's referenceable, team-visible *Threads*
  (`@T-id`) are a nice collaboration primitive; decknix sessions are local — worth
  considering for team review visibility.

## Gaps decknix is positioned to bridge

Where the whole field has **white space** — and decknix already holds the primitives
or a head start:

- **Multi-human, multi-agent *governed* pairing.** Every tool here is
  single-human-with-agents. None let *two or more people, each with their own
  agents,* share one governed conversation — with full transcripts, durable
  artifacts, and an explicit path from "we discussed it" to "there is a PR in the
  right repo." decknix already sketches this direction in its draft
  **[Pair Protocol](../../../pair-protocol.md)**, and the pieces it would build on —
  the coordination substrate, per-conversation identity, and provenance primitives —
  are already in place. It is a genuinely open space: nobody in this landscape is
  building *collaboration through* agents, only *operation of* them.
- **A cross-service resourcing ledger + timeline.** The `C-c s a` transient — a tree
  of a session and its sub-agents, each with what it produced: PRs authored/reviewed,
  **linked issues across Jira and GitHub**, worktrees, plus messaging, data, and
  support activity — over a swimlane timeline of *when* it happened. The hub, the
  progress layer, and per-conversation links are the raw material; no competitor
  aggregates provenance this way.
- **Accountability, not just fan-out.** The field optimises *starting* many agents;
  decknix is positioned to own *accounting for* what they did — the provenance,
  attention, and audit trail of a piece of work across every service it touched.

The near-term build order (sub-agent state + colourisation → `C-c s a` resourcing
transient → timeline) is tracked under [Sidebar Layouts](./layouts/index.md).

## The wider landscape

The matrix samples the field; the fuller taxonomy shows where these tools cluster —
and where the Agent Shell sits apart:

- **Terminal multiplexers** — [cmux](https://cmux.com), [supacode](https://supacode.sh):
  panes + worktrees + attention rings, macOS-native, model-agnostic. Excellent at
  fan-out; no cross-service provenance. (cmux is GPL-3.0; supacode is FSL
  source-available, not classic OSS.)
- **Desktop orchestrators over agent CLIs** — [Conductor](https://www.conductor.build/):
  free (bring your own subscription), worktree-per-agent, built-in diff/PR flow,
  start-from-Linear-issue.
- **Kanban-as-orchestration** — [Vibe Kanban](https://github.com/BloopAI/vibe-kanban):
  a board that spawns any of ~10 agent CLIs into worktrees; Apache-2.0 — but now
  **community-maintained after Bloop's April 2026 sunset**, so weigh its longevity.
- **AI IDEs** — [Cursor](https://cursor.com): parallel agents + worktrees inside its
  own editor, plus cloud agents and Slack/Linear/GitHub triggers.
- **Multi-surface first-party agents** — [OpenAI Codex](https://openai.com/codex/),
  [Sourcegraph Amp](https://ampcode.com): one agent across CLI/IDE/web/cloud; Amp
  adds native sub-agents and team-shared "Threads." Curated models; Amp has no
  worktree isolation.
- **Enterprise orchestrators** — [Augment Intent](https://www.augmentcode.com/blog/intent-a-workspace-for-agent-orchestration):
  coordinator → implementors → verifier over bring-your-own agents, worktree-backed.

Across all of them, the Agent Shell is the only one that is simultaneously
**editor-native (Emacs)**, **declared as Nix config-as-code**, and **backed by a
structured cross-service hub**. The others optimise fan-out and PR flow; decknix
optimises the *coordination, provenance, and accountability* of the work — and
does it *inside the editor you already live in*.

---

_Sources: [cmux](https://cmux.com) · [supacode](https://supacode.sh) ·
[Cursor](https://cursor.com/docs) · [OpenAI Codex](https://developers.openai.com/codex) ·
[Augment Intent](https://www.augmentcode.com/blog/intent-a-workspace-for-agent-orchestration) ·
[Claude Code](https://code.claude.com/docs) · [Conductor](https://www.conductor.build/) ·
[Vibe Kanban](https://github.com/BloopAI/vibe-kanban) · [Sourcegraph Amp](https://ampcode.com).
Compiled July 2026; agent tooling moves fast — verify against each tool's current docs._
