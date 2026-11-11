# Session messaging: lane state, durable delivery and interrupts

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
  _emacs.json     {"v":1,"pid":…,"at":<epoch>,"interval":30,"receiver":true|false}
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
```

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
- Full system build in the pre-commit gate.

## 8. Decisions

- **(user decision)** Interrupt policy default `coordinator`, coordinator tag `coordinator`, interruptible tag `interruptible`, minimum interval 300 s.
- **(user decision)** The dispatch receiver stays off until the human turns it on per Emacs run; the exporter is on by default. A coordinator that finds `receiver: false` in the heartbeat must ask the human; it cannot arm delivery itself, and `send` refuses (exit 14) rather than queue a request that arming would refuse. Auto-arming the receiver at startup would remove the "requests from before arming are refused" protection for anything queued while Emacs was down.
- Background threshold 120 s and the 24 h idle TTL are variables (`decknix-agent-session-export-background-seconds`, CLI `--ttl`).
- Interrupt cancels the whole turn, including background tasks the lane started (the transcript in incident 1 shows the sub-agent "stopped by the user" when the turn was cancelled). `status` shows `background` so the coordinator can weigh that cost.

## 9. Follow-up (not built)

The agent bridge advertises `promptQueueing`: it accepts a new prompt while one is open and feeds it to the model at the next opportunity, the way a background agent's message reached the lane in incident 1. Using that for `background` lanes would deliver without cancelling anything, but shell-maker tracks one prompt per buffer and would need changes upstream. Until then, `background` plus `interrupt` is the coordinator's choice to make.
