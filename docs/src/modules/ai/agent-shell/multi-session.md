# Multi-Session (Layer 2)

Layer 2 turns agent-shell from a single-buffer chat into a full session management system.

## Unified Session Picker (`C-c s`)

The session picker combines three sources into one completing-read:

```
Agent session:
  [new]   Start a new auggie session
  [live]  *agent-shell*<proptrack-fix>
  [live]  *agent-shell*<decknix-docs>
  [saved] a1b2c3d4  2h ago   12x  Investigate proptrack pubsub timeout...
  [saved] e5f6g7h8  3d ago    8x  Refactor agent-shell keybindings... [decknix, refactor]
```

- **[new]** — starts a fresh agent-shell session
- **[live]** — switches to an existing Emacs buffer
- **[saved]** — resumes a saved auggie session (boots a new agent-shell with `--resume <id>`)

Saved sessions show: truncated ID, relative time, exchange count, first message preview, and tags (if any).

## Session Resume

When you select a saved session, the picker:

1. Appends `--resume <session-id>` to the ACP command
2. Starts a new agent-shell buffer with the auggie session restored
3. Stores the auggie session ID in a buffer-local variable for history/tagging

```elisp
;; The resume mechanism — auggie CLI handles the actual session restore
(let ((agent-shell-auggie-acp-command
       (append agent-shell-auggie-acp-command
               (list "--resume" session-id))))
  (agent-shell-start :config (agent-shell-auggie-make-agent-config)))
```

## Session History (`C-c h` / `C-c H`)

View the full conversation history for any session:

- `C-c h` — **DWIM**: if in an agent-shell buffer with a known session, shows that session's history. Otherwise, prompts to pick.
- `C-c H` — **Always pick**: shows the session picker regardless of current buffer.

History is rendered by generating a share link via `auggie session share <id>` and opening it in **xwidget-webkit** (embedded browser) or **eww** (text browser) as fallback — all inside Emacs.

## Clean Quit (`C-c q`)

Quitting a session:

1. Prompts for confirmation (`y-or-n-p`)
2. Switches to the previous buffer
3. Kills the agent-shell buffer (sends SIGHUP to auggie, which auto-saves the session)

The session is immediately available in the picker's saved list for future resume.

## Buffer Rename (`C-c r`)

Rename the agent-shell buffer for clarity:

```
*agent-shell*  →  *agent-shell*<proptrack-pubsub-fix>
```

Uses `agent-shell-rename-buffer` from the core package.

## Extensions

### Manager Dashboard (`C-c m`)

`agent-shell-manager` provides a tabulated list of all agent-shell buffers at the bottom of the frame. Toggle with `C-c m`.

### Workspace Tab (`C-c w`)

`agent-shell-workspace` creates a dedicated tab-bar tab with a sidebar showing all agent sessions. Toggle with `C-c w`.

### Attention Tracker (`C-c j`)

`agent-shell-attention` adds a mode-line indicator showing pending/busy session counts:

```
AS:2/1    ← 2 sessions pending input, 1 busy
```

`C-c j` jumps to the next session needing attention.

## Nix Options

```nix
programs.emacs.decknix.agentShell = {
  manager.enable = true;    # Tabulated dashboard
  workspace.enable = true;  # Tab-bar workspace
  attention.enable = true;  # Mode-line tracker
};
```

