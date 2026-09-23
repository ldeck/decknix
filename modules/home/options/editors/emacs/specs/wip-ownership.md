# WIP ownership — spec (draft)

The WIP section shows work that is no longer yours. Two ways in, one
theme: nothing removes a PR from your list when responsibility moves.

## 1. The scenario, from a competing tool

`devtool-bear-with-me` PR #69, 2026-09-23 — *"Hide authored PRs that are
assigned to someone else"*:

> Once a PR is handed off by assigning it to someone else, it's theirs to
> drive, so it shouldn't keep cluttering the author's list. PRs assigned
> to the viewer still arrive via the `assignee:@me` search, and unassigned
> authored PRs are still shown.

Three cases, and the middle one is the whole point:

```
authored, unassigned            show   — nobody has picked it up
authored, assigned to me        show   — mine to drive
authored, assigned to someone   HIDE   — theirs to drive
```

## 2. We cannot express this yet

The WIP feed carries no assignee data. Measured on the live file:

```
authors, bot_pending, bot_replies_to_me, branch, draft, i_replied_last,
mergeable, needs_reply, number, replies_to_me, review_decision, state,
title, total_threads, unresolved_threads, updated, url
```

`requested_reviewers` is NOT a substitute. On GitHub an assignee and a
requested reviewer are different relations, and the distinction is exactly
what the rule turns on: a PR can have three requested reviewers and still
be yours to drive, or none and belong to someone else entirely.

So this is a FETCHER change before it is an Emacs change. Nothing in the
sidebar or the review board can act on a field that is not in the feed.

## 3. The sibling problem

`wip-worktree-status.md` records the other half: a worktree whose PR has
merged renders as `wip` and loses its number, because
`decknix--hub-wip-placeholder-rows` selects worktrees "lacking a matching
OPEN PR" and cannot tell "never had one" from "had one that merged".

Same theme. WIP shows work that has left you — by merging, or by being
handed to someone else — because nothing models the transfer of
responsibility. Worth building together; the two fixes touch the same rows
and would otherwise be designed twice.

## 4. Design questions

**Hide, or de-emphasise?** Bear-With-Me hides. Our WIP section has
visibility TOGGLES (`decknix--hub-wip-hide-linked`,
`decknix--hub-wip-hide-terminal`) rather than hard filters, and that has
been the better pattern here — a hidden row is unfindable when the
assumption behind hiding turns out wrong. A toggle defaulting to hide,
matching `hide-terminal`, is the shape that fits.

**Whose view is "mine"?** `assignee:@me` is one query; the feed is built
from a search across repos. Adding assignees to the existing query is
cheaper than a second query and keeps one source of truth.

**Interaction with review sessions.** A PR reassigned away while a review
session is live is the `gone` case the board already models
(`decknix--hub-review-status`), but `gone` currently means "left the
feed". If hiding removes it from the feed, sessions on it would read as
`gone` — which is arguably correct, and arguably a surprise. Decide
deliberately rather than inheriting it.

## 5. Sequencing

1. Add `assignees` to the WIP fetcher's query and feed
2. `decknix--hub-wip-assigned-elsewhere-p` — pure predicate over a row
3. Visibility toggle, defaulting to hide, beside `hide-terminal`
4. Decide the `gone` interaction for live review sessions (§4)
5. Fold in `wip-worktree-status` steps 1–2, which touch the same rows

Step 1 is the blocker and is outside Emacs. Steps 2–3 are small once the
data exists. Step 4 is a decision, not code.
