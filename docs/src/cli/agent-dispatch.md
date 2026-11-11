# Agent dispatch

`decknix-agent-dispatch` hands one prompt to one live agent-shell session, only when you have asked for exactly that. It is built for a coordinator agent that needs to message an existing session, and it is deliberately hard to misuse.

Nothing is sent by installing it. Delivery needs both an explicit `send` for a specific session and the receiver switched on in Emacs.

For coordinators, prefer `decknix session send` ([Session messaging](./session-messaging.md)): it resolves a session by tag or buffer name, shows the session's state first, waits up to 24 h for an idle point, supports `--when now` and `--when interrupt`, and records `answered` receipts. It writes version 2 requests to the same receiver; this script keeps writing version 1 requests with the behaviour described below.

## Turn the receiver on (once per Emacs run)

```
M-x decknix-agent-dispatch-mode
```

It is off by default and never auto-enabled. Turning it on creates the private state directory, settles anything left over from a previous run as `unknown` or `not-sent` (never retried), and ignores every request created before that moment. Turning it off settles waiting requests as `not-sent`.

## Send

```bash
decknix-agent-dispatch send --session 11111111-2222-4333-8444-555555555555 --prompt-file prompt.md
printf 'short prompt' | decknix-agent-dispatch send --session <uuid> --prompt-stdin --ttl 60
```

`--session` must be the full lowercase session UUID. There is no prefix match, no broadcast, and exactly one session per request. The command prints the request id and returns immediately; it never contacts Emacs.

A request expires after `--ttl` seconds (default 120, maximum 900). Past that it can never be delivered.

## Inspect

```bash
decknix-agent-dispatch status <request-id>
```

Exit codes: 0 accepted, 10 pending or waiting, 11 not delivered (rejected, expired, not-sent, cancelled), 12 unknown outcome, 2 no such request. `accepted` means the prompt was submitted and the session went busy. `unknown` means the submit was attempted but not confirmed; it is never retried, so look at the session before sending again.

Other commands: `cancel ID` (only before the receiver claims it), `sweep` (settle expired requests), `list`, `paths`.

## What is refused

The session is absent, held by more than one buffer, or changed between claim and send. Its process is gone. You have typed something at the prompt that is not sent yet (it is left untouched). The request is stale, future-dated, tampered with, or its file is a symlink or not mode 0600. A busy session is waited on, never interrupted, and only until the request expires (only a version 2 `--when interrupt` request from `decknix session send` can interrupt, under the interrupt policy).

Receipts live in `~/.local/state/decknix/agent-dispatch/receipts/` and never contain the prompt text.
