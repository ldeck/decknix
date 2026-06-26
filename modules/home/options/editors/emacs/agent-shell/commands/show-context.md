---
description: Show current context — summarise status, then verify the stated facts still hold.
argument-hint: "[TASK_KEY | PROJECT_KEY]"
---

Show context. $ARGUMENTS

Summarise where things stand, then **re-verify** the previously known context
against the live state and flag anything that has drifted. This is a status
query, not a plan — be terse.

## Arguments

Parse `$ARGUMENTS` for:
- **`TASK_KEY`** — issue/ticket key (e.g. `CONN-202`). Optional; inferred from context.
- **`PROJECT_KEY`** — project key (e.g. `ARC`, `OPS`, `CONN`, `CORE`). Optional.

If no arguments, default to **session context**.

## Workflow

### 1. Determine scope

| Scope | Condition |
|-------|-----------|
| **Session** | No args (or unrecognised) |
| **Task** | A `TASK_KEY` is present (explicitly or inferred) |
| **Project** | Only a `PROJECT_KEY` is present |

### 2. Gather the previously known context

**Session scope**
- Call `view_tasklist` — this is the primary signal.
- Scan recent conversation for the last user intent and agent output.
- Note any prior summary, decisions, or "next steps" already stated.

**Task scope**
- Fetch the issue (`GET /issue/{TASK_KEY}`).
- List subtasks, linked PRs, and recent comments.

**Project scope**
- Query active/in-progress tickets (`project = X AND status != Done ORDER BY updated DESC`).
- Note open blockers and sprint health.

### 3. Verify it still holds (do not trust stale state)

Don't just replay what was previously known — check each claim against the live
system and report only what you can confirm:

- **Task list** — re-read it; mark items done/changed since they were last mentioned.
- **Code / branch** — `git status -s` and `git log --oneline -10`; confirm referenced
  branches/commits still exist and whether work is committed/pushed.
- **PRs** — re-check each referenced PR's state (open/merged/closed, CI, review).
  A PR assumed "open" may now be merged or closed.
- **Tickets** — re-check status/assignee for any referenced `TASK_KEY`; a ticket
  assumed "in progress" may be Done or reassigned.
- **Files / paths** — confirm any referenced file or artifact still exists.

For anything that changed, record it as **drift** (was → now).

### 4. Produce a concise status report

Output the sections below (omit any that are empty):

```
## Current State
One-sentence summary of where things stand right now (verified).

## Recent Work
- Bullet list of what was completed or decided.

## Drift Since Last Summary
- was X → now Y (only items that changed on re-verification).
- Omit this section entirely if nothing drifted.

## Pending Decisions
- Anything blocking progress that needs a user choice.

## Next Steps
- Ordered list of recommended immediate actions.
```

Keep the whole reply under ~30 lines.
