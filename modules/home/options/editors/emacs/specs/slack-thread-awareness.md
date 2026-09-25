# Slack thread awareness in the sidebar — spec (draft)

A WIP or Requests row should say whether a Slack thread exists for it and
whether that thread has unread replies, and the transient menus should be
able to jump to the thread or start one.

None of it is possible today, because nothing remembers which thread
belongs to which PR.

## 1. The missing link

`pr-request-review` posts to `#backend-code-reviews` and prints the
message timestamp:

```
Please review https://github.com/UpsideRealty/connect-to-core/pull/21 (...)
1790306388.157409
✓ Posted to #backend-code-reviews
```

That `ts` IS the thread identifier, and it goes to stdout and nowhere
else. `~/.config/decknix/hub/` holds nine state files and none of them is
about Slack:

```
github-reviews.json  github-wip.json  jira-tasks.json  linked-prs.json
meta.json  pr-cache.el  repo-cache.el  session-meta.eld
teamcity-builds.json  teamcity-deploys.json  worktree-clones.el  worktrees.el
```

So every review request posted so far is already unrecoverable by
tooling. Four went out on 2026-09-24/25 alone.

This is the same shape as the problem `decknix-hub-pr-memory` solved for
merged worktrees: an association that existed at one moment and was never
written down. The fix is the same — persist identity at the moment it is
known, resolve state later.

## 2. Persist the association

```
(repo, pr) -> { channel, ts, permalink, posted_at }
```

Written by `pr-request-review` at post time, since that is the only point
where the `ts` is known for free. Keyed by `(repo, pr)` rather than by
URL so a row can look it up without string surgery.

`linked-prs.json` already exists for a different purpose (session to PR
links) and is not the right home: this is hub-poller-adjacent state, not
session state. A sibling `slack-threads.json` keeps the concerns apart.

**Backfill is possible and worth doing once.** `conversations_search_messages`
can find a PR URL in the channel history, so existing threads can be
recovered rather than written off. Cheaper than re-posting and avoids
pinging reviewers a second time.

## 3. Resolving thread state

Two facts are wanted per row, and they differ in difficulty.

**Does a thread exist, and how many replies?** Straightforward:
`conversations.replies` on the stored `ts` gives `reply_count` and the
latest reply timestamp.

**Are the replies unread?** Harder, and the honest answer is that Slack
does not expose per-thread read state cleanly. A channel has `last_read`;
a thread has no equivalent in the public API. Options, none free:

- Compare the thread's `latest_reply` against the channel's `last_read`.
  Approximates unread, and is wrong when the channel is read but the
  thread is not.
- Use the `slack` MCP's `conversations_unreads`, which may expose more
  than the raw API does. Needs checking before it is designed around.
- Keep our own per-thread `last_seen` marker, updated when the user jumps
  to the thread from Emacs. Fully under our control and honest about what
  it means ("unread since you last opened it from here"), but does not
  know about reading it in the Slack client.

The third is the only one that cannot silently lie, and it is also the
one that will diverge from the Slack client. Worth deciding deliberately;
this is the spec's main open question.

## 4. Glyph

The sidebar already carries two comment glyphs with hard-won rules (see
`pr-review-in-emacs.md` §1). A Slack indicator must not repeat that
mistake: it should mean one thing.

```
(none)   no thread known for this PR
s        thread exists, nothing new since last seen
S        thread has replies newer than last seen
```

Deliberately NOT keyed on reply count alone: a thread whose only reply is
my own post is not something to read. Same reasoning that removed
bodiless approvals from the `i` glyph.

## 5. Transient actions

Both the WIP and Requests menus, and the review board:

```
open thread      jump to the permalink (browse-url)
create thread    post the review request, storing the ts
copy link        yank the permalink
```

`create thread` is `pr-request-review` under a keybinding, which means
the mandatory dry-run gate has to survive the move. A keystroke that
silently pings reviewers is exactly what that gate exists to prevent, so
the Emacs path must show the resolved mentions and require confirmation
before posting, the same as the CLI does.

## 6. Sequencing

1. `pr-request-review` writes `slack-threads.json` at post time
2. One-off backfill via `conversations_search_messages` for existing PRs
3. Pure Emacs reader + glyph decision layer, ERT-tested against fixtures
4. Decide the unread question (§3) — needed before the glyph means anything
5. Thread state into the hub poll, so the glyph is not a synchronous
   Slack call per row
6. Transient actions: open, copy, then create behind the dry-run gate

Steps 1 and 2 are the blocker and are cheap. Step 4 is a decision, not
code, and steps 3 and 5 are guesswork until it is made: a glyph whose
meaning is unsettled is worse than none, which is the lesson from the
italic `i`.
