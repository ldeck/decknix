# Context viewer navigation — spec (draft)

Navigating a session's conversation history from `C-c s c`: stepping,
searching, jumping by time, and loading long conversations without
paying for the whole transcript up front.

## 1. Why this matters more than it looks

The viewer is currently a convenience. Two pending decisions would make
it **load-bearing**:

- **Reattach** (`#151`) — when Emacs reattaches to a live broker, the
  buffer starts near-empty. History has to come from somewhere.
- **Resume** — prepopulating the buffer from the transcript is what
  makes `agent-shell-chat--label-prompts` misclassify replayed runs as
  blank and strip their ` Me ` badges. Every bug of that shape comes
  from reconstructing a conversation in the buffer.

If the viewer is good enough to be the way you reach history, both paths
can stop prepopulating: fewer bugs, and a faster session start. So this
spec is a prerequisite for that simplification, not a nicety.

## 2. Current state

`context-history/decknix-agent-context-viewer.el`:

| Key | Command | Behaviour |
|-----|---------|-----------|
| `n` / `p` | `next-turn` / `prev-turn` | step by turn |
| `M-<` / `M->` | `goto-first` / `goto-last` | ends |
| `s` | `search` | `consult-line`, else `isearch` |
| `/` | `isearch-forward` | |
| `g` | `refresh` | re-extract and re-render |
| `j` | `jump-source` | back to the shell buffer |
| `q` | `quit-window` | |

Rendering: `─── Turn N / TOTAL ───` separators, `❯ prompt` then response,
with `decknix--context-viewer-turn-points` (a vector of buffer
positions) driving navigation.

So **stepping and in-buffer search already work**. The gaps are
elsewhere.

## 3. Gap matrix

| Need | Today | Gap |
|------|-------|-----|
| Step prompt/response | `n` / `p` | none |
| Search text | `s` (`consult-line`) | searches only what is RENDERED; cannot distinguish a prompt from a response |
| Long conversations | `extract-all-turns` on every open | loads the WHOLE transcript — 2,713 turns / 11,083 lines in the largest observed session — before the window appears |
| Jump by date/time | — | turns carry no timestamp in the render; no jump |
| Relative offset ("3h ago") | — | none |

Timestamps **are** available: every transcript line carries
`"timestamp":"2026-08-26T03:44:35.770Z"`. They are simply not extracted
into the turn records.

## 4. Proposed design

### 4.1 Separate the INDEX from the RENDER

The central move. Two data structures with different costs:

- **Index** — one entry per turn: `(turn-number, timestamp, role,
  first-line-preview)`. No bodies. Cheap to build for the whole
  conversation, and it is what search and time-jump operate on.
- **Window** — the rendered slice, a bounded run of full turns around a
  cursor.

Search over the index rather than the buffer is what lets you find a
turn that is not currently loaded — the thing `consult-line` structurally
cannot do.

### 4.2 Windowed loading

- Open renders the most recent `decknix-context-viewer-window-size`
  turns (default 50), not the whole history.
- Paging past either edge loads the adjacent window.
- Selecting an index entry loads the window containing it.
- `decknix--agent-context-render-window` already exists in the history
  layer; follow it rather than invent a second windowing scheme.

Open cost becomes O(window) for the render plus O(turns) for a
body-less index, instead of O(entire transcript).

### 4.3 Search by kind

`s` searches the index, with prompts and responses distinguishable:

- default: both
- `M-p`: prompts only — "find the thing I asked"
- `M-r`: responses only

Each candidate shows `Turn N · relative-age · preview`. Selecting jumps,
loading a window if needed.

Rationale for prompts-only: when hunting a point in a long conversation
you almost always remember what *you* said, not the agent's wording.

### 4.4 Time navigation

Two forms, one command (`t`):

- **absolute** — `2026-09-01`, `2026-09-01 14:30`
- **relative** — `3h`, `2d`, `45m` (same grammar as `session list
  --since`, which already accepts `7d` / `12h` / `30m`; reuse it rather
  than invent a second)

Jumps to the first turn at or after the instant. Turn separators gain a
relative age (`─── Turn 12 / 2713 · 3h ago ───`) so time is visible while
stepping, not only when jumping.

### 4.5 Keymap additions

| Key | Command | Notes |
|-----|---------|-------|
| `t` | `goto-time` | absolute or relative |
| `M-n` / `M-p` | `next-day` / `prev-day` | coarse stepping |
| `s` | `search` (reworked) | index-based, kind-filtered |
| `<` / `>` | `page-older` / `page-newer` | explicit window paging |

`n`/`p`/`M-<`/`M->`/`g`/`j`/`q` keep their meanings. `/` stays
`isearch-forward` for within-window text.

## 5. Open questions

1. **Index cost at scale — MEASURED, and it needs a cache.** One
   body-less pass over the largest live transcript (`122adc26`, 7,155
   lines, 1,574 user turns) took **228ms** in Python. Elisp `json-parse`
   will not be faster. That is far too slow to run on every viewer open:
   the Emacs AGENTS.md forbids blocking an interactive path, and 228ms is
   a visible stall.

   So the index MUST be cached against the transcript's mtime, and built
   incrementally — a transcript only ever grows, so an existing index can
   be extended from the last byte offset rather than rebuilt. That is a
   design constraint, not an optimisation, and it lands in step 3.
2. **Window size default.** 50 is a guess. Worth tuning once the perf
   numbers exist.
3. **Sub-agent turns.** Claude transcripts carry `isSidechain` entries.
   Include, exclude, or fold them?
4. **Does this replace prepopulation?** The motivating question. Answer
   only after the viewer is genuinely good enough to rely on.

   The case for "yes" got stronger while this spec was being written.
   Measured against the live bridges:

   | provider | `supports-session-resume` | `supports-session-load` |
   |----------|---------------------------|-------------------------|
   | claude-code | `t` | — |
   | pi | `nil` | `t` |

   `decknix--agent-resume-native-p` requires the *resume* capability
   specifically, and says why: "`session/resume` restores context
   without replaying the transcript, so it composes with our buffer
   prepopulation, whereas `session/load` would double-render."  The
   objection is entirely about prepopulation.

   pi is not incapable — it is differently capable.  Its bundle
   declares `agentCapabilities: { loadSession: true }` and only `list`
   under `sessionCapabilities` (hence the `nil` above), and its
   `loadSession` handler calls `restoreSession`, which spawns the CLI
   with `--session <path>`:

   ```js
   static async spawn(params) {
     const args = ["--mode", "rpc", "--no-themes"];
     if (params.sessionPath) args.push("--session", params.sessionPath);
   ```

   That is pi's own restore, so the MODEL gets its context back, not
   just the display.  So the continuation primer on pi is compensating
   for a capability pi has and decknix declines to use.

   Dropping prepopulation therefore resolves four things at once:

   - pi resumes natively via `session/load` (real context)
   - the continuation primer becomes unnecessary on BOTH providers
   - the conv-key collision bucket loses its source — every resumed
     session's first message is that identical primer, which is what
     made a `day6` conversation unfindable
   - the replay-rendering that strips ` Me ` labels stops happening;
     `d9c0390` guards a symptom of it

   **Partly resolved.** The pi half landed ahead of the viewer, because
   it did not actually depend on it. `decknix--agent-resume-native-method`
   now picks `session/resume` or `session/load` from the bridge's
   advertised capabilities, and `decknix--agent-resume-bridge-replays-p`
   makes exactly one side render the transcript — so pi resumes natively
   and its primer is suppressed, with no viewer work required.

   The distinction that unblocked it: dropping prepopulation *because
   the bridge replays it* is local and safe, whereas dropping it *so the
   viewer becomes the only route to history* is the change that still
   needs the viewer to be good enough first. Only the second one is
   gated here.

   Still open, and still gated on the viewer:

   - Claude, which uses `session/resume` (no replay), so our
     prepopulation is the only thing rendering its history.
   - Reattach (`#151`), where a buffer starts near-empty.

   The conv-key collision bucket is fixed for pi (its resumed sessions no
   longer all begin with the identical primer) but remains for Claude.

## 6. Sequencing

1. Timestamps into turn records (unblocks everything else; smallest)
   ✅ landed. Carried as a text property on the turn's user string, NOT as
   a third field: a turn record is a `(USER . RESPONSE)` cons and the
   resume primer, `asking`-flag restore, history extractor and viewer all
   read it that way, so widening the shape would break four consumers for
   a field only the viewer wants. A property is transparent to `string=`,
   preserved by `insert`/`mapconcat`, and dropped harmlessly by
   `substring-no-properties`. The stamp is the time of the line that
   STARTS the turn, since a response accumulates across many later lines.
   Separators now show local time to the minute.

   Claude and pi only. The Auggie JSON path is deliberately unstamped:
   there was no transcript on disk to verify a field name against, and
   guessing one would have been an unverified claim about the format. Its
   turns report nil, which renders exactly as before.
2. Windowed loading (the performance win, and the largest behaviour
   change)
3. Index + search-by-kind
4. Time navigation
5. Decide on prepopulation for resume/reattach

Steps 1–2 are worth landing and living with before 3–4 are designed in
detail; the shape of search depends on how windowing actually feels.
