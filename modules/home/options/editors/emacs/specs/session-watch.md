# Session watch — spec (draft)

Making "I'll report when it lands" a promise the system can keep.

## 1. The problem, observed

Session `664460b2` finished a terraform apply, said it would report when
something landed, and sits at `ready`:

```
*Claude: claude/nurturecloud/support/hot/#210/reinz*
status=ready   busy=nil   proc=live
  …apply:running SUCCESS(i2)
```

It will never report. An agent does nothing between turns — no timer, no
callback, no way to notice CI finishing. The promise is unfulfillable by
construction.

This is worse than a session that visibly wants you. `asking` announces
itself; a stalled promise looks *finished*, so you stop checking it. The
session most likely to be forgotten is the one that told you it would
follow up.

## 2. Two fixes, and why only one is honest

**Surface it.** Add a `pending` status for a turn that ended mid-workflow.
Cheap, but detecting it means parsing agent prose for promises — every
session that says "I'll…" becomes a false positive, and the ones phrased
differently are missed. It makes the display slightly better and the
promise no more true.

**Make the promise true.** Register a condition; re-prompt the session
when it fires. This is the one worth building, and it removes the need
for prose-parsing entirely.

## 3. What already exists

| Piece | Gives us |
|-------|----------|
| Hub file-notify tick | A periodic evaluation point that is already cheap and already running |
| `github-reviews.json` / `github-wip.json` | PR state: checks, mergeable, review decision |
| `teamcity-builds.json` / `teamcity-deploys.json` | Build and deploy state |
| `wait-for-pr-reviews` | The blocking form of exactly this, already written |
| Auto-review's `:after` advice | The precedent for acting on a hub tick |
| Spawn queue | Throttled dispatch, so N firing watches do not stampede |
| Broker (#151) | Sessions survive a restart, so a watch can outlive Emacs |

The evaluation loop is therefore not new work. What is new is a registry
and a re-prompt.

## 4. Design

### 4.1 The user registers the watch, not the agent

The obvious design is for the agent to declare "watch this for me". It is
also the wrong one to start with: it needs a tool or command surface, and
it puts the trigger for a model turn inside model output.

So v1: **you** mark a session as watching, from the board (`w`) or the
session (`C-c s w`). The condition comes from the row's PR — its checks,
its merge state — not from prose. No heuristics, nothing to misparse.

Agent-registered watches can follow once the mechanism is proven, and
would then be a strictly smaller change: same registry, different writer.

### 4.2 Conditions

Start with what the hub already knows:

- `checks-complete` — CI finished (pass or fail) for this PR
- `merged` — the PR left the queue (the `gone` classification)
- `reviewed` — someone else posted a review (`others_reviewed`)
- `build-finished` — a TeamCity build reaches a terminal state

Each is a pure predicate over feed data plus the watch's recorded
baseline, so each is testable without a session.

### 4.3 Firing

On a hub tick, for each watch whose condition holds:

1. If the session is busy, **queue** rather than interrupt — a re-prompt
   mid-turn would talk over the agent.
2. Submit a short prompt naming what changed.
3. **Remove the watch.** One-shot by default.

### 4.4 Constraints, each earned elsewhere in this codebase

- **A watch must expire.** Anything registered and never cleaned up leaks:
  the orphaned brokers ran for hours because nothing reaped them. Watches
  get a TTL and are dropped when their session dies.
- **Firing costs a model turn.** So one-shot, and never re-fire on the
  same transition.
- **Watches must be visible.** An invisible automation that silently stops
  working is the auto-review-mode bug again — that reverted to `off` on
  every restart and nobody noticed, because the failure was quiet. The
  board shows what is being watched, and the count is in the header.
- **Watches must survive a restart**, or they break exactly when a
  long-running condition would have fired. Persist beside the other
  session state, which is now the established home for anything that must
  outlive a `kickstart`.

## 5. Open questions

1. **Does a fired watch re-prompt, or just notify?** A re-prompt spends a
   turn unasked; a notification leaves you to act. Notification is the
   safer default and may be sufficient — the value is knowing, not
   necessarily acting.
2. **What baseline does a condition compare against?** "Checks complete"
   is only meaningful relative to when the watch was set; otherwise an
   already-green PR fires immediately.
3. **What happens to a watch whose session was detached?** The agent is
   alive in its broker but has no buffer. Firing into it is legitimate and
   the output would be invisible until reattach.
4. **Is `pending` still worth having** as a display state for a watched
   session, distinct from `ready`? Probably — but only once watches exist,
   so it describes a fact rather than a guess.

## 6. Sequencing

1. Watch registry + persistence, no conditions (register, list, expire)
2. One condition end to end: `checks-complete`, notify only
3. The board surface: show watches, `w` to set, count in the header
4. Re-prompt instead of notify, behind a setting
5. More conditions; agent-registered watches

Step 2 is the smallest end-to-end slice that proves the loop. Step 4 is
the first that spends a model turn without being asked, so it lands after
the mechanism has been lived with.
