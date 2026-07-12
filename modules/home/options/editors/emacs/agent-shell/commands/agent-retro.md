---
description: Retrospective on recent agent interactions — surface friction, wasted tool calls, and cross-repo workflow optimisations, then promote fixes into config
argument-hint: "[agent=<type>] [start=<when>] [end=<when>]"
---

# Agent retro

Review my recent interactions with a coding agent, find what slowed us
down, and produce a concrete plan to optimise the flow — then promote
durable fixes into version-controlled config rather than leaving them as
one-off advice.

## Arguments

Parse `$ARGUMENTS` for the following `name=value` pairs (any order; all
optional). Accept bare values positionally too, in the order agent, start,
end.

- **`agent`** — the agent type to review. Default: the agent you are
  currently running as (e.g. `claude`). Accepted: `claude` (aka
  `claude-code`), `auggie` (aka `augment`), `pi`.
- **`start`** — start of the window. Default: **yesterday 00:00** (local).
- **`end`** — end of the window. Default: **now**.

`start` / `end` accept either an absolute date/time (`2026-07-10`,
`2026-07-10T14:00`) or a **relative duration** measured back from *now*:
`60s`, `2m`, `5h`, `7d`, `7w` — where `s`=seconds, `m`=minutes, `h`=hours,
`d`=days, `w`=weeks. E.g. `start=7d` means "7 days ago", `end=2h` means
"2 hours ago". Echo the resolved absolute window before you begin so I can
correct it.

## Where the transcripts live

Locate the chosen agent's session transcripts for the window, filtering by
file mtime (and, where present, in-file timestamps) to the resolved range:

- **claude** — `~/.claude/projects/<slug>/*.jsonl` (one `<slug>` dir per
  working directory; a session is one `.jsonl`). Read the JSONL turns:
  `type`/`role`, `message.content` blocks (`text`, `tool_use`,
  `tool_result`).
- **auggie** — `~/.augment/sessions/*.json`.
- **pi** — the Pi session store under `~/.pi/`.

Use a subagent (or several, in parallel) to read across the transcripts so
you keep the conclusions, not the raw dumps, in context. Do NOT `cat` whole
large transcripts into the main thread.

## What to look for

Look thoroughly through all conversations in the window and identify:

- **Problems I hit** — errors, dead-ends, things that weren't working, and
  where I had to repeat myself or correct the agent.
- **Inefficiency** — unnecessary or redundant tool calls, re-reading files
  already in context, re-deriving known facts, serial calls that could have
  been parallel, permission prompts that recurred.
- **Common agent mistakes** — recurring wrong assumptions, wrong file/paths,
  ignored conventions, misremembered APIs, output-format slips.
- **Optimisations** — for the flow within each workspace, within a worktree,
  within a single repository, and **cross-repository** (multi-repo work in
  one session).
- **Pre-flight insights** — things the agent should know *before* entering a
  repository, and *before* working across multiple repositories at once
  (build/test commands, conventions, gotchas, where things live).

## Output

1. A ranked findings list: each finding = symptom → evidence (which
   session/turn) → root cause → fix.
2. An optimisation plan grouped by scope: workspace / worktree / repo /
   cross-repo / pre-flight.
3. **Promote durable fixes into config, not memory.** For each actionable
   finding, propose the concrete, reproducible home per the maturity ladder
   — a workspace `AGENTS.md`, the user-level guidelines
   (`~/.claude/CLAUDE.md` / `.augment-guidelines`, source
   `decknix/…/agent-shell/guidelines.md`), a slash command or skill, a
   `settings.json` permission/hook, or a code/default change in `decknix` /
   `decknix-config`. Machine-local per-fact memory files are NOT an
   acceptable destination — they are lost on reimage.

Present the plan and wait for my go-ahead before writing any config changes.
