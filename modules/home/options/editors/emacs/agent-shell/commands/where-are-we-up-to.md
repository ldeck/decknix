---
description: Summarise current status and surface pending decisions/next steps.
argument-hint: "[TASK_KEY | PROJECT_KEY]"
---

Where are we up to? $ARGUMENTS

## Arguments

Parse `$ARGUMENTS` for:
- **`TASK_KEY`** — Jira ticket key (e.g. `CONN-202`). Optional; inferred from context.
- **`PROJECT_KEY`** — Jira project key (e.g. `ARC`, `OPS`, `CONN`, `CORE`). Optional.

If no arguments, default to **session context**.

## Workflow

### 1. Determine scope

| Scope | Condition |
|-------|-----------|
| **Session** | No args (or unrecognised) |
| **Task** | A `TASK_KEY` is present (explicitly or inferred) |
| **Project** | Only a `PROJECT_KEY` is present |

### 2. Gather context

**Session scope**
- Call `view_tasklist` — this is the primary signal.
- Scan recent conversation for last user intent and agent output.
