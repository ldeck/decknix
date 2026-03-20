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

## Input & Editing

| Key | Action |
|-----|--------|
| `C-c e` / `C-c A e` | Compose buffer (multi-line editor) |
| `RET` | Send prompt (at end of input) |
| `S-RET` | Insert newline in prompt |
| `C-c C-c` | Interrupt running agent |
| `TAB` | Expand yasnippet template |

## Templates (`C-c t` / `C-c A t`)

| Key | Action |
|-----|--------|
| `t` | Insert a prompt template |
| `n` | Create new template |
| `e` | Edit existing template |

## Commands (`C-c c` / `C-c A c`)

| Key | Action |
|-----|--------|
| `c` | Pick & insert a slash command |
| `n` | Create new command |
| `e` | Edit existing command |

## Tags (`C-c T` / `C-c A T`)

| Key | Action |
|-----|--------|
| `t` | Tag current session |
| `r` | Remove tag |
| `l` | List / filter by tag |
| `e` | Rename a tag |
| `d` | Delete tag globally |
| `c` | Cleanup orphaned tags |

## Model & Mode

| In-buffer | Global | Action |
|-----------|--------|--------|
| `C-c v` | `C-c A v` | Pick model |
| `C-c M` | `C-c A M` | Pick mode |

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

