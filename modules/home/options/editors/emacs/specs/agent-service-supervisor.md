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
- **M2 — Minimal broker. DONE (Rust, validated 2026-07-30).**
  `pkgs/decknix-agent-broker/` (sibling of `decknix-hub`): a tokio process that
  spawns the bridge once and holds its stdin/stdout on **pipes**; listens on a
  unix socket; relays client⇄bridge; **always drains** bridge stdout to a log +
  the attached client, so the bridge never blocks and — the key property — only
  ever sees ONE stable peer (the broker). Client attach/detach is invisible to
  the bridge, so **"does the bridge tolerate a vanishing client mid-turn" is
  moot**. One client at a time (a new attach replaces the old); socket cleaned on
  exit / SIGINT / SIGTERM.
  Validation (mock stateful bridge + `socat - UNIX-CONNECT`): client connects →
  gets `reply:1` → disconnects; the bridge child **survives** (same pid); a
  second client **reconnects** → gets `reply:2` — proving the bridge kept its
  in-process state across disconnect/reconnect, over **clean pipe stdio** (no
  pty mangling). This is exactly what dtach/abduco could not do.
  Decision applied (reattach = cheap): the broker does NOT buffer/replay; a
  reattached client gets the LIVE stream only. Reviewing what streamed while
  detached is a separate "walk history" command over the transcript — so no ACP
  `session/resume` is needed in the broker itself.
  **REVISED 2026-08-04** (see "Reattach replay" below): live testing showed the
  no-replay UX is inadequate. On reattach to a mid-turn session the buffer shows
  the prompt and then nothing until the turn resolves — the in-flight stream that
  arrived while detached is lost to the client (it is only in the log +
  transcript). `session/load` restores *committed* turns; the *uncommitted
  in-flight* turn's already-streamed output is the gap. The target UX is:
  reattach rebuilds prior history + the detached-interval output + continues
  live. This does not undo the M2 property (bridge survival is orthogonal); it
  adds a rehydrate step on the read side.
- **M3 — Attach transport + daemonisation. DONE (validated 2026-07-31).**
  A transparent spawn-or-attach wrapper `decknix-agent-broker-attach KEY --
  <bridge-cmd>` that acp.el points its `:command' at: it `pgrep'/pidfile-checks
  whether a broker is holding `KEY''s socket, spawns one (with the real bridge)
  if not, and `exec socat - UNIX-CONNECT:<sock>' either way — so the FIRST attach
  starts the broker and every reconnect just re-attaches; no acp.el change.
  Because macOS ships no `setsid' binary, the broker itself gained
  `--daemonize' (fork + setsid + fork) so it reparents to pid 1, out of Emacs'
  process tree; it writes `<socket>.pid' (liveness) + a per-session registry
  JSON, both cleaned on exit.
  Validation (wrapper + daemonised broker + mock bridge): attach → `reply:1`;
  the attach (socat) exits (== Emacs closing the buffer / dying); the broker
  **survives with ppid=1**; reattach → `reply:2` (state kept across "Emacs
  death"). Packaged: broker + `socat` + the wrapper on PATH (inert until a
  session opts in).
- **M3b — Emacs opt-in + live validation. DONE (validated 2026-08-04).**
  Wrap `decknix--agent-command-build` with the wrapper when brokering is enabled,
  using a stable per-session broker KEY (generated at launch, persisted to
  conversation metadata at the sid↔conv link, reused on resume). `broker.enable`
  toggle (default off). Live-tested against a real `claude-agent-acp`:
  - Spawn: wrapper spawns the daemonised broker (ppid=1), the real bridge is the
    broker's child, `initialize` round-trips, registry/pidfile/log written.
  - Reattach: killing the buffer drops the client; the broker + bridge **survive**
    on the same pids; resume reattaches the SAME broker (no respawn). The real
    bridge tolerates the reconnect handshake — a second `initialize` (id:1) + a
    `session/load` (id:2) restoring the session's modes, no errors — so **risk 1
    is retired**: a vanishing/new client mid-session is handled.
  - Background turn-survival: a tool call started before detach (a shell
    `sleep`-loop) **kept running in the background** across the detach, parented
    to the broker, no client attached; the completion later reached the
    reattached client cleanly (a `stopReason` for a prompt the *killed* client
    had sent still rendered).
  - Bug found + fixed (commit `71af5eb`): the conv-key hash did not normalise
    trailing whitespace, so the live write path (`comint` input `"hello\n"`) and
    the transcript-read path (`"hello"`) produced different keys — on resume the
    lookup missed and the session lost its tags + brokerKey (spawning a fresh
    broker instead of reattaching). `decknix--agent-conversation-key-raw' now
    `string-trim's before hashing.
  - Gap surfaced (drives "Reattach replay" below): the reattached buffer does not
    show the in-flight turn's already-streamed output — a red herring compounded
    the demo (the model ran the count as a *foreground* shell loop that hit
    Claude's own ~3m30s Bash-tool timeout at 188, then recovered 189–200; that
    timeout is a tool/model artifact, not a broker fault).
- **M4 — Registry + lazy-attach.** Sidebar/board list sessions from the registry
  (no live connection); attach the ACP client only when a session is opened.
  Non-attached rows get status from the registry + transcript, not a socket.
- **M5 — Survive `decknix switch` / Emacs restart.** On startup, scan the
  registry, prune dead sockets, and offer reattach. Wire into the existing
  terminal-resume UI (Tier 1) as the "reattach" action. The broker is also the
  natural producer of the `(state, attention, last-activity)` signal for #150.
- **M6 — Reattach replay (rehydrate).** Turn reattach from "reopen and see the
  aftermath" into "reattach and watch it finish." See design below.

## Progress — 2026-08-07 (dogfooding + follow-ups)

Brokering ran in real daily use for ~2 days (9 concurrent live brokers spanning
Aug 4-6) — strong evidence the transport is solid, de-risking default-on.

- **M6 wiring landed (commit 202e1f5).** The rehydrate module (5eeb986) is now
  called from the resume timer after `decknix--agent-session-prepopulate`, gated
  on a LIVE broker (`decknix--agent-broker-live-p`, pidfile) and per-notification
  `ignore-errors`. Parser is ERT-tested; the live render path + live-vs-replay
  ordering still need an interactive streaming test (a backgrounded shell command
  ends its ACP turn immediately, so it is NOT a valid M6 test — use a streaming
  text turn detached mid-generation).
- **Switch-breaking bug fixed (commit c41ce6f).** The broker put its
  sockets/logs under `~/.config/decknix/agent-sockets` — inside the system
  flake's own (non-git) source tree — so `nix` aborted every `decknix switch`
  with "file … .sock has an unsupported type" whenever a session was live.
  Relocated the runtime dir to `${XDG_STATE_HOME:-~/.local/state}/decknix/
  agent-sockets` (wrapper + elisp in lockstep). One-time migration: clear the old
  dir before the first switch that carries the fix. Full build verified green
  from a socket-free flake copy.
- **IO overhead measured.** Broker vs direct pipe: +~0.7ms per round-trip; one-way
  throughput 53 MB/s vs 293 MB/s (5.5× lower but still ample for KB-scale ACP
  traffic; a 100 KB response relays in ~2 ms). All overhead is on the broker's
  core, off Emacs' main thread. Verdict: IO lag is a non-issue for real traffic.
- **Output coalescing built, default-OFF (commit e74a5a0).** `--coalesce-ms N`
  buffers bridge→client output and flushes every N ms (or 32 KiB) so the client
  wakes less often → fewer Emacs process-filter/redisplay cycles under heavy
  streaming. This is the responsiveness lever: brokering itself is resilience,
  NOT a responsiveness win (Emacs still parses/renders every update on its main
  thread regardless of transport); coalescing is what reduces that main-thread
  churn. Default 0 = the byte-identical immediate relay; not yet plumbed through
  the wrapper — enable + validate before making it live.

Remaining before broker-default (`broker.enable = true`): confirm M6 replay
interactively, then flip the default (deploys atomically with the socket
relocation, so there is no old-location window), then plumb + tune coalescing.

## Reattach replay — rehydrate on attach (revises M2 no-replay)

Target UX (user, 2026-08-04): reattaching to a live session opens a buffer that
shows (1) the prior session history, PLUS (2) every message that would have
streamed had the client been attached the whole time (the detached interval),
PLUS (3) continuous live streaming if the agent is still working — seamlessly,
as if never detached.

What already covers what:
- (1) prior COMPLETED turns → `session/load` replays them from the bridge's
  persisted transcript. Works today.
- (2) turns that COMPLETED while detached → also committed, so also via
  `session/load`. Works today.
- The gap is the (2)/(3) seam: the UNCOMMITTED in-flight turn's already-streamed
  output. It is not in the transcript (mid-turn) and the broker does not replay
  it, so a client that reattaches mid-turn sees the prompt, then silence, then
  the resolved result — never the progress.

Source of truth: the broker's raw ACP log (`<key>.log`) already contains EVERY
bridge→client byte since the broker spawned — including the original
`session/load` replay done at broker-creation and the current in-flight turn's
partial stream. It is a complete record of "what a continuously-attached client
would have received." So the DATA already exists; only replay + render is
missing. No new capture is needed.

Two candidate architectures:

- **A — Editor rehydrate from the log (broker stays dumb).** On reattach to a
  live broker, the editor replays `<key>.log`'s `session/update` notifications
  through the normal agent-shell render path to rebuild the buffer, then goes
  live. Pro: zero broker change; reuses the live renderer; full fidelity.
  Con: the editor must reconcile log-replay with acp.el's own reconnect
  (`initialize` + `session/load`), or double-render. Cleanest variant: on
  live-reattach, perform `initialize`+`session/load` for PROTOCOL only (to obtain
  the sessionId + a client able to send new prompts) but SUPPRESS rendering of
  `session/load`'s replayed history, rendering the buffer solely from the log
  replay; then stream live.

- **B — Broker replays the in-flight tail (broker turn-aware).** The broker
  line-frames the newline-JSON stream, tracks the last turn boundary (a `result`
  carrying `stopReason`), and keeps a bounded buffer of bytes since it. On
  attach it lets the client `session/load` (committed history), then replays the
  in-flight buffer, then live. Clean boundary (session/load = committed; broker =
  the single uncommitted turn; no overlap). Con: ORDERING — the broker must
  replay AFTER the client's session/load has rendered, but it does not parse
  client→bridge to know when that finished; replaying too early inverts the
  visual order.

Recommendation: **A** (editor rehydrate, suppress session/load render). It keeps
the broker a dumb relay, puts rendering where rendering already lives, and sizes
replay by reading a bounded tail of the log rather than teaching the broker ACP
framing. Revisit B only if the log-vs-socket handoff proves unreliable.

Hard problems to solve in M6:
- **Handoff without gap or dup.** Attach the socket first (so no live byte is
  missed), snapshot the log offset, render the log up to it, then flush the
  live bytes buffered since attach — with a boundary marker so the last logged
  bytes are not rendered twice.
- **Dedup vs `session/load`.** A "suppress-history-render until caught up" flag,
  so the protocol handshake does not double-paint what the log replay drew.
- **Bounded replay.** Do not re-render gigabytes on every attach; cap to the
  last N turns / N MB (checkpoint at turn boundaries), and `log()` when truncated.
- **Idempotent rendering.** Replaying logged `session/update` must yield the same
  buffer as live (tool-call blocks, message chunks, usage) — the renderer must
  not assume first-time-live invariants.
- **Pending permission requests (risk 2).** A `session/request_permission` that
  arrived while detached must rehydrate as an ACTIONABLE prompt, not historical
  text, so the user can answer it on reattach.

Acceptance test (the M3b demo, with the M6 outcome): start a long streaming
turn, detach mid-turn, reattach → the buffer shows the prompt AND the output
produced while detached AND continues streaming to completion; a permission
request raised while detached is answerable on reattach.

## Open questions / risks

1. **Client detach mid-turn. RESOLVED (M3b, 2026-08-04).** `claude-agent-acp`
   tolerates a client vanishing and a new one attaching mid-stream: the broker's
   always-one-peer design means the bridge never sees the change, the reconnect
   `initialize`+`session/load` handshake succeeds, and a tool call started before
   detach keeps running and completes into the reattached client. What remains is
   not tolerance but UX — rehydrating the in-flight stream on reattach (M6,
   "Reattach replay"), not an ACP `session/resume`.
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
