# Session messaging

`decknix session status`, `send`, `message`, `watch` and `inbox` let one agent session (typically a coordinator driving several lane sessions) see what another live session is doing and hand it a message, without asking Emacs anything directly. Design and rationale: [`docs/specs/session-messaging/spec.md`](https://github.com/ldeck/decknix/blob/main/docs/specs/session-messaging/spec.md).

Two pieces run in Emacs:

- **State export** (`decknix-agent-session-export-mode`, on by default). Read-only: one small JSON file per live session plus a heartbeat in `~/.local/state/decknix/sessions/`, rewritten only when something changed.
- **Dispatch receiver** (`M-x decknix-agent-dispatch-mode`, off by default, see [Agent dispatch](./agent-dispatch.md)). Nothing is delivered unless you turn it on in this Emacs run.

## See what a session is doing

```bash
decknix session list --live
decknix session status lane-2          # id, id prefix, buffer name or a unique tag
decknix session status lane-2 --json
```

States:

```
working             a turn is open and producing output or running a tool
background          a turn is open, no tool in flight, no output for 2 minutes
                    (waiting on a background task it started)
waiting-permission  blocked on a permission prompt
asking              its turn ended on a question for you
idle                no turn open
netfail             the last turn died on a network failure
starting / dead     initialising / process gone
```

`status` also shows how long it has been busy, when it last produced output, the current tool, the closing text, queued prompts and the last message delivered to it. `stale` means the Emacs heartbeat is old or from another Emacs, so the state cannot be trusted. `receiver: OFF` means messages would not be delivered.

## Send

```bash
decknix session send lane-2 -m "Rebase on main, then rerun the suite" --notify
decknix session send lane-2 --message-file brief.md --when now
decknix session send lane-2 -m "Stop: the ticket was withdrawn" --when interrupt --reason "work is obsolete"
```

- `--when idle` (default): queued until the session's turn ends, including while you have text typed at its prompt. Lives 24 h by default (`--ttl`, up to 7 d).
- `--when now`: sent only if the session is idle (or asking); otherwise prints its state and exits 13 without queuing anything.
- `--when interrupt`: needs `--reason`. Cancels the running turn, then delivers. Refused if you have typed text at its prompt, if the interrupt policy does not allow it, or if the session was interrupted in the last 5 minutes. Cancelling also stops background tasks that turn started.

Every message reaches the session's transcript with a header naming the sender (and, after an interrupt, the reason). `send` prints the message id and refuses with exit 14 when the receiver is off or Emacs is not running, since such a request could never be delivered.

`--from` defaults to `$DECKNIX_SESSION_ID`, then `$CLAUDE_CODE_SESSION_ID`.

## Receipts

```bash
decknix session message <id>                  # queued | waiting | delivered | answered | rejected ...
decknix session watch <id> --until answered   # blocks; run it as a background command
decknix session inbox --clear                 # notices for messages sent with --notify
```

`answered` means the session's turn ended after the message (or went to `background`), and carries the closing text. Exit codes: 0 delivered or answered, 10 still pending, 11 not delivered, 12 unknown, 13 busy (`--when now`), 14 receiver off, 124 watch timed out.

## Interrupt policy

Set in Emacs:

```elisp
(setq decknix-agent-dispatch-interrupt-policy 'coordinator) ; never | opt-in | coordinator | always
(setq decknix-agent-dispatch-coordinator-tags '("coordinator"))
(setq decknix-agent-dispatch-interruptible-tags '("interruptible"))
(setq decknix-agent-dispatch-interrupt-min-interval 300)
```

Under the default `coordinator` policy, a sender whose session carries a coordinator tag may interrupt any session, and any sender may interrupt a session tagged `interruptible`. A session never interrupts itself, and a session it interrupted cannot interrupt it back within the interval.
