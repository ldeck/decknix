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

## Switching Agents / Migrating off Auggie

decknix supports three agent providers — Auggie (`A`), Claude (`C`), and
Pi (`P`) — and new sessions default to **Claude**. There are three
distinct operations, and it's worth knowing which one to reach for:

| Goal | Command | Crosses agents? |
|------|---------|-----------------|
| Continue the **same** conversation on the **same** agent | **Resume** — picker `C-c A s` (Previous / Saved), or restart `C-c s R` | No |
| Continue a discussion on a **different** agent (Auggie → Claude / Pi) | **Fork** — `C-c A f` / `C-c s f` | **Yes** |
| Change **model** mid-conversation (same agent) | `C-c C-v` | No |

There is no "clone" command — **fork is the cross-agent path**.

### Why resume can't switch agents

Resume is provider-native: each agent stores its transcripts in its own
directory and format, and resume relaunches *that* agent with `--resume
<id>`:

- Auggie → `~/.augment/sessions/*.json`
- Claude → `~/.claude/projects/*.jsonl`
- Pi → `~/.pi/sessions/`

The picker reads the session metadata and always restores the **original**
provider, so an Auggie transcript can't be replayed *as* Claude.

### Fork hands off context to the new agent

`C-c A f` (`decknix-agent-session-fork`) is the tool for "I'm moving this
work off Auggie":

1. **Prompts for the new provider** — pick Claude or Pi.
2. Pre-seeds the source session's **workspace and tags** (editable before
   you confirm).
3. Auto-sends a **context hand-off** as the new session's first message,
   naming the source provider, session id, and best-effort **transcript
   path** — so the new agent can read the prior conversation and pick up
   where you left off.

This is best-effort continuity (the new agent *reads the named transcript
file* to reload context rather than a true session port), but for
"continue this discussion in Claude" it's the intended button. Invoked
outside an agent-shell buffer there's no source, so fork degrades to a
plain new session.

### Model selection by agent

`C-c C-v` (set session model) isn't Auggie-only. It's the upstream
agent-shell verb that lists whatever models the **running agent's ACP
bridge advertises** and switches the live session to your choice via an
ACP `session/set_model` request. decknix persists that choice against
the conversation for **every** provider, and **restores it on resume**
— the only difference is the mechanism:

- **Auggie** pins the model at launch via its `--model <id>` flag, so the
  resumed conversation comes up on the right model immediately.
- **Claude / Pi** don't accept a model launch flag, so decknix instead
  **replays** the saved model over ACP (`session/set_model`) the moment
  the resumed session reports ready — the same lever `C-c C-v` uses
  live. The result is the same: your per-conversation model survives the
  resume.

| Agent | Switch mid-session | Restored on resume? | Set the default |
|-------|--------------------|---------------------|-----------------|
| Auggie | `C-c C-v` | ✅ yes — `--model` at launch | `decknix.cli.auggie.settings.model` |
| Claude | `C-c C-v` | ✅ yes — ACP `set_model` replay | `agent-shell-anthropic-default-model-id`, or `ANTHROPIC_MODEL` env |
| Pi | `C-c C-v` *if Pi's bridge advertises models* | ✅ yes — ACP `set_model` replay | Pi's own config (`~/.pi.json`) |

The **default** still matters for the *first* turn of a brand-new
conversation, before you've made any `C-c C-v` choice to persist — set
it so fresh sessions start on the right model.

**Automated purposes** — for PR reviews (`C-c A c r`, sidebar Requests
row, auto-review dispatch), pin both the *provider* and *model* per
purpose via
`programs.emacs.decknix.agentShell.purposes.<name>.{provider,model}`
in your Nix config.  See [Per-Purpose Provider &
Model](../configuration.md#per-purpose-provider--model) for the full
list of purposes, defaults, and validation semantics.  Purpose pins
survive across all three providers — the model rides `--model` on
launch for Auggie and is replayed over ACP for Claude / Pi.

**Claude** — set the per-Emacs default in your personal config so every
new Claude session starts on the right model (after that, `C-c C-v`
choices persist and are replayed on resume):

```elisp
(with-eval-after-load 'agent-shell-anthropic
  (setq agent-shell-anthropic-default-model-id "claude-sonnet-4-5"))
```

To point at a custom or proxy endpoint/model instead, use the
environment:

```elisp
(setq agent-shell-anthropic-claude-environment
      (agent-shell-make-environment-variables
       "ANTHROPIC_MODEL" "..."))
```

**Pi** — the *default* model is governed by Pi itself (its own config /
in-session controls); decknix wires no `default-model-id` for Pi. But
once you pick a model with `C-c C-v` it's persisted and replayed on
resume like Claude. If `C-c C-v` reports *"No session models
available"*, the Pi ACP bridge isn't advertising a model list — there's
nothing to switch or persist, so select the model through Pi's own
configuration instead.

### Notes

- **Start fresh on Claude** with plain `C-c A n` (it prompts for provider;
  `C-u C-c A n` skips the prompt and uses the default, Claude).

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

