# Agent Service Supervisor — Tier 3 prototype (issue #151)

Scoping for decoupling agent (ACP bridge) lifetime from the Emacs process, so
agents run as managed services Emacs *attaches to* rather than *owns*. This is
Tier 3 of #151 ("the real fix"); Tier 1 (terminal resume) has shipped.

## Why (motivation + evidence)

Agents already run their compute in a separate OS process (the ACP bridge /
`claude` subprocess). But those processes are **children of the Emacs daemon**,
and all per-agent *presentation* runs on Emacs' single thread. Profiling under
~24 live agents (see #151 comment, 2026-07-24) showed the sidebar paint at
5.8 s before memoization stopgaps brought it to 74 ms. Those stopgaps cache the
repeated per-agent work, but the paint is still **O(all agents)** and the
agents still **die with Emacs** (a `decknix switch` or crash drops them).

Target: paint/attention cost **O(viewed sessions)**, agents survive Emacs
death, and sessions are monitorable/reattachable from outside Emacs.

## Key feasibility finding

`acp-make-client` (upstream `acp.el`) **requires `:command`** and spawns it via
`make-process`; it has no socket/network transport. Rather than patch acp.el,
point `:command` at an **attach client** for a detached supervisor:

- Launch the bridge detached, stdio multiplexed on a socket:
  `dtach -n <sock> claude-agent-acp …`  (or `abduco -n <name> …`)
- Emacs ACP client spawns the *attach*:
  `:command "dtach" :command-params ("-a" "<sock>")`
  dtach forwards the live bridge's stdio to Emacs; acp speaks JSON-RPC over it
  as if it had spawned the bridge directly. **No acp.el change required.**

`dtach -n` daemonises the bridge OUT of Emacs' process tree, so Emacs death
leaves it running; a fresh `dtach -a` reattaches.

## Architecture

```
              ~/.config/decknix/agent-sockets/<sid>.sock   (registry dir)
                         │
   ┌─────────────────────┴─────────────────────┐
   │  supervisor (dtach -n / abduco / launchd)  │   ← survives Emacs
   │    claude-agent-acp  ⇄  claude (model)     │
   └─────────────────────┬─────────────────────┘
                         │ stdio over socket
        ┌────────────────┴───────────────┐
        │  dtach -a <sock>  (attach shim) │   ← spawned by acp-make-client
        └────────────────┬───────────────┘
                         │ JSON-RPC (ACP)
                  agent-shell buffer (Emacs)   ← attach only when VIEWED
```

A session registry (one small file per session under
`~/.config/decknix/agent-sockets/`: socket path, sid, workspace, provider,
mode, pid, created/last-activity) is the cheap, file-based source of truth the
sidebar/board list from — and a `decknix` CLI can list/monitor/kill sessions
without Emacs.

## Prototype milestones (Claude only first)

- **M1 — Spike detach/reattach.** `dtach -n` a `claude-agent-acp`; drive it with
  a raw JSON-RPC client (or `acp-traffic`); detach; reattach; confirm the ACP
  session is intact and a turn started before detach can be observed after.
  Decide `dtach` vs `abduco` (abduco is cleaner programmatically; both fine).
- **M2 — Emacs attach transport.** Register a Claude provider variant whose
  `:acp-command` is the `dtach -a <sock>` attach, and a launcher that `dtach -n`
  the bridge + writes the registry file. Open/close the buffer = attach/detach;
  the bridge keeps running.
- **M3 — Registry + lazy-attach.** Sidebar/board list sessions from the registry
  (no live connection); attach the ACP client only when a session is opened.
  Non-attached rows get status from the registry + transcript, not a socket.
- **M4 — Survive `decknix switch` / Emacs restart.** On startup, scan the
  registry, prune dead sockets, and offer reattach. Wire into the existing
  terminal-resume UI (Tier 1) as the "reattach" action.

## Open questions / risks

1. **Client detach mid-turn.** dtach preserves the process, but does
   `claude-agent-acp` tolerate a client vanishing and a new one attaching
   mid-stream? Buffered output on reattach may need a re-sync or an ACP
   `session/resume`. Verify in M1; if the bridge assumes a single stable
   client, the supervisor may need to be a small ACP-aware broker instead of
   raw dtach (holds the bridge connection, multiplexes clients, replays state).
2. **Permission prompts while detached.** A detached session that hits a
   permission request has no UI to answer it and will block. Mitigation: run
   detached sessions in a non-prompting posture (the `auto`/`bypassPermissions`
   work already in place) or have the broker queue/deny per policy. Ties to the
   session-mode layer.
3. **dtach vs broker.** Raw dtach is the cheapest prototype; a purpose-built
   ACP broker (Rust, sibling of the hub daemon) is the robust end-state —
   holds bridges, exposes a socket API, emits state to the registry for #150.
   Prototype with dtach; graduate to a broker if (1) forces it.
4. **Ordering vs the hub daemon.** The registry + state emission overlaps #150
   (derived session state) and #97 (services sidebar). The broker, if built,
   is the natural producer of the `(state, attention, last-activity)` signal.

## Relates

- #151 (this, Tier 3) · #150 (state signal — registry/broker produces it) ·
  #97 (services sidebar surfaces supervised agents) · #143 (ACP resume) ·
  #68 (orchestration epic) · #84 (modular architecture).
