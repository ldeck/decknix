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

`acp-make-client` (upstream `acp.el`) **requires `:command`** and spawns it with
**`:connection-type 'pipe`** (verified: `acp.el` `make-process … :connection-type
'pipe`; stderr via `make-pipe-process`). It has no socket transport. So whatever
Emacs attaches to must be a **plain pipe** — no controlling terminal, no pty.

### M1 spike result (2026-07-30): dtach/abduco are the WRONG transport

The original plan — point `:command` at `dtach -a <sock>` — does **not** work,
and the reason rules out terminal multiplexers entirely:

- `dtach -a` **requires a controlling terminal** (`dtach: Attaching to a session
  requires a terminal.`) — it refuses to run under acp.el's pipe `make-process`.
- Both `dtach` and `abduco` run the child under a **pty**. A pty echoes input and
  does line-discipline translation, which would **corrupt newline-delimited
  JSON-RPC framing** even if the tty requirement were worked around.
- `dtach -n` *does* daemonise the child out of Emacs' tree (verified: the pid
  survives), so the *detach* half is fine — it's the *attach* transport that's
  unsuitable.

Conclusion: a pty-based multiplexer cannot be the attach transport for a
pipe-framed JSON-RPC bridge. The cheap-prototype path (raw dtach) is closed.

### Revised transport: a small pipe-clean broker

The bridge must be held by a **broker** that keeps its stdio on pipes and exposes
a **unix-domain socket**; Emacs attaches with a pipe-clean `:command` such as
`socat - UNIX-CONNECT:<sock>` (or `nc -U <sock>`) — clean bidirectional stdio, no
pty, still **no acp.el change**. Plain `socat UNIX-LISTEN … EXEC:bridge` is *not*
enough: `,fork` spawns a fresh bridge per client, and without it the bridge dies
when the client disconnects — neither gives "one persistent bridge, reattachable".
Holding one bridge and multiplexing attach/detach is exactly the broker from
open-question #3 below: the spike shows it is **required, not optional**.

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

Revised after the M1 spike: build the broker first (raw dtach is closed).

- **M1 — DONE (spike).** Result above: dtach/abduco unsuitable (tty + pty echo);
  acp.el is pipe-only; a pipe-clean broker is required.
- **M2 — Minimal broker.** A small long-lived process (prototype in Python or
  the hub's Rust; end-state = Rust sibling of the hub daemon) that: spawns
  `claude-agent-acp` once and holds its stdin/stdout on **pipes**; listens on a
  unix socket `~/.config/decknix/agent-sockets/<sid>.sock`; relays
  newline-delimited JSON-RPC between the current client and the bridge;
  **survives client disconnect** (keeps the bridge; on reattach, resyncs via ACP
  `session/resume` if needed — see risk 1). Verify: connect with
  `socat - UNIX-CONNECT:<sock>`, run an ACP `initialize`+turn, disconnect
  mid-turn, reconnect, confirm the session is intact.
- **M3 — Emacs attach transport.** Register a Claude provider variant whose
  `:acp-command` is `socat - UNIX-CONNECT:<sock>` (pipe-clean), plus a launcher
  that starts the broker + writes the registry file. Open/close the buffer =
  attach/detach; the bridge keeps running. Add `socat` (or use `nc -U`) to the
  package set **when this lands**, not before.
- **M4 — Registry + lazy-attach.** Sidebar/board list sessions from the registry
  (no live connection); attach the ACP client only when a session is opened.
  Non-attached rows get status from the registry + transcript, not a socket.
- **M5 — Survive `decknix switch` / Emacs restart.** On startup, scan the
  registry, prune dead sockets, and offer reattach. Wire into the existing
  terminal-resume UI (Tier 1) as the "reattach" action. The broker is also the
  natural producer of the `(state, attention, last-activity)` signal for #150.

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
