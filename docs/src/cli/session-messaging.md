# Session messaging

`decknix session status`, `send`, `message`, `watch` and `inbox` let one agent session (typically a coordinator driving several lane sessions) see what another live session is doing and hand it a message, without asking Emacs anything directly. Design and rationale: [`docs/specs/session-messaging/spec.md`](https://github.com/ldeck/decknix/blob/main/docs/specs/session-messaging/spec.md).

Two pieces run in Emacs:

- **State export** (`decknix-agent-session-export-mode`, on by default). Read-only: one small JSON file per live session plus a heartbeat in `~/.local/state/decknix/sessions/`, rewritten only when something changed.
- **Dispatch receiver** (`M-x decknix-agent-dispatch-mode`, off by default, see [Agent dispatch](./agent-dispatch.md)). Nothing is delivered, spawned or retired unless it is on in this Emacs run. You turn it on, or an agent does with `decknix session dispatch on` after asking you (see [The receiver](#the-receiver)).
- **Control watcher** (`decknix-agent-dispatch-control-mode`, on by default, Nix option `programs.emacs.decknix.agentShell.dispatch.remoteControl.enable`). It delivers nothing; it only lets `decknix session dispatch on|off` switch the receiver.

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

`status` also shows how long it has been busy, when it last produced output, the current tool, the closing text, queued prompts, the last message delivered to it, and its plan: entries done of total, the step in progress (`now`) and the first pending one (`next`), from the session's last ACP plan update (`plan: {current, next, done, total}` in the JSON, `null` when it has none). `stale` means the Emacs heartbeat is old or from another Emacs, so the state cannot be trusted. `receiver: OFF` means messages would not be delivered.

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

`answered` means the session's turn ended after the message (or went to `background`), and carries the closing text. Exit codes: 0 delivered, answered, spawned, retired or applied, 2 bad usage (missing workspace, unknown `--agent`, self-retire without `--force`), 10 still pending, 11 not delivered (rejected, expired, spawn-failed), 12 unknown, 13 busy (`--when now`), 14 receiver off, 15 no fresh Emacs heartbeat, 16 no control watcher, 20 no session matches, 21 several sessions match (or a retire target that is not exact), 22 only saved sessions match, 23 the saved session to resume is in another workspace, 124 watch timed out.

## The receiver

```bash
decknix session dispatch status      # exit 0 on, 14 off, 15 no fresh heartbeat
decknix session dispatch on          # ask the human first
decknix session dispatch on --release-queued
decknix session dispatch off
```

`status` shows the heartbeat age, whether the receiver is on, when and by whom it was armed (`human` or `control:<session>`), whether the control watcher runs, and how many requests are pending, queued and in flight. `on` and `off` do nothing (exit 0) when the receiver is already in that state. Without the control watcher they exit 16: only `M-x decknix-agent-dispatch-mode` can switch the receiver then. `off` lists the requests waiting in flight first; turning the receiver off settles them `not-sent`. A request to turn it on is refused when it was created before the watcher started, or while `decknix-agent-dispatch-remote-control` is nil (turning it off always works).

## Scale lanes: spawn and retire

```bash
decknix session spawn --workspace ~/src/app --tag lane-07,team-a --brief-file /tmp/lane-07.md
decknix session spawn --workspace ~/src/app --tag lane-07,team-a --mode auto -- "Pick up the parser work"
decknix session retire lane-07,team-a --reason "parser work merged"
```

`spawn` is idempotent, so re-running it is always safe:

- one live session already carrying every tag (exactly or ignoring case) is printed (`existing`) and nothing is started; several exit 21;
- otherwise one saved session carrying them is resumed in the background (exit 23 when it was recorded in another workspace; several exit 21, or pass `--no-resume` to start fresh);
- otherwise a new session starts in the background with the brief as its first message, prefixed `[decknix spawn <id> from <sender>]`.

`--agent` is `claude` (the default), `auggie` or `pi`; any other name exits 2 with that list before a request is written. It waits up to `--wait` seconds (180) and prints the new session id. In Emacs the receiver repeats the checks and adds its own: the workspace must be under `decknix-agent-dispatch-spawn-roots` (`~/Code`, `~/tools`), at most `decknix-agent-dispatch-spawn-max-live` (12) lanes, counting the sessions spawns started and any session tagged `lane-<digits>` (`decknix-agent-dispatch-spawn-counted-tag-regexp`) but not auto-review or other sessions, one spawn per `decknix-agent-dispatch-spawn-min-interval` (10 s), and the sender must satisfy `decknix-agent-dispatch-lifecycle-policy` (`coordinator` by default: the sender carries a coordinator tag). With the receiver off `spawn` exits 14; `--queue` writes the request anyway, to run when someone arms the receiver with `--release-queued`.

`retire` quits one live session named exactly: its full id, its buffer name, or tags only it carries, matched exactly or ignoring case. An id prefix or a normalised match exits 21. It waits for the session's turn to end (`--force` does not wait), never retires a session holding text you typed but did not send or carrying a protected tag (`coordinator` by default), refuses when the session's tags changed since you looked, and checks that the buffer is really gone. Retiring your own session needs `--force`. The saved record stays, so spawning the same tags later resumes it.

`decknix session message <id>` follows both: `launching` then `spawned` or `spawn-failed` for a spawn, `retired` for a retire.

## Interrupt policy

Set in Emacs:

```elisp
(setq decknix-agent-dispatch-interrupt-policy 'coordinator) ; never | opt-in | coordinator | always
(setq decknix-agent-dispatch-coordinator-tags '("coordinator"))
(setq decknix-agent-dispatch-interruptible-tags '("interruptible"))
(setq decknix-agent-dispatch-interrupt-min-interval 300)
```

Under the default `coordinator` policy, a sender whose session carries a coordinator tag may interrupt any session, and any sender may interrupt a session tagged `interruptible`. A session never interrupts itself, and a session it interrupted cannot interrupt it back within the interval.
