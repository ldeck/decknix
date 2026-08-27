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
| `C-c b` | `C-c A b` | Switch agent buffer (live only) — MRU order, status-coloured |

### Network-Failure Recovery

When the link drops, every in-flight session dies the same way at the same
moment: the turn ends having printed one line (`API Error: Unable to connect to
API (ECONNRESET)`) and then *settles*, so without help each one reports a
cheerful `ready` and sits in the sidebar looking like it finished its work.

Sessions in this state report the **`netfail`** status — the `✗` glyph, a red
row, and first place in the picker's attention order — and these keys clear
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

### Global (`C-c A T`)

| Key | Action |
|-----|--------|
| `t` | Tag current session |
| `r` | Remove tag |
| `l` | List / filter by tag |
| `e` | Rename a tag |
| `d` | Delete tag globally |
| `c` | Cleanup orphaned tags |

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
| `C-c j` | `C-c A j` | Jump to session needing attention |
| — | `C-c A S` | MCP server list |

## Help

| In-buffer | Global | Action |
|-----------|--------|--------|
| `C-c ?` | `C-c A ?` | Full keybinding reference (this page, in Emacs) |

