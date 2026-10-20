# Keybindings Reference

All agent-shell keybindings are available in two forms:

- **In-buffer**: `C-c <key>` — short form, only inside agent-shell buffers
- **Global**: `C-c A <key>` — works from any buffer

The `C-c A` prefix is labelled "Agent" in which-key.

## Session Management

| In-buffer | Global | Action |
|-----------|--------|--------|
| `C-c s` | `C-c A s` | Session picker (live + saved + new) |
| — | `C-c A g` | Grep sessions (full-text search across all history) |
| `C-c q` | `C-c A q` | Quit session (saves automatically) |
| `C-c h` | `C-c A h` | View history (current session or pick) |
| `C-c H` | `C-c A H` | View history (always pick) |
| `C-c r` | `C-c A r` | Rename buffer |
| — | `C-c A a` | Start / switch to agent |
| — | `C-c A n` | Force new session |
| — | `C-c A k` | Interrupt agent |
| `C-c b` | `C-c A b` | Switch agent buffer (live only): sessions that need you first (⚑, in jump order), then the rest as before, each with the sidebar's state glyph and colour |

### Network-Failure Recovery

When the link drops, every in-flight session dies the same way at the same
moment: the turn ends having printed one line (`API Error: Unable to connect to
API (ECONNRESET)`) and then *settles*, so without help each one reports a
cheerful `ready` and sits in the sidebar looking like it finished its work.

Sessions in this state report the **`netfail`** status — the `✗` glyph in the
picker, the shared needs-you `⚑` in the sidebar, and first place in both
attention orders — and these keys clear
them all in one action rather than one at a time:

| Key | Action |
|-----|--------|
| `C-c s N` | Reset every stranded session **and** send each a `continue`. Run this once the link is back. `C-u` widens it to every live session, for a failure whose evidence has already scrolled away. |
| `C-c s C-n` | Reset only — clears the flag and the stuck turn state without re-prompting, for when you would rather steer the sessions yourself. |
| `C-c s M-n` | List which sessions died, and on what. |

Both bulk commands **rescan before acting**, so a session that recovered on its
own is never re-prompted, and idle sessions are prompted immediately while busy
ones are queued — a returning link is not saturated by every session at once.

Detection deliberately refuses to flag an agent that merely *discusses* a
network error (the retry sends a prompt, so a false positive would interrupt
healthy work): the line must be a reported error, carrying a transient fault
(errno, socket/fetch failure, or 408/429/5xx — never a 401 or 400), and the turn
must have ended on it. Extend
`decknix-agent-net-error-transient-regexp` for an agent whose wording differs.

### In-Picker Keys

Every session-facing picker (`C-c A s`, `C-c A b`, `C-c A g`) prefixes
each row with a **provider glyph** — `A` Auggie, `C` Claude, `P` Pi —
and shares a set of picker-local action keys:

| Key | Action |
|-----|--------|
| `M-a` / `M-c` / `M-p` | Toggle visibility of Auggie / Claude / Pi rows (filter is shared across all three pickers; not persisted) |
| `M-w` | Toggle workspace filter (all workspaces ↔ the calling buffer's workspace); active filter shows in the prompt as `[~/path/to/ws]` |
| `C-SPC` | Mark row for batch action |
| `C-k` | Kill highlighted live session buffer(s) |
| `C-d` | Delete saved / previous session from disk and metadata |
| `C-u` | Expand (per-picker; e.g. `C-u C-c A s` shows every saved snapshot instead of one-per-conversation) |


## Input & Editing

| Key | Action |
|-----|--------|
| `C-c e` / `C-c A e` | Compose buffer (multi-line editor) |
| `RET` | Send prompt (at end of input) |
| `S-RET` | Insert newline in prompt |
| `C-c C-c` | Interrupt running agent |
| `C-c E` | Interrupt agent and open compose buffer |
| `TAB` | Expand yasnippet template |

### In Compose Buffer

| Key | Action |
|-----|--------|
| `C-c C-c` | Submit composed prompt |
| `C-c C-k` | Cancel / close compose buffer |
| `C-c C-s` | Toggle sticky (stays open) vs transient |
| `C-c k k` | Interrupt agent |
| `C-c k C-c` | Interrupt agent and submit |
| `M-p` | Previous prompt (history) |
| `M-n` | Next prompt (history) |
| `M-r` | Search prompt history (consult) |

## Templates (`C-c Y` / `C-c A t`)

In-buffer, snippet insertion is handled by the upstream `C-c Y` ("+snippet")
prefix — no decknix-specific in-buffer binding. The agent-namespaced
`C-c A t` global prefix is preserved for explicit, namespaced access.

| Key | Action |
|-----|--------|
| `C-c Y` | Snippet prefix (upstream) — insert / new / visit |
| `C-c A t t` | Insert a prompt template |
| `C-c A t n` | Create new template |
| `C-c A t e` | Edit existing template |

## Commands (`C-c c` / `C-c A c`)

| Key | Action |
|-----|--------|
| `c` | Pick & insert a slash command |
| `n` | Create new command |
| `e` | Edit existing command |
| `r` | Review PR by URL (quick action; launches in the `pr-review` purpose's `auto` mode) |
| `B` | Batch process (multi-session launcher) |
| `l` | Link PR to session |
| `L` | Link repo+branch to session (direct-push repos) |
| `u` | Unlink PR or repo (single picker) |

## Tags

Conversation-scoped tags (add / remove / list for this session) are now
nested under the session sub-prefix at `C-c s t`. Global tags
(rename / delete / cleanup across all sessions) remain at `C-c A T`.

### Conversation-scoped (`C-c s t`)

| Key | Action |
|-----|--------|
| `a` | Add tag (create or select) |
| `r` | Remove tag |
| `l` | List this session's tags |
| `s` | Replace this session's tags |
| `R` | Rename a tag on every session (same as `C-c A T e`) |
| `D` | Delete a tag from every session (same as `C-c A T d`) |

### Global (`C-c A T`)

| Key | Action |
|-----|--------|
| `l` | List / filter by tag |
| `e` | Rename a tag (`M-x decknix-agent-tag-rename`) |
| `d` | Delete tag globally (`M-x decknix-agent-tag-delete`) |
| `c` | Cleanup orphaned tags |

Rename and delete pick from the existing tags with a usage count beside
each, say how many conversations they will change, and confirm first.
They cover live and saved sessions in one write, so buffer names and the
sidebar refresh once. Renaming onto a tag that already exists merges the
two. A conversation left with no tags keeps its sessions and workspace.

There is no separate list of known tags: completion is built from the
tags sessions carry, so removing a tag from the last session that has it
removes it from completion as well. `r` says when that happened, or how
many other conversations still carry it.

## Sidebar Actions (`C-c W`)

Trigger sidebar transients without switching focus away from the
agent-shell buffer. `C-c W` opens `decknix-sidebar-transient` — the
same parent menu that the sidebar's `?` / `h` opens — exposing
Navigate / Quick / Actions plus `T` for the toggles sub-transient.

| Key | Action |
|-----|--------|
| `C-c W` | Open sidebar action transient |
| `C-c W T` | Toggles transient (filters, sort, indicators) |
| `C-c w` | Toggle the workspace tab itself (unchanged) |

## Sidebar Keys

Every session blocked on you (`netfail`, `waiting`, `asking`) is listed
first, under **Needs you**, in the order `j` visits them and with how long
each has waited, whichever section it would otherwise sit in. A review
session whose PR has since merged or closed is still listed, dimmed and
marked `PR gone`: it is still waiting on a prompt, though the answer is
usually to close it. Under each, one dimmed line says what it is asking: the
permission it wants, or the question its last turn ended on, followed by the
reply it expects (`reply 1-3, rec 1`, `reply yes/edit/cancel`, `reply
yes/no`) when `y` or a digit can send it. The header line opens with the
same count.

Pressed inside the Agents sidebar itself. The header line names the few
keys that do most of the work, dropping hints from the right as the sidebar
narrows; `?` is always the last to go, and opens the full reference.

| Key | Action |
|-----|--------|
| `j` | Move to the next session that needs you (`netfail`, then `waiting`, then `asking`, then the longest wait); again for the one after |
| `J` | Go straight to that session |
| `i` | What the session at point is asking: its state and wait, the question, its whole last message and the tail of the session. `RET` there goes to it |
| `y` | Answer the session at point "yes", when it asks yes/no or offers yes among its words. Always asks first, naming the session and the exact text |
| `1`-`9` | Send that option's number to the session at point, when its question ends in a numbered list (`CHOOSE ONE`). Confirms first, showing the option; refused when the list has no such number |
| `n` / `p` | Next / previous row that has an action, skipping headers and counts |
| `o` | Restore a previous session (was `p`) |
| `RET` | Session rows: go to the session. Reviews PR rows: go to the session covering the PR, ask which when several do, or open the PR's action menu when none does |
| `M-RET` | Primary action: open the row's PR in the browser |
| `TAB` | Expand or collapse the Reviews group, or held items, at point |
| `A` | Reviews: only what wants you, or everything |
| `N` | New session for the repo, worktree or PR at point |
| `G` | Repo-sync action for the row at point |
| `T` | Toggles |
| `?` / `h` | Every sidebar key |

## Review Board Keys

`C-c s B` opens the Review Board: every live review session and every
review request, in lanes. Each session row leads with where its review is
in `/review-service-pr`, which assesses the PR, stops at a confirmation
gate, then posts once you answer:

| Glyph | Phase | Meaning |
|-------|-------|---------|
| `⚑` | awaiting you | The plan is presented. The row shows the verdict and the reply wanted, e.g. `APPROVE · reply 1-3, rec 1`. Listed under Needs you |
| `⚑` | asking / permission / netfail | Blocked on you for anything else |
| `◐` | assessing | Reading the PR; you have not answered it yet |
| `◐` | revising | Changing the plan after you asked for an edit |
| `◑` | posting | Acting on your go-ahead, with the verdict being posted |
| `●` | actioned | Settled after your go-ahead without reporting a review link (a failed submit looks like this); `i` to see |
| `✓` | posted | The review is on GitHub (the session linked it, or the feed has your review). Filed under Finished |
| `●` | idle | Settled, nothing in flight |

| Key | Action |
|-----|--------|
| `n` / `p`, `TAB` | Next / previous row |
| `RET` / `o` | Open the PR in the browser |
| `i` | Inspect: the session's state, phase and last lines, or the PR detail |
| `j` | Go to the session |
| `y` | Send "yes" to the session at point, when it asks yes/no or `(yes / edit / cancel)`. Always confirms first |
| `1`-`9` | Send that number to the session at point, when it offers a numbered choice. Confirms first, naming the option and the verdict at stake; refused when out of range |
| `m` / `u` / `U` / `M` | Mark, unmark, unmark all, mark the lane |
| `d` | Dispatch review sessions for the marked rows |
| `k` / `D` | Quit (terminating the broker) or detach the marked sessions |
| `s` | Merge via `/merge-train`, behind a manifest (`C-u s` dry run) |
| `r` | Review PR url(s) pasted from anywhere |
| `A` / `x` / `f` | Cycle auto-review, toggle auto-dismiss, toggle filters |
| `g` / `?` | Refresh / full help |

The reply keys act on the row at point only, never the marked set: one key
answering several gates would post several reviews. The board also
repaints itself a second after any session's turn ends or starts, so a
review reaching its gate moves to Needs you without waiting for the
reviews feed.

## Model & Mode

| In-buffer | Global | Action |
|-----------|--------|--------|
| `C-c C-v` | — | Pick model (persists per-conversation; survives resume) |
| `C-c C-m` | — | Pick permission mode (persists per-conversation; survives resume/fork) |

See [Model Selection](./foundation.md#model-selection) for the
recommended-model-by-task table and the per-purpose
(`programs.emacs.decknix.agentShell.purposes`) / framework
(`decknix.cli.auggie.settings.model`) override levers.

## Context (`C-c i` / `C-c A i`)

| Key | Action |
|-----|--------|
| `i` | List tracked issues |
| `p` | List tracked PRs |
| `c` | Show CI status |
| `r` | Show review threads |
| `a` | Pin issue/PR to context |
| `d` | Unpin from context |
| `g` | Open in browser |
| `f` | Visit in forge |

| In-buffer | Global | Action |
|-----------|--------|--------|
| `C-c I` | `C-c A I` | Full context panel |

## Extensions

| In-buffer | Global | Action |
|-----------|--------|--------|
| `C-c m` | `C-c A m` | Manager dashboard toggle |
| `C-c w` | `C-c A w` | Workspace tab toggle |
| `C-c j` | `C-c A j` | Jump to the next session that needs you: `netfail`, then `waiting`, then `asking`, oldest wait first. Repeat to walk the queue; `C-u` to choose. Selects the tab already showing the session |
| — | `C-c A S` | MCP server list |

## Help

| In-buffer | Global | Action |
|-----------|--------|--------|
| `C-c ?` | `C-c A ?` | Full keybinding reference (this page, in Emacs) |

