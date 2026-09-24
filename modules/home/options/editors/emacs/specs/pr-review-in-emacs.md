# PR comment attention + reviewing in Emacs — spec (draft)

Two asks, one data layer. The italic `i` fires when it should not, and
there is no way to read or conduct a review from Emacs. Both want the
same thing the feed does not currently carry: **inline review threads,
attributed and resolved-or-not**.

## Part 1 — the `i` glyph is answering a different question

### 1.1 What it actually means today

`needs_reply` is computed in `pkgs/decknix-hub/src/main.rs`. Its own
declaration says it (main.rs:183):

```rust
needs_reply: Option<bool>, // true when latest comment/review is from someone else (bot or human)
```

The activity pass (main.rs:1188–1230) builds one stream from two sources
and sorts by timestamp:

- `view.comments` — PR-level conversation comments
- `view.reviews` — every submitted review

then:

```rust
let reply_needed = activities.last().map(|(_, a)| *a != Actor::Me).unwrap_or(false);
```

So `i` means **"the last thing that happened on this PR was not by me"**.
Nothing about inline comments, and nothing about whether anything was
said at all.

### 1.2 The three false positives

Each of these sets `i` today, and none of them is a comment to consider:

```
someone approves with no body     a review with submitted_at, empty body -> activity
someone writes "LGTM" / "deployed" a conversation comment                -> activity
a bot posts anything               activity (bot_pending only partly separates it)
```

The approval case is the sharpest: a bodiless `APPROVED` review is
*good news*, and it renders as the same glyph as an unanswered question.

### 1.3 What the data can already support

`ReviewThreadStats` (main.rs:805–842) is the right shape and is already
fetched, via a dedicated GraphQL query because `gh pr view --json` does
not surface `isResolved`:

```graphql
reviewThreads(first: 100) { nodes { isResolved comments(last: 1) { nodes { author { login } } } } }
```

`unresolved_to_me` already means "unresolved AND the last commenter is
not me", which is most of the way there. What it does **not** do is
distinguish a bot from a human — so an unresolved Copilot thread and an
unresolved colleague question are one number.

Bot detection already exists for the activity stream: `classify_author`
(main.rs:530) and `login_is_bot`. Threads have the last commenter's
login, so the same classification applies with no extra query.

### 1.4 Proposed fields

Fetcher-side, and this is a fetcher change before it is an Emacs change:

```
human_unresolved   unresolved threads whose last commenter is a non-bot human != me
bot_unresolved     unresolved threads whose last commenter is a bot
human_said_something  a human authored a NON-EMPTY body (inline, conversation,
                      or review body) after my last activity
```

The third is what separates "a colleague engaged with the substance"
from "a colleague clicked approve". Requires filtering the activity pass
on a non-empty body rather than on the existence of a record.

### 1.5 Glyph semantics that follow

```
i  italic   human_unresolved > 0 OR human_said_something   — read this
ẞ  bot      bot_unresolved > 0                             — bot thread open
·  dim      i_replied_last AND threads still open           — waiting on them
(none)      approvals, bodiless reviews, resolved threads
```

An approval stops being a comment glyph entirely; it is already carried
by `review_decision` and the state word, which is where it belongs.

## Part 2 — reviewing from Emacs

This is #165 step 3, and it needs exactly the thread data Part 1 adds:
once threads are fetched with author, body, path, line and resolution,
the review surface is a renderer over them rather than a new fetch.

### 2.1 Reading a review

The unit is a thread, not a comment: a thread has a file, a line, a
resolution state and an ordered conversation. So the surface is a
thread list per PR, each expandable, each with a jump to `file:line` in
the worktree that `#165 step 1` already creates.

Minimum useful set:

```
list threads for a PR          grouped by file, unresolved first
jump to file:line              in the review worktree
read the full conversation     all comments in a thread, not just the last
reply to a thread              one comment, no state change
resolve / unresolve            the action that actually clears the glyph
```

`gh api` covers all of it, and the resolve mutation is GraphQL
(`resolveReviewThread`), which the hub already has a path for.

### 2.2 Conducting a review

Distinct from reading, and the house rules constrain it hard: the
`/review-service-pr` workflow in `AGENTS.md` mandates a two-phase
flow with a confirmation gate, canonical approval bodies, 👍/👎 on bot
comments rather than restating them, and inline comments rather than an
uber-comment. Anything built here must compose the whole plan locally
and present it before a single write, or it violates that contract.

That argues for a **staging buffer**: accumulate pending inline
comments, a verdict and a body; show the complete plan; submit as one
`pulls/{n}/reviews` call with the comments array. One write, one
reviewable artifact, gate satisfied by construction.

### 2.3 Why not just use the agent

The agent already drives `/review-service-pr` well. What Emacs adds is
the *reading* half: seeing at a glance which threads are open, whose
turn it is, and jumping to the code. The conducting half is worth
having so a human correction does not require leaving the editor, but
it is the lower-value of the two and should land second.

## 3. Open questions

1. **Does `human_said_something` need to survive a resolve?** A human
   asks a question in the conversation tab (not a thread, so nothing to
   resolve) and I answer it. `i_replied_last` clears it. But if they
   comment again and I never reply, it stays lit forever with no way to
   dismiss. A per-PR "seen" marker may be needed, which is state the
   hub does not currently keep.
2. **Bot detection on threads uses login only.** `login_is_bot` takes an
   `is_bot` flag the thread query does not fetch. Worth adding
   `author { login __typename }` (or `... on Bot`) rather than relying on
   login patterns, which miss a bot with an ordinary-looking name.
3. **100-thread ceiling.** `reviewThreads(first: 100)` is unpaginated.
   Fine for the glyph counts, probably not for a review surface on a
   large PR. Needs pagination before Part 2 renders threads.
4. **Where does the review surface live?** The review board is a list of
   PRs; a thread list is per-PR. Either a new buffer or a board
   expansion. The board already has `RET` semantics worth not breaking.

## 4. Sequencing

1. Split `unresolved_to_me` into `human_unresolved` / `bot_unresolved`
   in `parse_thread_nodes` (same query, add classification)
   ✅ landed, with Rust tests asserting the two counts PARTITION
   `unresolved_to_me` so the Emacs side can trust either alone
2. Body-aware activity: add `human_said_something`, stop counting
   bodiless reviews as comment activity
   ✅ landed. Note there are TWO near-duplicate activity passes (the
   Requests path in `fetch_pr_ci` and the WIP path), both of which had to
   change; they are a standing invitation to fix one and not the other.
3. Repoint `decknix--hub-activity-icons` onto the honest fields, with the
   glyph table from §1.5
   ✅ landed, gated on the new fields being PRESENT. Absent (a feed from a
   hub binary that has not restarted) keeps the legacy rules exactly, so
   nothing regresses in the gap. Treating nil as zero would have gone
   silent across the board instead.
   Also: approval no longer blanket-suppresses activity icons on an
   attributed feed. An open human thread on an approved PR is precisely a
   comment worth considering, and the old rule hid it.
4. Fetch full thread detail (author, body, path, line, resolution) with
   pagination — the Part 2 data layer
5. Thread list + jump + read (reading half of Part 2)
6. Reply + resolve
7. Staging buffer + single-call review submission (§2.2)

Steps 1–3 fix the reported problem and are small; step 1 is where the
real ambiguity dies. Step 4 is the boundary: everything after it is a new
surface rather than a corrected signal, and should not start until 1–3 are
lived with, because the glyph rules are what tell us whether the
attribution is actually right.
