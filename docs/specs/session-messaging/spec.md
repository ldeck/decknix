# Session messaging: lane state, durable delivery, interrupts and lane lifecycle

Status: implemented on `main` (local, not yet switched). Decisions marked **(user decision)** in section 8 ship with the defaults stated there.

## 1. Problem

A coordinator agent session drives several lane sessions. It hands work to a lane with the explicit-approval dispatcher (`decknix-agent-dispatch send`, receiver `agent-shell/dispatch/decknix-agent-dispatch.el`): a request file in a private directory, delivered at most once when the lane is idle, expiring after at most 900 s.

Three weeks of receipts (`~/.local/state/decknix/agent-dispatch/receipts/`, 1089 requests) contain 89 `expired` and 21 `rejected unsent-input`. Over a third of the expiries came from one coordinator. Typical incidents, reconstructed from the coordinator and lane transcripts plus the lane's broker log:

1. **A lane that looked busy for 75 minutes was doing nothing.** At 00:33 UTC a lane accepted a coordinator message, launched a background sub-agent and wrote its closing text at 00:34. The broker log shows no `stopReason` for that prompt until 01:48, when the human cancelled it: the agent's prompt stays open while a background task it started is running, so `shell-maker--busy` stayed set. Two coordinator messages sent at 01:06 and 01:27 (TTL 900 s) both expired `expired-before-send`. The coordinator told the human the lane had "been busy for more than 15 minutes at a stretch"; it could not see that the lane's model had been silent for over half an hour. The human then cancelled the turn and pasted the message by hand.
2. **Lost context from expired messages.** A lane missed three consecutive briefs (03:35, 04:18, 04:34 UTC; all `expired-before-send`, the lane again holding an open turn while background tasks ran). The fourth brief was delivered and referred to a task from an expired one; the lane replied that it had no such task.
3. **Misread refusals.** A brief was refused `unsent-input` (the human had typed at the lane's prompt). The coordinator told the human the lane "can't receive messages" and a minute later had to correct itself.
4. **Hand-rolled polling.** The coordinator wrote its own watch loops (`status` every 15 s, up to 30 minutes) and resent expired messages, creating duplicates of the same brief.

Root cause: the dispatcher's only signal is a single busy bit, the coordinator cannot read even that, and the maximum lifetime (900 s) is shorter than an ordinary lane turn. "Busy" conflates a model producing output, a long tool call, and an open prompt waiting on background work.

## 2. Goals

- (a) **Observability.** Any agent can ask, through a shell command, what a lane is doing: state, busy since, last activity, current tool, closing text, queue depth, last delivered message. Answered from files, without Emacs.
- (b) **Delivery semantics.** Durable idle delivery with a long TTL, an immediate `now` probe, and an explicit, policed `interrupt`. Every message has an id and a receipt chain; nothing expires silently.
- (c) **Guidance.** Coordinators check state first, prefer idle delivery, interrupt only with a reason, and watch receipts instead of sleeping.

Non-goals: injecting a prompt into an open turn (section 9), any network transport, any change to how a human uses a session.

## 3. Lane state export

Emacs writes one JSON file per live agent-shell session plus a heartbeat (module `agent-shell/session-export/`, `decknix-agent-session-export-mode`, on by default because it only writes local files and sends nothing):

```
$XDG_STATE_HOME/decknix/sessions/        (default ~/.local/state, dir 0700, files 0600)
  _emacs.json     {"v":1,"pid":…,"at":<epoch>,"interval":30,"receiver":true|false,
                   "armed_at":<epoch>|null,"armed_by":"human"|"control:<id>"|null,
                   "control":true|false,"remote_control":true|false}
  <session>.json  one per live session
```

Session file fields: `v`, `id`, `buffer`, `agent`, `cwd`, `emacs_pid`, `state`, `status` (raw sidebar status), `busy`, `busy_since`, `state_since`, `last_activity` (rounded down to 15 s), `tool` (`name`, `since`) or null, `tools_in_flight`, `tail` (closing or streaming text, last 300 characters), `queued` (`compose`, `dispatch`), `last_delivered` (`id`, `at`, `from`) or null.

States:

```
working             a turn is open and output or a tool call is in flight
background          a turn is open, no tool in flight, no output for 120 s
                    (waiting on a background task it started)
waiting-permission  blocked on a permission prompt
asking              turn ended on a question for the human
idle                no turn open
netfail             the last turn died on a network failure
starting            the session is initialising
dead                the process is gone
```

Cost rules (Emacs AGENTS.md, periodic writes): the notification observer only stores a timestamp and, for tool calls, updates a small in-flight table. A self-pacing sweep (default every 5 s, longer when a sweep was slow) builds each snapshot and writes it through `decknix-hub-cache-write-string`, so an unchanged session never touches the disk. The heartbeat is rewritten every 30 s.

Staleness: the CLI reports `stale: true` when the heartbeat is older than three intervals, the heartbeat's pid is not running, or a session file's `emacs_pid` differs from the heartbeat's. A stale file is never reported as live state.

## 4. CLI

All under `decknix session` (Rust, `cli/src/session_msg.rs`):

```
status <target> [--json]                     one session's state
list --live [--json]                         every exported session
send <target> (--message T | --message-file F | --stdin)
     [--when idle|now|interrupt] [--ttl 24h] [--from ID] [--reason TEXT]
     [--notify] [--wait-receipt SECS]
message <id> [--json]                        receipt chain for one message
watch <id>... [--until delivered|answered] [--timeout 2h]
inbox [--session ID] [--json] [--clear]      notices pushed to the sender
spawn --workspace DIR --tag a,b [--agent claude] [--name N] [--model M]
      [--mode MODE] (--brief-file F | --stdin | -- <brief>) [--queue]
      [--no-resume] [--wait 180] [--ttl 1h] [--from ID] [--json]
retire <target> [--reason T] [--force] [--wait 60] [--json]
dispatch status [--json] | dispatch on [--release-queued] [--wait 15]
                         | dispatch off [--wait 15]
```

Lifecycle and receiver control are section 10 (`cli/src/session_lifecycle.rs`).

`<target>` is anything `decknix session find` accepts (full id, unique id prefix of 6+ characters, buffer name or its tag path, workspace path, or tags matched exactly, case-insensitively or normalised) that resolves to exactly one live session; see `cli/src/session_lookup.rs`. Anything ambiguous is an error that lists the candidates (exit 21), a miss lists the closest sessions (exit 20), and a saved-only match exits 22. The request file always names the full id, so the receiver's exact-identity rule is unchanged.

`--from` defaults to `$DECKNIX_SESSION_ID`, then `$CLAUDE_CODE_SESSION_ID`, when it is a full UUID. Tags come from `~/.config/decknix/agent-sessions.json`.

## 5. Delivery semantics

Requests are version 2 of the dispatcher's request file (`v: 2`), adding `when`, `from`, `from_name`, `reason`, `notify`. Version 1 requests from `decknix-agent-dispatch send` behave exactly as before.

- **idle** (default). Waits while the lane is busy or has unsent typed input, delivers at the next idle point. TTL default 24 h, maximum 7 days. On expiry the receipt is `expired` and, with `--notify`, the sender gets a notice.
- **now**. The CLI reads the lane's state file first. If the lane is not idle (or its state is stale) nothing is written; the command prints the state and exits 13. Otherwise it writes a request with a 60 s TTL that the receiver refuses (`busy`) rather than waits on if the lane turned busy meanwhile.
- **interrupt**. Requires `--reason`. If the lane is idle it is delivered like `now`. If busy, the receiver checks the interrupt policy (section 6), cancels the turn through `agent-shell-interrupt` (the same call compose's interrupt-and-submit uses), waits for the turn to settle and submits. If the cancel is not acknowledged the message stays queued until its TTL; it is never dropped. Unsent typed input always refuses an interrupt: a human at the prompt outranks a coordinator.

Every version 2 prompt is delivered with a one-line envelope so the lane's transcript, and the human reading it, shows who sent it:

```
[decknix message 1a2b3c4d from coordinator-buffer]
[decknix message 1a2b3c4d from coordinator-buffer; interrupted your turn: <reason>]
```

### Receipts

```
queued     pending/<id>.json exists (the CLI computes `expired` once past expires_at)
waiting    claimed by the receiver, lane busy or interrupt in progress
delivered  receipts/<id>.json state=accepted
answered   receipts/<id>.answered.json: the lane's turn ended, or went to
           `background`, after delivery; carries the closing text tail
rejected | expired | not-sent | unknown | cancelled   terminal, with a reason
```

`decknix session message <id>` merges these. Exit codes: 0 delivered or answered, 10 queued or waiting, 11 not delivered, 12 unknown, 2 no such message.

With `--notify` (and a `from`), the receiver writes a notice to `agent-dispatch/notices/<from>/` on delivered, answered and every terminal state. `decknix session inbox` lists them; `--clear` removes the listed ones. `decknix session watch` blocks (meant for a background shell) until each id reaches the requested state or a terminal one, so an agent gets one completion event instead of polling.

## 6. Interrupt policy and loop prevention

The dispatcher's guarantee is unchanged: nothing is delivered unless the human turned on `decknix-agent-dispatch-mode` in this Emacs run, and requests created before arming are refused. On top of that, an interrupt needs the policy `decknix-agent-dispatch-interrupt-policy`:

```
never        interrupts are always refused
opt-in       only lanes tagged with one of decknix-agent-dispatch-interruptible-tags
coordinator  (default) senders tagged with one of decknix-agent-dispatch-coordinator-tags,
             or lanes that opted in as above
always       any sender
```

Always refused: a session interrupting itself; a lane interrupted less than `decknix-agent-dispatch-interrupt-min-interval` (300 s) ago (`interrupt-rate-limited`); a sender that the lane itself interrupted within that interval (`interrupt-loop`), so two sessions cannot ping-pong. Refusals are receipts, never a silent fallback to idle.

## 7. Verification

- Rust unit tests: target resolution, staleness, state rendering, request format and modes, `now` against a busy lane writes nothing, interrupt requires a reason, receipt merging including lazy expiry, notices.
- ERT: export snapshot and state mapping, change-only writes, activity and tool tracking; dispatcher v2 validation, idle waiting on unsent input, `now` refusing a busy lane, interrupt policy, rate limit and loop guard, envelope, answered receipts and notices. Version 1 tests are unchanged except the version table.
- Rust unit tests for section 10: request builders and validation, the idempotent `existing` plan writing nothing, ambiguous live and saved matches (21), saved resume and workspace mismatch (23), the receiver gate (14, 15, `--queue`), retire exactness, `dispatch on|off` no-ops and the missing watcher (16), spawned receipt merging.
- ERT for section 10: the v3 validation table, policy, roots, cap and rate refusals, `existing` and ambiguous outcomes, the spawned receipt, timeout and buffer death, a resumed session's brief, predates-arming against `release_queued`, retire refusals (protected, unsent, busy, force, session changed); control on/off, remote control disabled, unsafe and expired requests; heartbeat arming fields; background resume taking no window. Every real session entry point is stubbed to error.
- Full system build in the pre-commit gate.

## 8. Decisions

- **(user decision)** Interrupt policy default `coordinator`, coordinator tag `coordinator`, interruptible tag `interruptible`, minimum interval 300 s.
- **(user decision, revised for section 10)** The dispatch receiver stays off on install and at startup; the exporter is on by default. Originally only the human could arm it. It can now also be armed by a `dispatch on` control request, through the separately enabled control watcher, so a coordinator that finds `receiver: false` asks the human in one line and, only after a yes, runs `decknix session dispatch on` itself. `send` still refuses (exit 14) rather than queue a request that arming would refuse. The receiver is still never armed automatically: control requests created before the watcher started are refused and live at most 300 s, so nothing queued while Emacs was down can arm it, and the "requests from before arming are refused" protection is kept except for spawns queued with `--queue` and released explicitly with `--release-queued`.
- **(user decision)** Lifecycle policy default `coordinator` (the sender must carry a coordinator tag), spawn roots `~/Code` and `~/tools`, at most 12 live sessions, 10 s between spawns, protected tag `coordinator`. The control watcher runs by default (Nix option `programs.emacs.decknix.agentShell.dispatch.remoteControl.enable`); `decknix-agent-dispatch-remote-control` set to nil refuses remote `on` while still honouring `off`.
- Background threshold 120 s and the 24 h idle TTL are variables (`decknix-agent-session-export-background-seconds`, CLI `--ttl`).
- Interrupt cancels the whole turn, including background tasks the lane started (the transcript in incident 1 shows the sub-agent "stopped by the user" when the turn was cancelled). `status` shows `background` so the coordinator can weigh that cost.

## 9. Follow-up (not built)

The agent bridge advertises `promptQueueing`: it accepts a new prompt while one is open and feeds it to the model at the next opportunity, the way a background agent's message reached the lane in incident 1. Using that for `background` lanes would deliver without cancelling anything, but shell-maker tracks one prompt per buffer and would need changes upstream. Until then, `background` plus `interrupt` is the coordinator's choice to make.

## 10. Lane lifecycle and receiver control

A coordinator that scales its lanes used to ask the human to open each session and later close it. Version 3 requests let it do both through the same private directory, with the receiver making the final checks against its own view of live sessions.

### Requests

```
v: 3, id, kind, created_at, expires_at, [from, from_name]
kind spawn     pending/   workspace, tags[], brief, brief_sha256,
                          [agent, name, model, mode, resume_session_id, queue]
kind retire    pending/   session_id, expect_tags[], [expect_buffer, reason, force]
kind dispatch  control/   op on|off, [release_queued]
```

Spawn and retire live at most 24 h (CLI defaults: spawn 1 h, retire 1 h); control requests 300 s (CLI 60 s). A `dispatch` request in pending/ is refused (`bad-kind`).

### Spawn

The CLI resolves first: one live session whose tags include every requested tag (exactly or ignoring case; a normalised match such as `lane-7` for `lane-07` does not count) is printed with outcome `existing` and no request is written; several live matches exit 21. Otherwise one saved match is resumed (exit 23 when its recorded workspace differs; several saved matches exit 21 unless `--no-resume`). With the receiver off it exits 14, with no fresh heartbeat 15, unless `--queue`.

The receiver then checks, in order: the lifecycle policy (`lifecycle-not-allowed`); the agent maps to a registered provider (`unknown-agent`; `decknix-agent-dispatch-agent-providers` maps the CLI and store names `claude`, `auggie` and `pi` to the provider ids `claude-code`, `auggie` and `pi`); the workspace is under `decknix-agent-dispatch-spawn-roots` (`workspace-not-allowed`) and exists (`no-workspace`); idempotency against live buffers (one match: outcome `existing`, no brief; several: `ambiguous-existing`; an accepted spawn for the same tags not yet confirmed: `spawn-in-progress`); the live-session cap (`too-many-sessions`) and the spawn interval (`spawn-rate-limited`). It then writes `receipts/<id>.json` (`accepted`, `kind: spawn`, `outcome: new|resumed|existing`) and starts the session in the background through the spawn throttle: a new one via the quick-action path with the brief as its first message, or the saved one via a background resume, whose brief is submitted once the resumed session has stayed idle for 4 s. The brief is prefixed with `[decknix spawn <id> from <sender>]`.

`receipts/<id>.spawned.json` follows once the buffer has a session id: `{session_id, buffer, outcome}` (a resume adds `brief: delivered|not-delivered`), or `{state: spawn-failed, reason}` after 180 s without an id, when the buffer dies, or when the start fails. Disarming the receiver settles unconfirmed spawns `{state: unknown, reason: disarmed-before-confirmation}`. A spawn queued with `--queue` before the receiver was armed is released only when the arming control request carried `release_queued`; any other request created before arming is still refused.

`decknix session message` reads a spawn as `launching` (exit 10) until the spawned file arrives, then `spawned` (0) or `spawn-failed` (11).

### Retire

The CLI needs exactly one live session named by full id, buffer name or tags at the exact or case-insensitive tier; an id prefix, a workspace or a normalised match exits 21 ("retire needs an exact target"). Retiring the calling session needs `--force`. The request carries the session's current tags and buffer name.

The receiver refuses: policy (`lifecycle-not-allowed`); a self-retire without force (`retire-self-needs-force`); no or several buffers (`no-session`, `ambiguous-session`); tags no longer including `expect_tags`, a different buffer name or a swapped buffer (`session-changed`); a tag in `decknix-agent-dispatch-retire-protected-tags` (`protected-session`); text typed at the prompt, even with force (`unsent-input`). A busy session is waited on until idle or expiry (`expired-before-retire`) unless `force`. Then it quits the session through `decknix-session-lifecycle-quit` (broker stopped, buffer killed) and records `accepted` with `outcome: retired` only when the buffer is really gone, otherwise `unknown`. The saved record stays, so a later spawn with the same tags resumes it. `message` reads it as `retired`.

### Receiver control

`decknix-agent-dispatch-control-mode` (package `agent-shell/dispatch-control/`) checks control/ every 5 s (one directory stat when nothing changed) plus file-notify, claims a request by renaming it to `<id>.claimed`, applies the receiver's file checks (UUID name, 0600, owner, no symlink, size), and writes `receipts/<id>.json` with `kind: dispatch`. `op on` arms the receiver with `armed_by: control:<from>` (refused `remote-control-disabled` while `decknix-agent-dispatch-remote-control` is nil); `op off` disarms it, always. Requests created before the watcher started are refused (`predates-control`). The heartbeat is rewritten as soon as the receiver or the watcher toggles.

`decknix session dispatch status` exits 0 when the receiver is on, 14 when off, 15 with no fresh heartbeat, and shows who armed it, whether the watcher runs, and request counts. `on` and `off` are no-ops (exit 0) when already in that state, exit 16 when the heartbeat shows no control watcher (only `M-x decknix-agent-dispatch-mode` can switch it then), and otherwise publish to control/, wait for the receipt and re-read the heartbeat. `off` first lists in-flight requests, which disarming settles `not-sent` (`disarmed`). The receipt reads `applied`.

Agents must ask the human before `dispatch on` and say when they turn it off; that rule lives in the session-messaging skill, since the CLI cannot tell who typed the command.
