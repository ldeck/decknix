# Keybindings Reference

All agent-shell keybindings are available in two forms:

- **In-buffer**: `C-c <key>` — short form, only inside agent-shell buffers
- **Global**: `C-c A <key>` — works from any buffer

The `C-c A` prefix is labelled "Agent" in which-key.

## Session Management

| In-buffer | Global | Action |
|-----------|--------|--------|
| `C-c s` | `C-c A s` | Session picker (live + saved + new) |
| `C-c q` | `C-c A q` | Quit session (saves automatically) |
| `C-c h` | `C-c A h` | View history (current session or pick) |
| `C-c H` | `C-c A H` | View history (always pick) |
| `C-c r` | `C-c A r` | Rename buffer |
| — | `C-c A a` | Start / switch to agent |
| — | `C-c A n` | Force new session |
| — | `C-c A k` | Interrupt agent |
| `C-c b` | `C-c A b` | Switch agent buffer (live only) — MRU order, status-coloured |


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
| `r` | Review PR (quick action) |
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
| `C-c M` | `C-c A M` | Pick mode |

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

