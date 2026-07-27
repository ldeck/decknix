# TechOps living environment — the runnable playbook

Turn the TechOps Developer-on-Support (DoS) playbook from a static Confluence
page you *read* into a living environment you *run*: magit-like single-key
actions, a constant-attention board of what to prioritise next, AI-agnostic CLI
tooling the wider team can share, and (next) agents as managed background
services. The Weekly Techops Report becomes one **export surface** for the
audits, not the system of record.

> "turn the techops playbook from a static page to read into a living
> environment to run … magit-like single character actions, a sidebar bringing
> constant attention and monitoring to live activities that the DoS engineer
> should prioritise … lower the bar of entry." — the brief

## Design principles

1. **One engine, two faces.** The `nc-dos` CLI (decknix-config `pkgs/nc-dos.py`)
   is the single engine: it reads Jira/Confluence via the pre-authed
   `atlassian-cli`, computes the Playbook §6 priority order, and owns every
   write (agent spawns, tab opens, tick state). Emacs and the terminal are two
   faces over that one engine, kept in parity by consuming its `--json`. No
   logic is duplicated in Elisp.
2. **AI-agnostic + hexagonal.** Nothing is tied to Claude. Prompts/JQL live in
   the CLI; spawns dispatch to whatever agent is configured (claude/pi/gemini).
   The terminal face is the shareable analogue for teammates who don't use
   Emacs — contributable upstream.
3. **Deterministic, cheap to leave open.** The board and dashboard are LLM-free
   and refresh only while visible, so they can stay open all day without
   burning the rotation's attention or the machine's CPU.
4. **Obvious actions.** Every surface advertises its keys (`?` action menu,
   an Actions hint line, which-key). Lower the bar: land on the top item, act.

## What exists today (shipped, on `main`)

Emacs (decknix):

- `C-c A B` — **DoS priority board** (`decknix-dos-board`), the living playbook.
  Renders `nc-dos-sidebar --json` as ranked lanes (production incidents ->
  alerts -> DoS tasks) with single-key actions on the row at point: `RET` browse,
  `i` foreground agent (agent-shell, runbook-primed), `x` background `claude -p`
  agent (logged), `c` copy spawn commands, `r` open the Weekly Report, `W`
  export today's worksheet into Emacs, `n`/`p` move, `g` refresh, `?` menu. The
  header is the constant-attention surface: weekday, deploy/freeze posture,
  Report freshness, and live open-work counts.
- `C-c A D` — **support dashboard** (`decknix-support-dashboard`): grouped
  DoS-board + alert-feed view with filtering (status/category/user/service) and
  a `R` daily-log draft.
- `C-c A W` — **guided workflow** (`decknix-support-workflow`): the day-aware
  "what to do, when, how" checklist.

CLI / shared tooling (decknix-config, AI-agnostic):

- `nc-dos-sidebar` — interactive single-key priority console; `--once` renders
  once; `--json` feeds the emacs board; `--spawn-fg/-bg/--print-cmd/--json`
  are the key-addressable actions the board delegates to.
- `nc-dos-worksheet [DATE]` — writes a per-day Markdown support worksheet seeded
  with live counts (the audit export).
- `nc-open-service-dashboards`, `atlassian-cli`, `replay-dlq`, the `teamcity` /
  `techops-*` audit skills.

## Roadmap (keyed to existing issues)

Near-term, additive, demonstrable:

- **Filter + "my work" lanes on the board** — mirror board 757 (by owner /
  category / owning service). Extends the dashboard's existing filter model.
- **Alert triage lane depth** — surface the `ai-triaged` label + pre-comment
  gate state inline so the board *shows* eligibility, not just lists alerts.
- **Report auto-populate** — grow `W`/`R` from "seed a worksheet" toward
  writing the day's entry into the current Weekly Report page (Playbook §3.3).
  The report gap is how the rotation is measured; closing the export loop is the
  highest-value follow-up.

Architectural through-line (the "background services" half of the vision):

- **#151 session detachment / service supervisor** — agents as managed services
  Emacs *attaches to* (dtach/abduco attach shim; see
  `agent-service-supervisor.md`). The fix for "in-process agents hurt Emacs
  responsiveness"; unlocks tens of live agents.
- **#150 session-state + attention signals** — the single derived signal the
  board and sidebar both consume (the board linchpin).
- **#97 services sidebar section** — background service health as a first-class
  lane, so monitors/watchdogs (and #153 auth-expiry hardening) show up next to
  incidents.
- **#142 priority lane view / #101 alerts sidebar section** — fold the board's
  ranked lanes into the always-on sidebar so attention is constant, not on a
  keystroke.

## Demo script (5 minutes)

1. `C-c A B` — the board draws live: today's posture (deploy day / freeze),
   Report freshness, and the ranked lanes with real incidents/alerts/DoS.
2. Land on the top incident, `RET` — it opens in the browser. `?` — the action
   menu shows every key.
3. Move to an ai-able DoS item (`n`), press `x` — a background agent starts on
   it (logged), or `i` for a foreground agent-shell session, runbook-primed.
4. `W` — export today's worksheet (live counts) straight into Emacs; this is the
   day's audit, ready to review and paste into the Weekly Report (`r`).
5. Same engine in a plain terminal: `nc-dos-sidebar` — parity for teammates who
   don't use Emacs.
