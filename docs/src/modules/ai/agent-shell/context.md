# Context Awareness (Layer 5)

Layer 5 makes the agent shell **work-aware** — it passively tracks the issues, PRs, CI status, and review threads relevant to your current conversation.

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│ Issues: #51 #52  |  PR: #50  |  CI: ✅  |  Reviews: 2 unresolved │
├─────────────────────────────────────────────────────────────┤
│  *agent-shell*<cherries-epic>                               │
│                                                             │
│  Let's work on the migration wizard (#52). The PR (#50)     │
│  is passing CI now. There are 2 unresolved review threads.  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

The header-line at the top of every agent-shell buffer shows a live summary of tracked context.

## Auto-Detection

The context panel scans buffer text for references:

| Pattern | Detected As | Example |
|---------|-------------|---------|
| `#123` | GitHub issue/PR (current repo) | `#51` |
| `org/repo#123` | GitHub issue/PR (specific repo) | `ldeck/decknix#52` |
| `PROJ-1234` | Jira ticket | `ALR-4268`, `NC-7801` |

False positives are filtered: `HTTP-200`, `SHA-256`, `UTF-8`, `ISO-8601` are excluded.

## Data Fetching

For each detected GitHub reference, the panel fetches metadata via `gh` CLI:

- **Issues/PRs**: number, title, state (open/closed/merged), URL, type (issue vs PR)
- **CI**: latest run status for the current branch (pass/fail/running)
- **Reviews**: unresolved review thread count across open PRs in context

CI status auto-polls every 60 seconds.

## Header-Line Indicators

| Indicator | Meaning |
|-----------|---------|
| `Issues: #51 #52` | Tracked issues (green = open, grey = closed) |
| `PR: #50` | Tracked PRs (green = open, purple = merged, red = closed) |
| `CI: ✅` | Latest CI run passed |
| `CI: ❌` | Latest CI run failed |
| `CI: 🔄` | CI run in progress |
| `Reviews: 2 unresolved` | Unresolved PR review threads (yellow warning) |

## Context Panel (`C-c I`)

The full detail panel shows everything in a formatted buffer:

```
Agent Context Panel
────────────────────────────────────────────────────

Issues
────────────────────────────────────────
  #51          Cherries epic — high-appeal features    open
  #52          Migration wizard                        open 📌

Pull Requests
────────────────────────────────────────
  🟢 #50       Agent shell context awareness           open

Branch & CI
────────────────────────────────────────
  Branch: feature/context-panel  (ldeck/decknix)
  CI:     ✅ success  CI / Build and Test

Reviews
────────────────────────────────────────
  4 threads, 2 unresolved

────────────────────────────────────────────────────
Press q to close.  C-c i g to open item in browser.
```

## Pin / Unpin

Manually pin items to keep them in context even if they're not mentioned in the conversation:

| Key | Action |
|-----|--------|
| `C-c i a` | Pin an issue/PR (e.g., `#49`, `NC-1234`, `org/repo#12`) |
| `C-c i d` | Unpin — remove from tracked context |

Pinned items are marked with 📌 in the detail panel.

## Navigation

| Key | Action |
|-----|--------|
| `C-c i i` | List tracked issues (completing-read → open in browser) |
| `C-c i p` | List tracked PRs |
| `C-c i c` | Refresh and show CI status |
| `C-c i r` | Refresh and show review thread count |
| `C-c i g` | Open any tracked item in external browser |
| `C-c i f` | Visit in magit-forge |

## Persistence

Pinned context items are saved per-session in `~/.config/decknix/agent-sessions.json` (the same file used for tags). When you resume a session, pinned items are restored and metadata is re-fetched.

## Nix Options

```nix
programs.emacs.decknix.agentShell.context.enable = true;
```

Requires `gh` CLI on `$PATH` (included in decknix default packages).

