# Conversation identity — spec (draft)

One session, ten conversation keys. Fixing the lookup, the naming, and
the entries already on disk.

## 1. Observed

Session `5de16692` appears in **ten** conversation entries:

```
09d29407  tags=None     3e98a7ac  tags=None
37d2b6af  tags=None     523fdb64  tags=None   <- the buffer holds this one
5b4d1718  tags=None     613e8edf  tags=None
96a399f9  tags=None     9929b68f  tags=None
d88c0413  tags=None
b67b7519  tags=['guidelines','policies','ai','nurturecloud']   <- the real one
```

Its buffer holds an empty key, so it has no tags, so it named itself
after its workspace: `*Claude: nurturecloud*`. The switcher (`C-c b`)
shows that name and no tags, and the session is unrecognisable in a list
of a dozen.

Lookup by session id returns the right answer today:

```
by conv-key    -> nil
by session-id  -> ("guidelines" "policies" "ai" "nurturecloud")
```

## 2. Why this happens

The conv-key is `sha256(canonicalize(first_message)[:200])[:16]`. The
live write path and the transcript read path do not always produce the
same string for the same conversation — long prompts truncate
differently, an edited first message rehashes, and a resumed session
whose first message was a continuation primer hashes to whatever that
primer was. Each divergence mints a NEW conversation entry and registers
the session into it, so entries accumulate one per resume.

This is already known in the codebase. `decknix-agent-session-broker`
says so explicitly:

> "The session id is stable across launch and resume, unlike the conv-key
> (derived from the first message, which the live write path and the
> transcript-read path hash differently for long or edited prompts) — so
> this is the RELIABLE reattach link."

## 3. Where the lesson has and has not landed

| Consumer | Resolves by | Result |
|----------|-------------|--------|
| Broker key | session id, scanning all entries | correct |
| Header tags | conv-key, **falling back to session id** | correct |
| Buffer naming | conv-key only | falls back to workspace name |
| `C-c b` switcher | conv-key only | no tags |
| Session picker | conv-key (collapses by conversation) | one session, many entries |

Two consumers already do the right thing. The rest ask the fragile key
and take the empty answer at face value.

## 4. Design

### 4.1 One resolver, used everywhere

A single `decknix--agent-tags-resolve (conv-key session-id)`: try the
conv-key, fall back to the session id, and return the union when both
answer. Every consumer calls it; none reimplements the fallback.

The header's existing fallback becomes a call to this rather than a
second copy — the divergence between "two consumers do it right" and
"three do it wrong" is itself the bug pattern.

### 4.2 Naming must re-run

Fixing lookup does not rename `*Claude: nurturecloud*`; the name was
chosen at post-create when tags were absent. So naming re-runs when tags
first resolve — on resume, and when a session is tagged for the first
time.

That has a visible consequence to accept deliberately: a buffer can be
renamed under the user. Better than a permanently wrong name, but it
should happen once, not on every refresh.

### 4.3 Consolidation is the actual repair

Lookup fallback makes the symptom disappear. The store still grows one
entry per resume, and every future consumer has to know about the
fallback.

So: merge entries that share a session id. The winner is the one with
tags (or the earliest, when several have them); the others are folded in
and removed. This is the same family as the pending `session purge` task
and should share its machinery.

**Merging is destructive and must be reversible.** Write the store once,
after computing the whole merge, and keep a backup — a bad merge would
silently lose tags across many conversations, and tags are the only
durable metadata a session has.

## 5. Open questions

1. **Do any two conversations legitimately share a session id?** A fork
   might. If so, merging by session id is wrong and the key must be
   (session id + something).
2. **How many entries are affected?** 533 conversations, 133 with no
   sessions at all — the scale of duplication is unmeasured beyond this
   one example.
3. **Should the conv-key stop being derived from the first message?**
   That is the root cause rather than a symptom. A conversation could
   carry a stable generated id instead, with the first-message hash kept
   only as a migration path. Bigger change; worth costing before the
   fallbacks multiply further.
4. **Does the picker's collapse-by-conversation compound this?** Ten
   entries for one session means it can appear ten times, or hide behind
   whichever entry the live buffer claims.

## 6. Sequencing

1. `decknix--agent-tags-resolve` + repoint every consumer, header included
2. Naming re-runs when tags first resolve
3. Measure the duplication across the store (open question 2)
4. Consolidation, with a backup and a dry run
5. Decide on question 3 — a stable conversation id — once 3 shows scale

Steps 1–2 fix what is visible today and carry no risk to stored data.
Step 4 rewrites the store and is the only irreversible one; it waits
until step 3 says how much there is to merge and question 1 is answered.
