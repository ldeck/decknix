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

## 4.4 Measured: how much duplication there actually is

Step 3, run against the live store on 2026-09-11.

```
conversations total        541
  with tags                347
  without tags             194
  with no sessions at all  133
distinct session ids       530
session ids in >1 conv      38     (7% of sessions)
  worst / median spread     10 / 2
  surplus entries           96
```

The breakdown that decides step 4:

```
  tags on exactly one entry  34   unambiguous merge, one winner
  tags on more than one       4   merge must union
  tags on no entry            0   nothing to lose
```

This is smaller and safer than the `5de16692` example suggested. That
session, at ten entries, is the worst case in the whole store; the median
duplicated session has two. Nothing is in the "tags scattered with no
clear winner" state that would make a merge lossy, and the four
multi-tagged cases are exactly what the union in
`decknix--agent-tags-resolve' already handles on read.

It also softens open question 1. If these were legitimate forks we would
expect tags on several entries; instead 34 of 38 have tags on precisely
one and the rest are empty. That is the signature of key scatter, not of
deliberate branching -- suggestive rather than conclusive, since the store
records no intent.

## 4.5 Step 4, and why the specified merge was wrong

Section 4.3 says "merge entries that share a session id". Run as written,
against the live store, that is destructive — and the dry run is the only
reason it was caught.

Merging by shared session id is TRANSITIVE. Some entries are containers
that wrongly accumulated many unrelated session ids (`d2b0c372c9` holds
fifteen, untagged; four such entries exist). Chaining through them
collapsed 60 conversations into one carrying **47 tags and 27 sessions** —
`guidelines/policies/ai` merged with `activepipe/conn`, `dos/day6/log`,
`rea-integration/#15/review` and thirty more. That destroys findability,
which is the entire point of the fix.

The §4.4 measurement did not predict this. It counted session ids owned by
several conversations and found 34 of 38 unambiguous, which is true and
irrelevant: it measured pairs, and the danger is in the transitive
closure.

**Applied instead — a fold that cannot chain.** An entry is removed only
when all three hold:

- its session set is exactly `{S}` (never a container),
- it carries no tags (nothing to lose),
- exactly one owner of `S` has tags (an unambiguous winner).

Result: 46 empty entries folded away, 541 → 495 conversations, zero tags
lost, zero session ids lost, and the largest tag count on any conversation
unchanged at 8. `5de16692` went from ten entries to two: its tagged one
and a container that is deliberately left alone.

26 session ids still sit in more than one conversation. Those are the
container cases, and they need the containers understood — probably
repaired at the write path — rather than merged.

The generalisable lesson, and the reason the dry run was mandated: a
measurement can be accurate and still support the wrong conclusion, when
it measures a different structure than the operation traverses.

## 4.6 The write path: already fixed, plus one latent hole

Asked to fix "unrelated session ids being added to the same
conversation". Analysed: **the code cause was already fixed.**

`decknix--agent-non-keying-preambles` rejects both machine-generated
openings, and its own docstring names `887e38e509a9ee3e` -- one of the
four containers found here. Verified the predicate still behaves: it
matches a fork preamble and a resume primer, and does NOT match a genuine
user message that merely mentions resuming.

The containers are residue from before that guard, and they had stopped
growing: last accessed 2026-06-26, 07-10, 07-13 and 08-03, against a
current date of 09-11.

Data repaired in two passes (see 4.5 for the first). The second strips a
session id from an untagged container when exactly one TAGGED owner
exists, dropping any container left empty:

```
containers touched         6
session links removed     25
emptied entries dropped    2
conversations            495 -> 493
duplicated session ids    26 -> 4
tags lost                  0
session ids lost           0
```

`5de16692` now resolves to exactly one conversation carrying its real
tags. The remaining 4 have tags on more than one owner, so no single
winner exists and they are deliberately untouched.

### Latent: an argless slash command keys identically every time

Not currently biting -- zero such buckets in the store -- but the same
class of bug:

```
/standup       -> 36e6d3abb4947808   (every invocation, any day)
/start         -> b34dafd9a78e1808
/review-bot-pr <url-1> -> 8495e79053300a86   (distinct, fine)
```

A command with args canonicalises to `name args' and keys distinctly. An
argless one canonicalises to just the name, so two unrelated sessions
started the same way collide -- a container by construction.

**Deliberately not fixed blind.** The obvious repair, adding argless
commands to the non-keying list, has a plausible regression: a nil
conv-key defers metadata to `prompt-ready', which recomputes from the same
first message and yields nil again, so such a session might store no tags
at all -- worse than the collision. The likelier correct shape is to key
those by session id, since for an argless command the conversation genuinely
IS the single session. That wants its own change and its own test, on
evidence rather than on this reasoning alone.

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
