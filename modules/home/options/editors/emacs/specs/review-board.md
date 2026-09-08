# Review board — spec (draft)

A single screen for managing PR review requests and the agent sessions
that serve them: ordered, grouped, and actionable on a marked set rather
than one session at a time.

## 1. The problem, as observed

Auto-review dispatches **per item**. Five dependabot bumps against
`listing-performance-service` become five buffers, five brokers and five
agents, each independently reviewing one bump of the same repo. Nothing
records that they are related, so nothing can sequence them, notice they
conflict, or fix them together.

Measured on one ordinary day: 21 open review requests, 11 live agent
sessions, and no way to answer "which of these needs me next?" other than
opening them. The reported experience was being swamped and cycling
through sessions at random.

Two distinct failures, and they want different fixes:

- **Volume.** Too many sessions exist. Fixed upstream by grouped
  dispatch (§7), not by this board.
- **Attention.** Of the sessions that legitimately exist, which one now?
  That is this board.

A board alone would organise sessions that should never have been
created, so the two are specified together and sequenced deliberately.

## 2. What already exists

| Piece | Where | Gives us |
|-------|-------|----------|
| Priority score | `review-priority/` | Incident > feature > EH, crossed with engagement. Answers "which next". |
| Staleness status | `review-status/` | `gone` / `stale` / `answered` per request or session. |
| Review identity | `review-identity/` | Which PR a session is reviewing, surviving rename and tag edits. |
| Session snapshot | `hub-bulk` | Memoised per-session tags/PR, cheap on the render path. |
| Auto-review policy | `auto-review/` | `off` / `bot` / `human` / `any`, readiness predicates. |
| DoS board | `dos-board/` | The interaction model this follows. |
| Bulk send | `session-bulk-send/` | Partition logic for dispatching to many sessions. |

So the data layer is largely done. This spec is mostly about a surface
and a set of verbs.

## 3. What the DoS board establishes, and what we keep

`decknix-dos-board` is the precedent, and its discipline is the part
worth copying rather than its lanes:

- **It renders and dispatches; it does not compute.** The `nc-dos-sidebar`
  CLI is the single engine, so terminal and Emacs stay in parity.
- **Lanes are constant.** A lane is always present, even when empty, so
  position is learnable.
- **Single-key actions on the row at point**, plus a transient for
  discovery (`?` / `.`).
- **Read-only buffer, auto-refreshing.**

We keep all of that. The engine here is the hub JSON plus the pure
packages in §2, not a new CLI: there is no terminal counterpart to stay
in parity with, and inventing one would be cost without a reader.

The significant departure is **marks**: the DoS board acts on point, this
board must act on a set. That is the whole point of it.

## 4. Model

### 4.1 Lanes

Ordered top to bottom, always rendered:

1. **Needs you** — sessions blocked on input (`waiting`, `asking`,
   `netfail`). Nothing else matters while this lane is non-empty.
2. **Finished** — sessions whose PR is `gone`, or that ended cleanly and
   are just holding a broker. The lane you clear to reduce noise.
3. **Human reviews** — one row per PR, priority-ordered.
4. **Grouped** — bot/dependabot PRs folded by repo (§4.2).
5. **Idle** — human requests with no session yet.

Bot requests do **not** appear here even before dispatch: they fold into
`Grouped` whether or not a session exists yet. Rendering forty
un-dispatched dependabot bumps as forty Idle rows would reproduce the
flood faithfully on the screen built to remove it. Measured against a
live feed while implementing: 44 ungrouped rows became 18 human plus 16
folded services.

Rationale for `Finished` at position 2 rather than last: it is the
cheapest lane to clear, clearing it is what reduces the noise being
complained about, and burying it at the bottom means it never gets
cleared.

### 4.2 Grouping

A group is **(author-kind = bot) × repo**. Dependabot bumps on one
service are the motivating case, but the rule is not dependabot-specific:
any bot flooding one repo groups the same way.

A group renders as one foldable row:

```
▸ listing-performance-service          5 bumps   ⧗2 ✓3
```

Expanded, its members are ordinary rows. Collapsed is the default,
because the point is to stop five things demanding attention as five
things.

Human PRs are never grouped. They are individually authored, individually
argued with, and folding them would hide exactly the reviews that most
need reading.

### 4.3 Row anatomy

```
<mark> <status> <priority> <repo>#<num> <title…> <session> <age>
```

- `mark` — `*` when marked, space otherwise.
- `status` — the §2 staleness badge (`⊘` `↻` `☑`) plus attention glyphs.
- `priority` — the numeric score, shown because an ordering you cannot
  interrogate is one you cannot trust. `help-echo` carries the breakdown
  from `decknix--hub-review-priority-explain`.
- `session` — live / none / detached, and its broker state.

### 4.4 Ordering

Within a lane, by priority descending, ties by activity — the same
function the sidebar Requests section uses, so the two surfaces cannot
disagree. A group sorts by its **highest-priority member**, so one urgent
bump lifts its group rather than being buried inside it.

## 5. Verbs

The board's reason to exist is acting on several things at once.

### 5.1 Marking

| Key | Action |
|-----|--------|
| `m` | mark row (or whole group at a group row) |
| `u` | unmark |
| `U` | unmark all |
| `M` | mark every row in the current lane |
| `t` | toggle marks in lane |

### 5.2 Acting

Every action applies to the marked set, or to the row at point when
nothing is marked — the dired convention, because it is already in
everyone's fingers.

| Key | Action |
|-----|--------|
| `d` | dispatch a review session (grouped for a group row) |
| `RET` / `o` | browse the PR |
| `j` | jump to the session buffer |
| `a` | approve (see §6) |
| `s` | ship / merge (see §6) |
| `k` | quit sessions, terminating brokers |
| `D` | detach sessions, leaving agents running |
| `g` | refresh |
| `?` / `.` | transient |
| `q` | bury |

`k` and `D` deliberately mirror `C-c s q` and `C-c s D` so the
quit/detach distinction is learned once.

## 6. Anything that writes to GitHub needs a gate

`a` and `s` post to GitHub across a marked set. That is the one place
this board can do real damage, and batch amplifies it.

Constraints:

- **Confirm with a manifest.** List exactly what will be posted, to
  which PRs, and require explicit confirmation. This mirrors the
  mandatory confirmation gate in the PR review workflow, which exists
  for single PRs; a batch cannot be looser than the single case.
- **Approve individually, never as a batch.** Even for a group, each PR
  gets its own approval, so one bad bump cannot carry the others through
  on a shared verdict.
- **Never merge on a stale row.** A row marked `↻` (author pushed since)
  must be re-checked before it can be shipped; the analysis behind the
  approval is void.
- **Fail partially and say so.** If three of five succeed, report the
  three and leave the two marked.

## 7. Grouped dispatch (the upstream half)

The board organises; this removes work. Specified here because the board
depends on it for the Grouped lane to be non-trivial.

Auto-review batches per hub tick: collect eligible bot PRs, group by
repo, dispatch **one** session per group with its PRs in priority order.

One schema change: `reviewPr` records a single `repo#number`, and a
grouped session covers several. It becomes a list. All three consumers
(`review-status`, `review-identity`, the sidebar badge) read it through
one accessor, so the change is contained — but it must land before, or
with, grouped dispatch, or a grouped session will look like a session for
whichever PR happened to be recorded.

### Ordering within a group

Dependency bumps on one service sometimes must merge in order. The
grouped session receives them ordered and is told to sequence rather than
parallelise. What "correct order" is cannot be decided here — it is a
property of the diffs — so the session decides and reports, rather than
the board guessing.

## 8. Open questions

1. **Does the board replace the sidebar Requests section, or sit beside
   it?** Beside, initially. The sidebar is glanceable and always present;
   the board is a place you go. If the board wins in practice, the
   sidebar section can shrink to a count.
2. **Auto-refresh interval.** The DoS board polls. The hub already has a
   file-notify watcher, so this can refresh on hub change instead, which
   is both cheaper and more current. Prefer the watcher.
3. **Should `Finished` auto-clear?** Tempting, and wrong at first: a
   session that ended cleanly may still hold context worth reading. Offer
   `k` on the lane, and revisit once it is clear whether anyone reads
   them.
4. **Non-dependabot bots.** `author_kind` is already `bot` for several
   authors. Grouping by repo works for all of them, but the ship command
   is dependabot-shaped. Grouped dispatch should refuse to group across
   *different* bot authors in one repo until that is understood.
5. **How does a group behave when its session dies?** Five PRs, one
   broker, one crash. Probably: the group reverts to Idle and can be
   re-dispatched whole. Needs deciding before grouped dispatch ships.

## 9. Sequencing

1. `reviewPr` becomes a list (schema, contained, no behaviour change) ✅ landed
2. Grouped dispatch in auto-review (removes the volume) ✅ landed
3. Board: lanes, rows, ordering, navigation — read-only ✅ landed
4. Marks and the non-writing verbs (`d`, `j`, `k`, `D`)
5. Writing verbs (`a`, `s`) behind the §6 gate

Steps 1–2 are worth landing and living with before 3 is built: the
board's shape depends on how much volume is actually left once bot
reviews arrive pre-grouped, and building the board first risks designing
lanes around a problem that step 2 removes.

Step 5 is deliberately last and separable. Everything before it is
recoverable; it is not.
