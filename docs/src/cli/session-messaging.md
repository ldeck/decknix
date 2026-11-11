# Session messaging

`decknix session status`, `send`, `message`, `watch` and `inbox` let one agent session (typically a coordinator driving several lane sessions) see what another live session is doing and hand it a message, without asking Emacs anything directly. Design and rationale: [`docs/specs/session-messaging/spec.md`](https://github.com/ldeck/decknix/blob/main/docs/specs/session-messaging/spec.md).

Two pieces run in Emacs:

- **State export** (`decknix-agent-session-export-mode`, on by default). Read-only: one small JSON file per live session plus a heartbeat in `~/.local/state/decknix/sessions/`, rewritten only when something changed.
- **Dispatch receiver** (`M-x decknix-agent-dispatch-mode`, off by default, see [Agent dispatch](./agent-dispatch.md)). Nothing is delivered unless you turn it on in this Emacs run.

## Find a session

```bash
decknix session find lane-04,PLAT-1342     # every match, live first
decknix session find lane-04 --id        # just the full id, or exit 21 if several match
decknix session find plat-1342 --all       # live and saved together
decknix session tags --live              # the tag vocabulary, with counts and sessions
```

Every command that names another session (`find`, `status`, `send`, `resume`, `tag`, and the `--tag` filters of `list`, `resume` and `archive`) uses one resolver. A query can be:

- a full session id, or a unique prefix of at least 6 hex characters;
- a buffer name, with or without the `*`, the agent prefix and a `<2>` suffix (`*Claude: lane-04/PLAT-1342*`, or just `lane-04/PLAT-1342`);
- a workspace path (`~/src/app`): sessions in it or below it;
- tags, all of which must match: `lane-04,PLAT-1342`, `lane-04/PLAT-1342`, `lane-04 PLAT-1342` or repeated `--tag`. A term matches a tag, a segment of the buffer name or a review PR (`repo#123`), exactly, else ignoring case, else ignoring `#`, quotes, `-`, `_`, `.`, spaces and leading zeros (`Lane_4` finds `lane-04`, `1014` finds `#1014`). When matches differ in strictness only the strictest are kept, with a note.

Live sessions (in a running Emacs with a fresh heartbeat) win. `find` falls back to saved sessions when nothing live matches and says so; `--all` shows both. `status` and `send` need a live session.

Results are never picked silently. On a miss the command prints the closest sessions (by prefix, substring and edit distance) and exits 20; when several match it lists them all (id, agent, state, last activity, buffer, tags, workspace) and exits 21; when only saved sessions match a live-only command it lists them and exits 22. `--json` prints `{query, scope, result, matched_by, tier, note, heartbeat, matches[], candidates[]}`, each session as `{id, short, live, state, buffer, tags, review_prs, workspace, agent, last_activity, quiet_for, transcript, self}`.

`session list` searches every workspace when `--tag` or `--grep` is given without `--workspace`, and lists pi sessions alongside claude and auggie ones.

## See what a session is doing

```bash
decknix session list --live [--tag lane-04]
decknix session status lane-04         # anything `find` accepts, if one live session matches
decknix session status lane-04 --json
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

Every message reaches the session's transcript with a header naming the sender (and, after an interrupt, the reason). `send` prints the message id and refuses with exit 14 when the receiver is off or Emacs is not running, since such a request could never be delivered. A full id that no live session has is refused too (exit 22, with the closest sessions), since a message to a closed or replaced session only expires; `--force` queues it anyway.

`--from` defaults to `$DECKNIX_SESSION_ID`, then `$CLAUDE_CODE_SESSION_ID`.

## Receipts

```bash
decknix session message <id>                  # queued | waiting | delivered | answered | rejected ...
decknix session watch <id> --until answered   # blocks; run it as a background command
decknix session inbox --clear                 # notices for messages sent with --notify
```

`answered` means the session's turn ended after the message (or went to `background`), and carries the closing text. Exit codes: 0 delivered or answered, 10 still pending, 11 not delivered, 12 unknown, 13 busy (`--when now`), 14 receiver off, 20 no session matches, 21 several sessions match, 22 only saved sessions match, 124 watch timed out.

## Interrupt policy

Set in Emacs:

```elisp
(setq decknix-agent-dispatch-interrupt-policy 'coordinator) ; never | opt-in | coordinator | always
(setq decknix-agent-dispatch-coordinator-tags '("coordinator"))
(setq decknix-agent-dispatch-interruptible-tags '("interruptible"))
(setq decknix-agent-dispatch-interrupt-min-interval 300)
```

Under the default `coordinator` policy, a sender whose session carries a coordinator tag may interrupt any session, and any sender may interrupt a session tagged `interruptible`. A session never interrupts itself, and a session it interrupted cannot interrupt it back within the interval.
