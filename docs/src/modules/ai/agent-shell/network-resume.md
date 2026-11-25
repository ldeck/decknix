# Auto-Resume After Network Loss

A short DNS or network blip stops every agent turn in flight. Each session ends its turn on one line, such as

```text
API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)
```

and then waits for a human to type "continue". Background sub-agents started by those sessions stop with them. Auto-resume does that typing for you once the link is back, and never when you have taken the session over yourself.

It builds on the [`netfail` status](./keybindings.md#network-failure-recovery): a session that died on the link is flagged first (red, `⚑` in the sidebar), and auto-resume decides whether, and when, to re-prompt it.

## What counts as a network failure

Only a failure the agent's **own API call** reported is considered: the line starts with `API Error`, `Connection error`, `Request failed`, `Network error`, `Fetch error` or `stream error`, or arrived as the JSON-RPC error of a failed prompt. A tool that could not reach its own service (`Error: getaddrinfo ENOTFOUND github.com`) is not a reason to re-prompt the session, and neither is an agent discussing an error.

| Class        | Examples                                                                                                                  | Resumed?                         |
|--------------|---------------------------------------------------------------------------------------------------------------------------|----------------------------------|
| `network`    | `ENOTFOUND`, `EAI_AGAIN`, `ECONNRESET`, `ECONNREFUSED`, `ETIMEDOUT`, `Can't reach the API server`, `Connection closed mid-response`, `Stream idle timeout`, `socket hang up`, `fetch failed` | Yes, when the API host answers   |
| `overloaded` | `529 Overloaded`, `502 Bad Gateway`, `503 Service Unavailable`, `504 Gateway Timeout`, `408`                               | Yes, after a backoff (60 s, 120 s, ... up to 15 min) |
| `server`     | a bare `500 Internal server error`                                                                                        | No: it repeats as often as it clears |
| `rate-limit` | `429`, `rate limit`                                                                                                       | No                               |
| `auth`       | `401`, `403`, OAuth expired, not logged in                                                                                | No                               |
| `quota`      | usage, weekly or monthly limit, credit balance, budget                                                                    | No                               |
| `local`      | a failure naming `localhost` or `127.0.0.1`                                                                               | No                               |

A user cancel, a model refusal or a tool error never produces any of these lines, so it is never resumed. When a line names both a limit and an errno, the limit wins.

## How recovery is detected

Nothing runs while no session waits on the network: no process, no timer. When the first session is flagged:

1. `notifyutil -w com.apple.system.config.network_change` starts (macOS only). A network change is debounced for two seconds, then triggers a probe.
2. A probe also runs on a backoff: 10 s, then 20, 40, ... up to 5 min between attempts. DNS can fail while the interface stays up, which no network-change event reports, so the backoff is what catches that case.
3. The probe is a child process: `curl -I` to the API host of each waiting session (DNS, TCP and TLS; any HTTP answer, even a 401, counts as reachable), or `nc -z host 443` without curl. The host comes from the failure (`ENOTFOUND api.example.com`), else from the provider (`decknix-agent-net-resume-hosts`), else `api.anthropic.com`.
4. When the probe succeeds, the watcher stops and waiting sessions are resumed. If any are still waiting afterwards, it starts again.

An `overloaded` session needs no probe, since the link is up; it is resumed by a timer when its backoff runs out.

## When a session is resumed

At the moment of the resume, each rule must still hold; otherwise the session is left for you:

- auto-resume is on, and not suppressed for this session;
- the session is still `netfail`: not waiting on a permission prompt, not killed, not already re-prompted by you;
- it is not asking you a question;
- it is idle: a session that woke up by itself (a background task finishing) is not interrupted;
- nothing is typed and unsent at its prompt or in its compose buffer, and nothing is queued;
- it has had fewer than `decknix-agent-net-resume-max-attempts` (3) resumes in this failure streak, and none in the last 30 s.

A session skipped because you were typing, it was asking, or it was busy, is skipped for this failure. The resume is never queued behind you.

Resumes in one recovery are staggered 4 s apart plus up to 3 s of jitter, because each one re-uploads its whole context to a link that has only just come back. Each resume sends

```text
↻ The network dropped and is back. Continue where you left off; re-run any step that failed because of the network. [auto-resume 1/3]
```

so the transcript shows which prompts were automatic, and the echo area reports how many sessions were resumed.

A failure streak ends when a turn completes without a network failure, or when you send the session anything yourself. A session that fails again after a resume waits out the probe backoff before the next attempt; after the third, it stays `netfail` for you.

## In the sidebar

Next to the session's status:

| Badge  | Meaning                                                  |
|--------|----------------------------------------------------------|
| `↻…`   | waiting for the link; no resume sent yet                 |
| `↻2`   | two resumes sent in this streak, still failing           |
| `↻✗`   | gave up after the cap: over to you                       |
| `↻off` | auto-resume is suppressed for this session               |
| `↻`    | resumed, and the next turn got through                   |

## Turning it off

| How                                     | Scope                                             |
|-----------------------------------------|---------------------------------------------------|
| Sidebar toggles (`T`), then `Z`          | All sessions, until toggled back or Emacs restarts |
| `(setq decknix-agent-net-resume-enabled nil)` | All sessions, permanently                    |
| `C-c s M-N` (`decknix-agent-net-resume-suppress`) | One session, until toggled back (survives restarts) |

The manual commands (`C-c s N`, `C-c s C-n`, `C-c s M-n`) keep working either way.

## Across Emacs restarts

Agent processes survive an Emacs restart in the broker. The attempt count, the backoff deadline and the suppression for each session id are kept in `~/.local/state/decknix/net-resume.eld`, written before each resume is submitted, so a restart neither repeats a resume nor starts a fresh cap. A minute after start (deferred while you type), every live session is rescanned, and those whose restored last turn ended on a network failure rejoin the watcher.

## Agents

| Agent  | Failure shape                                                                                                  |
|--------|----------------------------------------------------------------------------------------------------------------|
| Claude | `API Error: ...` streamed as agent text, then either a normal turn end or a JSON-RPC `-32603` error (`Internal error: API Error: ...`, `data.errorKind: "server_error"`). Both are handled. |
| Pi     | `**Pi error (provider/model):** detail` streamed as agent text, then a normal turn end. Not flagged as `netfail` yet, so not resumed. |
| Codex, Auggie, Antigravity | Through the same JSON-RPC error or agent-text paths. Not exercised against a real outage; extend `decknix-agent-net-error-transient-regexp` if their wording is missed. |

## Settings

| Variable                                        | Default                       |
|-------------------------------------------------|-------------------------------|
| `decknix-agent-net-resume-enabled`              | `t`                           |
| `decknix-agent-net-resume-max-attempts`         | `3`                           |
| `decknix-agent-net-resume-prompt`               | the prompt above              |
| `decknix-agent-net-resume-overloaded-prompt`    | the same, for an overloaded API |
| `decknix-agent-net-resume-stagger`              | `4.0` s                       |
| `decknix-agent-net-resume-jitter`               | `3.0` s                       |
| `decknix-agent-net-resume-min-interval`         | `30` s                        |
| `decknix-agent-net-resume-probe-backoff`        | `(10 . 300)` s                |
| `decknix-agent-net-resume-overloaded-backoff`   | `(60 . 900)` s                |
| `decknix-agent-net-resume-hosts`                | provider to API host          |
| `decknix-agent-net-resume-startup-delay`        | `60` s idle                   |
