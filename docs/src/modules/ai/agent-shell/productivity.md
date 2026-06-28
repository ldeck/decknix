# Productivity (Layer 3)

Layer 3 provides the tools for structured, repeatable interactions with the AI agent.

## Compose Buffer (`C-c e`)

A magit-style multi-line editor for writing prompts. Opens at the bottom of the frame:

```
┌─────────────────────────────────────────────┐
│  *agent-shell*<my-session>                  │
│                                             │
│  ... conversation ...                       │
│                                             │
├─────────────────────────────────────────────┤
│  Compose prompt → C-c C-c submit, C-c C-k  │
│                                             │
│  Please refactor the UnrecoverableError     │
│  handler to support a new category:         │
│                                             │
│  - Add `TransientNetworkError` subclass     │
│  - Wire it into the metrics recorder        │
│  - Update the Terraform alert definitions   │
│                                             │
└─────────────────────────────────────────────┘
```

- `C-c C-c` — submit the composed text to the agent
- `C-c C-k` — cancel and close the compose buffer
- `C-c C-s` — toggle sticky (stays open after submit) vs transient (closes after submit)
- `C-c k k` — interrupt the agent, `C-c k C-c` — interrupt and submit
- Full text-mode editing: `RET` for newlines, no accidental submissions

### Prompt History (`M-p` / `M-n`)

The compose buffer supports prompt history across all sessions — cycle through previously sent prompts:

| Key | Action |
|-----|--------|
| `M-p` | Previous prompt (older) |
| `M-n` | Next prompt (newer) |
| `M-r` | Search all prompts (consult fuzzy match) |

History is loaded lazily from auggie session files — `M-p` starts with the current session, then progressively loads older sessions as you keep pressing. `M-r` provides a full fuzzy search across all sessions using [consult](https://github.com/minad/consult).

Your current input is saved when you start navigating and restored when you cycle past the newest entry.

## Yasnippet Prompt Templates (`C-c t t`)

Seven built-in templates with interactive fields:

| Template | Key | Purpose |
|----------|-----|---------|
| `/review` | `C-c t t` → review | Code review with focus selector (bugs, performance, security, readability) |
| `/refactor` | `C-c t t` → refactor | Refactoring with pattern selector (extract, rename, DRY up, etc.) |
| `/test` | `C-c t t` → test | Test generation covering happy path, edge cases, errors |
| `/explain` | `C-c t t` → explain | Code explanation with aspect focus |
| `/fix` | `C-c t t` → fix | Bug fix with stack trace placeholder |
| `/implement` | `C-c t t` → implement | Feature implementation following existing patterns |
| `/debug` | `C-c t t` → debug | Debugging with logs and steps-taken fields |

Templates auto-populate the current file from the source buffer. TAB advances between fields; `yas-choose-value` provides dropdown selectors.

### Creating Templates

- `C-c t n` — create a new yasnippet template
- `C-c t e` — edit an existing template

Templates are stored in `~/.emacs.d/snippets/agent-shell-mode/`.

## Custom Slash Commands (`C-c c c`)

Slash commands are markdown files with YAML frontmatter, deployed to `~/.claude/commands/` (the shared location read by both Claude Code and Auggie) and fanned out to `~/.pi/agent/prompts/` so Pi picks them up as `/name` prompt templates too:

```markdown
---
description: Create a new session from a Jira ticket key
argument-hint: [session name or JIRA-KEY]
---

Create a new Augment session and rename it in one step.
...
```

### Built-in Commands

| Command | Description |
|---------|-------------|
| `/start` | Create a new session from a Jira ticket key or plain name |
| `/find-session` | Search all saved sessions by keyword (up to 500) |
| `/pivot-conversation` | Hard pivot — discard current plan, re-evaluate |
| `/step-back` | Stop, summarise progress, wait for direction |

### Command Discovery

The picker (`C-c c c`) **scopes discovery to the agent the current session is running as**: a Claude/Auggie session lists `~/.claude/commands/` (plus project-level `.claude/commands/` and the legacy `~/.augment/commands/` during the transition), while a Pi session lists `~/.pi/agent/prompts/`. Invoked outside an agent session, it falls back to scanning the union so everything is still discoverable. Duplicates collapse (preferring the canonical global copy), and each command shows its scope and description:

```
Command:
  /start           (global)  Create a new session from a Jira ticket key
  /find-session    (global)  Search all saved sessions by keyword
  /pivot-conversation (global)  Hard pivot — discard current plan
  /deploy-check    (project) Verify deployment prerequisites
```

### Nix-Managed vs Runtime Commands

Nix-managed commands are deployed as **symlinks**. User-created commands are **regular files**. On `decknix switch`, Nix refreshes its symlinks; runtime-created commands persist untouched.

## Session Tagging (`C-c T`)

Tag sessions with freeform labels for organisation:

| Key | Action |
|-----|--------|
| `C-c T t` | Add a tag (with completion from existing tags) |
| `C-c T r` | Remove a tag |
| `C-c T l` | Filter sessions by tag → resume picker |
| `C-c T e` | Rename a tag across all sessions |
| `C-c T d` | Delete a tag globally |
| `C-c T c` | Cleanup orphaned tags (sessions that no longer exist) |

Tags are stored in `~/.config/decknix/agent-sessions.json`, keyed by auggie session ID. The session picker shows tags inline:

```
[saved] a1b2c3d4  2h ago  12x  Fix pubsub timeout... [proptrack, bug]
```

## Quick Actions

### PR Review (`C-c c r` / `C-c A c r`)

Start a code review session for a GitHub PR:

1. Prompts for PR URL (auto-detects from clipboard)
2. Creates a named session: `Review: owner/repo#123`
3. Tags the session with `review` and sends `/review-service-pr <url>`

### Batch Process (`C-c c B` / `C-c A c B`)

Launch multiple sessions from a single editor — ideal for batch code reviews or parallel investigations:

```
┌─────────────────────────────────────────────┐
│  Batch: C-c C-c submit | C-c C-k cancel    │
│                                             │
│  # Batch session launcher — workspace: ~/.. │
│  --- backend : ~/Code/my-project            │
│  https://github.com/org/api/pull/42         │
│  https://github.com/org/api/pull/43         │
│                                             │
│  --- frontend                               │
│  https://github.com/org/web/pull/17         │
│                                             │
└─────────────────────────────────────────────┘
```

**Syntax:**
- `--- <name> [: <workspace>]` — group header (items below launch as one session)
- Ungrouped URLs — each gets its own session
- `#` lines — comments, ignored

**Snippets** (via yasnippet in batch compose mode):
| Key | Snippet | Description |
|-----|---------|-------------|
| `---` | Group header | `--- <name> : <workspace>` with tab stops |
| `pr` | PR URL | Generic `github.com/<owner>/<repo>/pull/<number>` |

Org-specific snippets (e.g., pre-filled workspace paths) can be added via downstream `decknix-config`.

`C-c C-c` parses the buffer and launches all sessions. A summary buffer shows success/failure for each.

## Auto-Review (`T` → Requests → `A`)

Automatically dispatch a review session when a PR review request that
**@-mentions you** arrives in the hub Requests section — so a verdict is
waiting by the time you switch to it.

Cycle the mode from the sidebar Toggles transient (`T` → Requests → `A`):

| State | Behaviour |
|-------|-----------|
| `off` | Disabled (default). |
| `bot+@` | Auto-review bot-authored PRs that @-mention you, via `/review-and-ship-bot-pr`. |
| `human+@` | Auto-review human-authored PRs that @-mention you, via the background `/review-service-pr-factory`. |
| `any+@` | Both — bots ship, humans get the background review. |

Every active state requires the @-mention: this is a deliberate safety
guard so team-noise PRs (where you are not directly addressed) never spawn
a session. Human reviews run as a background factory session whose verdict
surfaces through the attention indicator (`AS:n/m`, jump with `C-c j`).

**Incoming-only:** turning the toggle on seeds the current backlog as
already-handled, so only genuinely *new* mentioned PRs dispatch — enabling
it never floods you with sessions for the existing queue. A live-session
guard plus a per-PR dedup set prevent double-dispatch.

**Per-workspace commands:** override the slash command per repository
workspace via `decknix-auto-review-commands` (an alist of
`(workspace . (:review CMD :ship CMD))`); the global defaults are
`decknix-auto-review-default-review-command` and
`decknix-auto-review-default-ship-command`.

## Focus Steal (`T` → Global → `g`, default off)

Off by default, Emacs never steals window focus. Opt in to have the frame
raise itself to the foreground when work needs your attention — handy when
agent sessions run in the background behind other apps.

Cycle the mode from the sidebar Toggles transient (`T` → Global → `g`, or
the footer `focus` label):

| State | Behaviour |
|-------|-----------|
| `off` | Never raise the frame (default). |
| `attention` | Raise the frame when a backgrounded session enters a waiting / needs-input state. |
| `both` | Also raise the frame when a new session is created (e.g. an auto-review dispatch). |

The attention raise is edge-triggered (once per transition into waiting)
and skipped when you are already viewing that session. On the background
Emacs daemon an `osascript … activate` is issued so macOS actually brings
the app forward.

**Navigation:** `C-c A o` jumps to the sidebar window from anywhere;
`C-c A j` jumps the other way, to the next session needing input. These
cover session↔sidebar movement whether or not focus-steal is enabled.

## Priority View (`C-c A p`, opt-in)

A ranked, lane-based "what should I do next?" view over the hub's existing
data, shown in a standalone read-only `*Agent Priority*` buffer. Off by
default; enable it with
`programs.emacs.decknix.agentShell.hub.priority.enable = true` to bind
`C-c A p`.

Four ordered lanes, highest-leverage first:

| Lane | What it surfaces |
|------|------------------|
| **Discussions** | PRs where a human is awaiting *your reply* (highest priority). |
| **Reviews** | PRs awaiting *your review verdict*. |
| **Tasks** | Your non-done Jira issues. |
| **Queue** | Your open WIP PRs flowing through the pipeline. |

Within each lane, items you were directly @-mentioned on rank first, then
oldest first. In the buffer: `RET` opens the item, `g` refreshes, `q`
quits.

This is phase 1 (existing sources only). A sidebar live-view mode, pin /
exclude support, and generic GitHub Actions pipeline enrichment of the
Queue lane are tracked in issues #142 and #141.

## Formatting Output

The agent emits raw markdown, which the comint buffer shows literally —
collapsed tables and `**bold**` / `### head` / `[t](u)` syntax that pastes
badly into Slack and other tools. Three complementary tools address this.

### Auto-aligned Tables (default on)

Tables in agent-shell output are automatically aligned via **display
overlays** — the columns line up visually while the underlying buffer
text stays raw markdown, so `M-w` and **Copy Region As…** still see the
original. When an aligned table would be wider than the window it reflows
into the bullet list shown below instead. The same overlay is enabled in
inline-review buffers. Disable with
`programs.emacs.decknix.agentShell.tableOverlay.enable = false;` to fall
back to the on-demand command only.

### Reformat Table (`C-c x` → `t`)

Re-aligns the GFM table at point (or in the active region) so the pipes
line up:

```
| Name  | Age | City |
| ----- | --- | ---- |
| Alice | 30  | NYC  |
```

When the aligned table would be wider than the window, it reflows into a
per-row bullet list with key/value sub-items instead — readable even in a
narrow sidebar:

```
• Alice
    - Age: 30
    - City: NYC
```

### Copy Region As… (`C-c x`)

Select a region, then `C-c x` opens a transient that converts it and puts
the result on the kill-ring in the chosen syntax:

| Key | Format | Notes |
|-----|--------|-------|
| `m` | Markdown | tables re-aligned, prose untouched |
| `s` | Slack mrkdwn | `*bold*`, `_italic_`, `~strike~`, `<url\|text>`, headings → bold line, `&`/`<`/`>` escaped, tables → aligned code block |
| `h` | HTML | via `pandoc` (GFM → HTML) |
| `p` | Plain text | emphasis stripped, links → `text (url)`, tables aligned |

It also has an **Export region to file** entry that writes a file rather
than copying to the kill-ring:

| Key | Format | Notes |
|-----|--------|-------|
| `P` | PDF | via `pandoc`; prompts for a path, then offers to open it |

Both the HTML and PDF paths need `pandoc`, and PDF additionally needs a
PDF engine on `PATH`. decknix installs both by default — `pandoc` plus
`typst` (small, fast, no TeX) — so `C-c x h` / `C-c x P` work out of the
box after `decknix switch`. See the Nix options below to change the
engine or opt out. If no engine is found the command reports which to
install (the auto-detect order is `typst`, `tectonic`, `weasyprint`,
`wkhtmltopdf`, `xelatex`, `pdflatex`) rather than failing silently.

`C-c x` is bound in agent-shell buffers and in markdown / review buffers
(`C-c y` is reserved for yasnippet). The Slack mapping follows
[Slack's mrkdwn spec](https://docs.slack.dev/messaging/formatting-message-text/).

## Nix Options

```nix
programs.emacs.decknix.agentShell = {
  templates.enable = true;  # Yasnippet prompt templates
  commands.enable = true;   # Nix-managed slash commands
  hub.priority.enable = false;  # opt-in Priority view (C-c A p)
  tableOverlay.enable = true;   # auto-align GFM tables via display overlays

  # Copy-as-format / export runtime deps (C-c x h / C-c x P)
  copyRegion.pandoc.enable = true;  # install pandoc (HTML + PDF)
  copyRegion.pdfEngine = "typst";   # "typst"|"tectonic"|"weasyprint"|"wkhtmltopdf"|null
};

programs.emacs.decknix.ui.focus.steal = "off";  # "off" | "attention" | "both"
```

