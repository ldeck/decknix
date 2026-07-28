# On-Support (DoS) Features

The agent-shell ships three in-editor surfaces that turn a team's
"developer-on-support" (DoS) playbook from a static page you *read* into a live
environment you *run*: a prioritised board, a filterable dashboard, and a guided
checklist. They give a support engineer magit-like single-key actions over the
live worklist — browse, investigate, spawn an agent, export the day's audit —
without leaving Emacs.

> **Org engine required.** These surfaces are framework code, but the *data* and
> the *actions* come from an org-provided CLI (the "engine") that reads your
> issue tracker and computes the runbook priority order. NurtureCloud ships one
> as `nc-dos` (see the org config's *TechOps On-Support* page). Point the
> `decknix-dos-board-cli` / `decknix-support-dashboard-*` variables at your own
> engine to light these up for another org.

## The three surfaces (complementary)

| Surface | Command | What it is | Reach for it to… |
|---------|---------|------------|------------------|
| **Priority board** | `C-c A B` | The cockpit — the runbook's ranked worklist (incidents → alerts → tasks) with one-key actions per row | Work top-down: land on the next item and act |
| **Support dashboard** | `C-c A D` | The reference view — the full board + alert feed, grouped by status and filterable | Survey / slice by user, category, or service; draft the daily log |
| **Guided workflow** | `C-c A W` | The map — the day-aware "what to do, when, how" checklist | Know the order of the day and tick tasks off |

All three are read-only, deterministic (no LLM), and refresh only while visible,
so they are cheap to leave open all day. They are backed by the **same engine**,
so the board here and the terminal console stay in parity.

## The DoS priority board — `C-c A B`

The living playbook. It renders the engine's computed priority model as ranked
lanes and stamps each row with its ticket key, so single-key actions operate on
the item at point. The header is the constant-attention surface: weekday,
deploy/freeze posture, weekly-report freshness, and live open-work counts.

| Key | Action |
|-----|--------|
| `RET` / `o` | Browse the ticket at point |
| `i` | Spawn a **foreground** agent (a new agent-shell session, runbook-primed) on the item |
| `x` | Spawn a **background** agent (headless, logged to the engine's runs dir) |
| `c` | Copy the exact fg/bg spawn commands for the item to the kill-ring |
| `n` / `p` | Move to the next / previous item (`TAB` / `S-TAB` also) |
| `r` | Open the current weekly report |
| `W` | Export today's support worksheet (live counts) and open it in Emacs |
| `g` | Refresh now |
| `?` / `.` | Action menu (magit-style transient) |
| `q` | Bury the board |

## The support dashboard — `C-c A D`

The survey view: the DoS board grouped by status alongside the alert feed, with
filtering. Best when you need to slice the board a different way (everything one
person owns, one service, one category) or draft the day's report entry.

| Key | Action |
|-----|--------|
| `b` / `RET` | Browse the issue at point |
| `/` | Filter by status / category / user / service |
| `\` | Clear all filters |
| `a` | Assign the issue at point |
| `i` | Investigate with a foreground agent |
| `A` | Investigate as an alert (alert-specific prompt + pre-comment gate) |
| `p` | Show the engine's priority panel (text) |
| `x` | Spawn a background agent on the issue |
| `c` | Print / copy the spawn command |
| `t` | Toggle auto-spawn of background agents |
| `r` | Open the weekly report |
| `R` | Draft today's daily-log entry from the live board |
| `w` | Open the guided workflow |
| `g` | Refresh |
| `?` / `.` | Action menu |
| `q` | Bury |

## The guided workflow — `C-c A W`

The day-aware checklist distilled from the playbook work order (daily checks,
scheduled deploys, audits, then the priority ladder). It cross-links into the
other surfaces so you can jump from a step to the live view.

| Key | Action |
|-----|--------|
| `RET` | Run the action for the step at point (e.g. open service dashboards) |
| `o` | Open the link for the step at point |
| `SPC` | Toggle the step done |
| `n` / `p` | Next / previous step |
| `a` | Jump to alert triage (dashboard + the tracker's alert swimlane) |
| `b` | Open the tracker's DoS board in the browser |
| `d` | Open the support dashboard (`C-c A D`) |
| `P` | Open the playbook page |
| `g` | Refresh |
| `?` | Action menu |

## Step-by-step: a support day

1. **Start with the map.** `C-c A W` — read the day's order: production
   incidents first, then daily checks, scheduled deploys (on the stipulated
   days), audits, then the work ladder. Tick items with `SPC` as you go.
2. **Do the daily checks.** From the workflow, `RET` on *Service Health* opens
   the service dashboards; run *Build Health* per your playbook. Note anything
   found for the report.
3. **Live in the cockpit.** `C-c A B` — the board draws the ranked worklist.
   Work top-down:
   - Land on the top **incident** → `RET` to open it; incidents preempt
     everything.
   - Move to an **alert** (`n`) → `i` to open a runbook-primed agent-shell
     session that triages it (respecting the pre-comment gate), or `x` to run it
     in the background.
   - Pick up a **DoS task** the same way; `c` first if you want to see/copy the
     exact command.
4. **Slice when needed.** `C-c A D` — filter (`/`) by user, category, or service
   to reconcile the full board, or draft the daily log with `R`.
5. **Export the audit.** Back on the board, `W` writes today's worksheet (seeded
   with live counts) and opens it in Emacs — review it and paste the entry into
   the weekly report (`r` opens the report). The report is an *export surface*
   for the day's work, kept current as you go.
6. **Parity outside Emacs.** The same engine runs in a plain terminal for
   teammates who don't use Emacs — see *From the terminal* below.

## From the terminal (CLI parity)

Every board action is delegated to a CLI, so the whole flow is available without
Emacs. Two CLIs are relevant:

- **The org priority engine** (org-provided; NurtureCloud ships `nc-dos`):
  `nc-dos-sidebar` is the single-key priority console the board renders,
  `nc-dos-sidebar --once` prints the panel, `--json` feeds the board, and
  `nc-dos-worksheet` exports the day's worksheet. See your org config's
  *TechOps On-Support* page for the full command set.
- **[`decknix session`](../../../cli/core-commands.md#decknix-session)** — the
  framework's workspace- and tag-aware session CLI. The agents the board spawns
  on a ticket land as ordinary sessions, so you can list, resume, tag, or start
  them from the terminal and they stay in sync with the sidebar:

  ```bash
  # Resume the latest session you spawned on a DoS item (by tag)
  decknix session resume --tag dos

  # Start a session on a ticket, seeded and pre-tagged
  decknix session new --tag dos -- "Investigate ALR-5752"

  # List Claude sessions touched today, as JSON
  decknix session list --agent claude --since 1d --json
  ```

## How it fits together

There is one engine and several faces. The engine (org-provided) reads the
tracker, computes the runbook priority order, and owns every write (agent
spawns, tab opens, tick state). The board and dashboard *render* that model and
*delegate* actions back to it, so the Emacs and terminal experiences never drift
apart and no runbook logic is duplicated in Elisp.
