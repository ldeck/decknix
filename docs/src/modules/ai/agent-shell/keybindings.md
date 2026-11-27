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
| `C-c s M-N` | Suppress (or allow again) [auto-resume](./network-resume.md) for one session. |

Sessions are also [resumed automatically](./network-resume.md) once the API host answers again, unless you have typed into them, they are asking you something, or they moved on by themselves. Sidebar toggles `Z` turns that off.

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

## Saved Layout (`C-c D w` / `C-c D W`)

Frames, tabs and windows, including which agent session each window
showed, are saved on exit and every five minutes, and offered back on the
first frame after a daemon restart. `C-c D w` saves now; `C-c D W` restores
and resumes the sessions (`C-u` for the run before the last). See
[Emacs: restoring frames and windows](../../emacs.md#restoring-frames-and-windows-after-a-restart).

## Layouts (`C-c l`)

One prefix for every layout command: named window-layout groups and the
saved whole-frame layout.

| Key | Action |
|-----|--------|
| `C-c l l` | Switch to a named layout group |
| `C-c l s` | Save the current windows as a named layout group |
| `C-c l x` | Delete a named layout group |
| `C-c l w` | Save frames, tabs and windows now (`C-c D w`) |
| `C-c l W` | Restore the saved frames, tabs and windows (`C-c D W`) |

In a buffer managed by eglot, `C-c l` also carries the language-server
keys (`r`, `a`, `f`, `F`, `d`, `i`, `t`, `h`, `k`); the letters do not
overlap, so both sets work there. The older bindings stay:
`C-c s l` / `C-c s L` / `C-c s C-l` outside an agent buffer, and
`C-c A l` / `C-c A L` from anywhere, switch and save groups.

## Balancing windows (`C-x +`)

`C-x +` balances only the main window area: the agent sidebar (a left
side window) keeps its width. Every row and column gets an equal share
even when splits are nested in the same direction, so a 3x2 grid comes
out as six equal windows rather than rows of 1/2, 1/4 and 1/4.
`C-u C-x +` runs plain `balance-windows` on the whole frame.

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

Every session blocked on you (`netfail`, `waiting`, `asking`, or flagged)
has exactly one row, marked `⚑`, in the section that owns it: a review
session under its repo in **Reviews** (collapsed or not), any other session
in **WIP**. A review session whose PR has since merged or closed is still
listed, its repo kept visible, dimmed and marked `PR gone`: it is still
waiting on a prompt, though the answer is usually to close it. Under its
repo a review session is named by what the repo does not already say:
`auto/#22261/widget/review` reads `#22261  ask 1h`, with the full name on
hover. Statuses are compact (`ask 1h`, `wait`, `work`, `ready`) and keep
their width; a long name is truncated instead. Under each,
one dimmed line says what it is asking: the permission it wants, or the
question its last turn ended on, followed by the reply it expects (`reply
1-3, rec 1`, `reply yes/edit/cancel`, `reply yes/no`) when `y` or a digit
can send it. The header line opens with the count (`⚑2 need you`), and `j`
visits them in order: `netfail`, `waiting`, `asking`, then the longest
wait.

**WIP** is grouped. When sessions run from more than one workspace, each
workspace gets a collapsible heading. Within a workspace come coordinators,
each with the lane sessions it drives nested beneath it, then individual
sessions, then (only with the `0` toggle) review sessions. A lane belongs to
the coordinator that sent it the last message delivered through `decknix
session send`; with no delivery since Emacs started, a session tagged
`lane-NN` goes under the one coordinator in its workspace that shares most
of its other tags, and is marked `~` as a guess. `TAB` on a coordinator
collapses its lanes (`RET` still goes to it); `TAB` or `RET` on a heading
collapses that group. A collapsed group still lists any session in it that
is blocked on you.

The row of the session shown in the selected window is highlighted
(`decknix-sidebar-active-session`, inheriting `hl-line`). Selecting the
sidebar keeps the mark on the session you came from. Turn it off with
`decknix-sidebar-highlight-active-session`.

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
| `TAB` | Expand or collapse the Reviews group, WIP group or coordinator's lanes, or held items, at point |
| `A` | Reviews: only what wants you, or everything |
| `K` | Sub-agents: only running and active ones (default), or finished ones too. Hidden, a session whose sub-agents have all finished takes no row |
| `F` | Focus the sidebar on one [board](./boards.md#sidebar-focus) (a pilot, a hackathon): only its sessions, PRs, worktrees and repos. `F` again clears it, `C-u F` switches board. A dim `+N need you elsewhere` row counts what the focus hides. Survives restarts |
| `N` | New session for the repo, worktree or PR at point |
| `G` | Repo-sync action for the row at point |
| `T` | Toggles |
| `?` / `h` | Every sidebar key |
| `L` | Glyph and colour legend |

## Session URLs

Every agent-shell buffer can reach the links its session is handling without
scrolling. The list puts the session's identity first (the PR it reviews, PRs
linked to the conversation, PRs it created), then every URL in the last 256 KB
of the transcript, most recent first, since the link you want is usually the
one the agent printed last. Bare ticket keys such as `ABC-123` are included
when `decknix-session-urls-jira-base-url` is set, or when a ticket URL in the
transcript shows the base.

| Key | Action |
|-----|--------|
| `C-c s O` | Pick a URL (annotated with its kind, label and where it appeared) and open it; `C-u` opens the action menu instead |
| `C-c s U` | Action menu on the URL at point, or on a picked one |
| `C-c s <` / `C-c s >` | Move to the previous / next URL in the buffer and highlight it. From the prompt, `<` lands on the most recent |

Straight after a move, `n`/`p` (or `<`/`>`) keep cycling, `RET`/`o` opens,
`w` copies, `m` copies as a Markdown link and `a` opens the action menu. Any
other key ends the cycle and does what it normally does.

The action menu offers: open in the browser, eww or xwidget (when this Emacs
has it), copy the URL, copy as a Markdown link, insert into the compose
buffer, and for a PR its files-changed view, its checks and its Review Board
row; `j` opens the ticket, or one the session mentions. In the `C-c s O`
picker, embark's `C-.` acts on a candidate with the same actions.

### Review sessions

`decknix-review-session-mode` switches on by itself in review sessions (any
session with recorded review coordinates), shown in the mode line as
`[review widget#460 ...]`. Its keys come in two tiers:

| Chord (anywhere) | Letter (transcript only) | Action |
|------------------|--------------------------|--------|
| `C-c C-j` | `o` | Open the reviewed PR |
| `C-c C-f` | `f` | Its files-changed view |
| `C-c C-k` | `k` | Its checks |
| `C-c C-b` | `b` | Its Review Board row |
| `C-c C-y` | `w` | Copy its URL |
| `C-c C-q` | `y` / `1`-`9` | Answer the session like the board does; always confirms first |
| `C-c s <` / `>` | `<` / `>` | Previous / next URL |
| `C-c s O` | `u` | Pick a URL and open it |
| `C-c s U` | `a` | Act on a URL |
| | `?` | Menu of all of the above |

The letters only act when point is in the transcript; at the prompt they
insert themselves, the same rule agent-shell's own `n`/`p` follow, so typing
is never affected. They avoid every key agent-shell binds there. `C-c C-p` is
comint's previous prompt, hence `C-c C-j` for open.

## Review Board Keys

`C-c s B` opens the Review Board: every live review session and every
review request, in lanes. Each session row leads with where its review is
in `/review-service-pr`, which assesses the PR, stops at a confirmation
gate, then posts once you answer.

The header is two lines: counts and policies, then the daily keys. The
column labels are pinned in the header line.

```
Review Board  27 rows  ⚑ 2 need you  1 stalled   filtered · auto-review [any] · re-review [notify] · auto-dismiss [off]
  RET open  v view  i inspect  j jump  y/1-9 answer, nudge or resume  d dispatch  k quit  s merge  R re-review  g refresh  ? all keys
m st s   pri  pr                       title                author      age/quiet c me thr    phase
Needs you (2)  asked you, or lost its link: answer or y
     ✖    35  widget-service#410       Bump the spring gro… dependabot⚙ 2d/40m    ✓    b1     crashed  y resets and resumes
     ⚑    50  web-app#22335            ABC-123: Define eac… jo          1d/2h     ✓ C  h1     awaiting you  APPROVE · reply 1-3, rec 1
Stalled (1)  stopped short of the gate without asking: y nudges it
     ⚑    -5  api-gateway#1041         chore(deps): bump n… dependabot⚙ 4d/3h     ✓             stalled  y nudges it on
Waiting on others (1)  PR in draft, or handed to another reviewer
☑    →   -25  billing-integration#399  Bump the actions gr… dependabot⚙ 6d/1d     ✓             handed off  approved by sam
Posted (1)  your review is on GitHub
     ✓    21  task-tools#27            feat(tasks): tasks_… ana         3d/1h     ✓ A           posted
Obsolete (2)  PR merged or closed: safe to quit
⊘    ⚑     0  infra-prd#360            Promote api to prd   ana         5d/2h     ·             merged  asking  moot
⊘    ●     0  web-app#22324            Fix the importer     jo          8d/6h     ·             closed  stalled  moot
```

| Lane | Holds |
|------|-------|
| Needs you | Sessions that asked you something, or crashed on the network |
| Re-review | PRs the author pushed to after the review |
| Stalled | Sessions that stopped short of the gate without asking: `y` nudges them on |
| In progress | Assessing, revising, or posting your answer |
| Waiting on others | PR back in draft, or the review handed to another reviewer (the session said so, or someone else approved and you have not reviewed) |
| Posted | Your review is on GitHub. Most recent first |
| Obsolete | PR merged or closed: `k` the session. Most recent first; the row says `merged` or `closed` (asked of GitHub once per PR in the background, kept in `~/.local/state/decknix/review-board-prs.eld` with the PR's title and author), and a question the session was asking reads `moot` |
| Grouped / Idle | Requests nobody is on yet: bot PRs folded per service, human ones listed |

| Glyph | Phase | Meaning |
|-------|-------|---------|
| `✖` (red) | crashed | The session's last message is a network failure (a first prompt that failed on `ENOTFOUND` included). Needs you; `y` resets it and sends `continue` |
| `⚑` (amber) | awaiting you | The plan is presented. The row shows the verdict and the reply wanted, e.g. `APPROVE · reply 1-3, rec 1` |
| `⚑` (amber) | asking / permission | Blocked on you for anything else |
| `⚑` (amber) | stalled | Stopped without posting or asking anything. Filed under Stalled |
| `◐` | assessing | Reading the PR; you have not answered it yet |
| `◐` | revising | Changing the plan after you asked for an edit |
| `◑` | posting | Acting on your go-ahead, with the verdict being posted |
| `●` | actioned | Settled after your go-ahead without reporting a review link (a failed submit looks like this); `i` to see |
| `✓` (green) | posted | The review is on GitHub (the session linked it, or the feed has your review). Filed under Posted |
| `→` (grey) | handed off | Another reviewer has it. Filed under Waiting on others |
| `⚑` (amber) | updated | The author pushed after the review. Filed under Re-review, with what changed (see below) |
| `●` (grey) | idle | Closing or watching, nothing in flight |

Colours are the sidebar's (its severity face function): red failed, amber
waiting on you, plain in flight, green done, grey quiet.

| Column | Shows |
|--------|-------|
| `st` | Staleness badge: `⊘` gone, `↻` stale, `☑` answered by someone else |
| `pri` | Priority; hover the row for its breakdown |
| `author` | Short login, `⚙` for a bot |
| `age/quiet` | How old the PR is / how long since anything moved |
| `c` | CI: `✓` pass, `✗` fail, `◐` running |
| `me` | My prior review: `A` approved, `CR` changes requested, `C` commented |
| `thr` | Open threads: `hN` human, `bN` bot |

The title column takes the width left in the window.

| Key | Action |
|-----|--------|
| `n` / `p`, `TAB` | Next / previous row |
| `RET` / `o` | Open the PR in the browser |
| `v` | View the PR in `*PR Review: repo#N*` (see below) |
| `i` | Inspect: the session's state, phase and last lines, or the PR detail |
| `j` | Go to the session |
| `y` | On a crashed session: reset it and send `continue`. On a stalled one: send `decknix-review-board-nudge-prompt` (finish, present the plan, stop at the gate). Otherwise send "yes" when it asks yes/no or `(yes / edit / cancel)`. Always confirms first |
| `1`-`9` | Send that number to the session at point, when it offers a numbered choice. Confirms first, naming the option and the verdict at stake; refused when out of range |
| `m` / `u` / `U` / `M` | Mark, unmark, unmark all, mark the lane |
| `d` | Dispatch review sessions for the marked rows |
| `k` / `D` | Quit (terminating the broker) or detach the marked sessions |
| `s` | Merge via `/merge-train`, behind a manifest (`C-u s` dry run) |
| `r` | Review PR url(s) pasted from anywhere |
| `R` | Re-review a PR updated since the review (`C-u R` acknowledges the push instead) |
| `X` | Cycle what an update does: off / notify / auto |
| `A` / `x` / `f` | Cycle auto-review, toggle auto-dismiss (drops Obsolete rows), toggle filters |
| `g` / `?` | Refresh / full help |

### Reading and editing a review in Emacs (`v`)

`v` opens `*PR Review: repo#N*` for the row's PR: its summary, the agent's
staged plan, the description, CI (failures first), the reviews so far, and
every review thread grouped by file, open ones first and with their whole
conversation. Threads are fetched page by page, so a large PR is never cut
short. The plan is the one `/review-service-pr` saved at
`~/.local/state/decknix/reviews/<owner>/<repo>/<n>/plan.json` (verdict,
body, inline comments, bot reactions), when there is one.

Every `gh` call runs in the background: the buffer opens at once and each
section fills in.

| Key | Action |
|-----|--------|
| `n` / `p` | Next / previous review thread |
| `RET` | Open the thread at point on GitHub |
| `o` | Open the PR on GitHub |
| `v` | Cycle the staged plan's verdict (`APPROVE` -> `COMMENT` -> `REQUEST_CHANGES`) and sync canonical `LGTM + N inline comments` body |
| `e` | Edit the inline comment at point, or the review body when not on an inline comment |
| `a` | Add a new inline comment (`path:line` and body) to `plan.json` |
| `k` / `d` | Delete the staged inline comment at point |
| `V` | Open the interactive HTML review workbench (`canvas.html`: Before/After What/Why walkthrough, inline comments, and threads) |
| `C-c C-c` | Submit the staged review plan via `pr-review-execute` |
| `C-c C-k` | Cancel the staged review, optionally discard `plan.json`, and close the view |
| `g` / `q` | Refresh / quit window |

From a review session, `C-c C-b` (or `b` in its transcript) comes back to its
row here.

### Re-review after the author updates the PR

When you reviewed a PR with feedback (changes requested, a comment, a body,
or a thread you opened) and the author answers by pushing to the same PR,
the row leaves Posted for the **Re-review** lane, second from the top.
The same happens when another reviewer's feedback was what your finished
session was waiting on. The row says what moved: commits since the review,
files changed, how many of your threads are resolved or replied to, whether
the push dismissed your approval, and how long ago. `i` lists the commits.

Pushes that change nothing are not updates: a merge of the base branch, or
a rebase that leaves the PR's own diff identical
(`decknix-review-board-rereview-ignore-base-merges`,
`decknix-review-board-rereview-ignore-rebases`). Neither is a push made
only of your own commits. A bare approval does not count unless
`decknix-review-board-rereview-bare-approvals` is set; a dismissed one
always does.

`R` refreshes the PR's review worktree to the new head and asks the review
session (the live one, else the saved one resumed, else a new review) to
review only the changes since the reviewed commit, check whether the
feedback was addressed, and stop at the confirmation gate as before. It
never posts on its own. Each head is re-reviewed at most once.

`decknix-review-board-auto-rereview` (`X` cycles it) decides what an update
does without you: `nil` shows it on the board only; `notify` (the default)
also says so once per head and flags the session in the sidebar, `C-c A j` and the mode-line count; `auto` also starts the
re-review, as `R` would. The detail comes from the hub's reviews feed, so
nothing is fetched while the board paints.

The reply keys act on the row at point only, never the marked set: one key
answering several gates would post several reviews. The board also
repaints itself a second after any session's turn ends or starts, so a
review reaching its gate moves to Needs you without waiting for the
reviews feed.

## Coordination Boards (`C-c s H`)

`C-c s H` opens a board (`C-u C-c s H`, or no boards yet: define one). See
[Coordination Boards](./boards.md).

| Key | Action |
|-----|--------|
| `n` / `p`, `TAB` | Next / previous row; fold the item |
| `RET` / `o` | Go to the item's session, else open the item / always open it |
| `N` | New session for the item, tagged `REPO#N` and briefed |
| `j` / `b` | Go to the item's session / message its sessions (`C-u b`: all) |
| `c` | Create a child issue (confirms first) |
| `s` | Draft a Slack update; `C-c C-c` sends after confirming |
| `g` / `e` / `?` | Refresh / edit definition / every key |

`RET` or `o` on a row of the board's **Open PRs** section opens that PR.

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
| `C-c j` | `C-c A j` | Jump to the next session that needs you: `netfail`, then `waiting`, then `asking`, oldest wait first. Repeat to walk the queue; `C-u` to choose. Selects the tab already showing the session. Global even when the sidebar is focused on a board, unless `decknix-attention-respect-focus` is set; `C-u C-u` inverts that for one jump |
| — | `C-c A S` | MCP server list |

## Help

| In-buffer | Global | Action |
|-----------|--------|--------|
| `C-c ?` | `C-c A ?` | Full keybinding reference (this page, in Emacs) |

