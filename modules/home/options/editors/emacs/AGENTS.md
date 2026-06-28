# AI Agent Guidelines — Emacs Modules

> Emacs-specific conventions for AI agents. Read the root `AGENTS.md` first.

## Architecture

The Emacs configuration is split into independent Nix modules, each generating
Elisp into a shared `default.el` that is byte-compiled and native-compiled at
Nix build time.

### Module Map

| Module | Purpose |
|--------|---------|
| `default.nix` | Core settings, theme, daemon config, `exec-path-from-shell` |
| `agent-shell.nix` | Augment AI agent integration (sessions, compose, context) |
| `completion.nix` | Vertico, Consult, Corfu, Orderless, Embark |
| `magit.nix` | Git via Magit, Forge, code-review |
| `ui.nix` | which-key, helpful, nerd-icons |
| `languages.nix` | 30+ language modes |
| `lsp.nix` | Eglot, language servers, DAP debugging |
| `deckmacs.nix` | Framework management — hot-reload, status, diagnostics (#85) |
| Others | editing, undo, org, treemacs, http, welcome, project |

### Daemon (`modules/darwin/emacs.nix`)

- Runs as a launchd user agent (`org.nixos.emacs-server`)
- Uses `bin/emacs --fg-daemon` (not `Emacs.app` — avoids macOS quit dialogs)
- `ProcessType = "Background"` in the plist
- GUI frames via `emacsclient -c`; `ec` wrapper auto-starts daemon

### Hot-reload (`deckmacs-reload`, `C-c D r`)

`decknix switch` invokes `(deckmacs-reload)` via `emacsclient` from
`postActivation`.  The reload performs three steps in order so that
edits to **carved first-party packages** (everything matching
`decknix-*` under `agent-shell/<feature>/`) propagate without a
`launchctl kickstart`:

1. **Swap store paths.**  The aggregator lives at one
   `/nix/store/<HASH>-emacs-packages-deps` root that changes on every
   switch.  `deckmacs--swap-store-paths` rewrites that prefix in
   `load-path` and `native-comp-eln-load-path`, preserving the
   surrounding upstream Emacs lisp dirs (their order matters for
   built-in module precedence).
2. **Force-unload `decknix-*` features.**  `(unload-feature ... t)`
   on every loaded `decknix-*` so the next step's `(require ...)`
   calls actually run instead of no-opping.  FORCE=t bypasses the
   dependent-features check; ordering is irrelevant because every
   `require` re-resolves below.
3. **Load the new `default.el`.**  The heredoc's
   `(require 'decknix-foo)` calls now find new bytecode at the new
   store root.  Top-level side-effects (`define-key`, `add-hook`,
   `advice-add`) re-run.

A manual `launchctl kickstart -k gui/$(id -u)/org.nixos.emacs-server`
is still needed when (and only when):
- The Emacs **major version** changes (different `emacs-30.2` store path).
- `EMACSLOADPATH` gains entries outside `emacs-packages-deps` that
  the daemon's environment doesn't know about.
- A buffer-local `decknix-*` function is mid-execution at reload
  time (extremely rare; the reload runs in idle).

Note: `add-hook` lambdas in the heredoc that lack a symbol form
will accumulate duplicates across reloads — this pre-dated the
unload step and is a known minor footgun.  Symbol-named hooks
(`(add-hook 'foo #'bar)`) are unloaded with the feature and
re-added cleanly.

## Critical: Dynamic Binding in `default.el`

**`default.el` is evaluated under dynamic binding** (no `;;; -*- lexical-binding: t -*-`).
This means lambdas do NOT capture enclosing variables as closures.

### The Pattern

When you need a closure (timers, sentinels, callbacks), use:

```elisp
;; WRONG — variables are unbound when the lambda runs:
(let ((name "foo"))
  (run-at-time 1 nil (lambda () (message "Hello %s" name))))

;; CORRECT — eval with t flag creates a lexical closure:
(let ((name "foo"))
  (run-at-time 1 nil
    (eval `(lambda () (message "Hello %s" ,name)) t)))
```

**Exception**: Lambda parameters (e.g., `proc` and `_event` in a process
sentinel) are always bound by the lambda itself — the pattern is only needed
for captured *outer* variables.

### Exception: in-tree Elisp packages under `agent-shell/`

First-party Elisp moved out of the `extraConfig` heredoc lives in standalone
`.el` files under `modules/home/options/editors/emacs/agent-shell/<feature>/`,
packaged via `pkgs.emacsPackages.trivialBuild` and pulled into `default.el`
with a `(require 'decknix-<feature>)` line at the same point in the heredoc
where the inline source used to live.

These files **opt into lexical binding** (`;;; -*- lexical-binding: t -*-`)
and so the dynamic-binding workaround above is **not** needed inside them.
Two rules apply:

1. Symbols defined elsewhere in `default.el` (e.g. `decknix-agent-prefix-map`,
   `decknix--hub-wip`, `decknix--agent-current-conv-key`) are forward-declared
   at the top of each file using `declare-function` and `defvar`-without-value.
   This keeps byte-compile warning-clean while still resolving at runtime.
2. Top-level **side-effects** that depend on `default.el` runtime state
   (`define-key` on `decknix-agent-prefix-map`, file-notify-watch starts,
   etc.) stay **in the heredoc**, immediately after the `(require ...)` call.
   At Nix build time the byte-compiler triggers `(require ...)` for these
   files; if they ran side-effects at top level the build would crash because
   the surrounding heredoc's defvars have only been seen, not evaluated.

Current in-tree packages:

| Path | Feature | Notes |
|------|---------|-------|
| `agent-shell/progress/decknix-progress.el` | Progress data layer | Provider-agnostic items, attention rollup |
| `agent-shell/progress/decknix-progress-ui.el` | `*decknix-progress*` buffer | Magit-style hierarchical view |
| `agent-shell/progress/decknix-progress-sidebar.el` | Sidebar badge integration | Mtime-cached `index.json` reads |

### Verification

The Nix build derivation native-compiles all Elisp.  A syntax error or
missing `declare-function` will fail the build.

**Before committing Elisp changes:**

1. **Syntax Check**: Run `emacs -Q -batch -f batch-byte-compile <file>.el`. This
   is significantly faster than a full Nix build and catches 90% of issues
   (unbalanced parens, missing requires, unknown functions).
2. **Heredoc Unescaping**: If you are moving code from the `agent-shell.nix`
   heredoc into a standalone `.el` file, you **must** unescape all `\"` back to
   plain `"`.  Failing to do so results in `Interactive form missing` errors
   because the byte-compiler sees one giant malformed string.
3. **Check `declare-function`**: Ensure all cross-file dependencies (including
   built-in tabulated-list or transient functions if they aren't loading) are
   forward-declared.

### Tests (`agent-shell/tests/`)

Every in-tree package wires its ERT characterisation suite into the
build via the `mkEmacsTestedPackage` helper in `agent-shell.nix`.  A
red test exits the byte-compile build non-zero, which fails the
system derivation; no commit lands without a green build.

Layout:

```
agent-shell/tests/
├── decknix-test-helpers.el       # shared macros + fixture builders
├── decknix-progress-test.el      # data layer
├── decknix-progress-ui-test.el   # UI helpers
└── decknix-progress-sidebar-test.el  # sidebar badge + cache
```

Conventions:

1. **TDD — tests describe intended behaviour, not just current behaviour.**
   The ERT suite is wired into the Nix build derivation; a red test fails the
   entire system build.  Treat every test as the authoritative specification
   for its function's contract.

   Follow the red → green → refactor cycle for all changes:

   - **New behaviour**: write the failing test first, then implement.
   - **Changing an existing contract** (glyphs, faces, data shapes): update the
     test(s) to the new intended contract first so they go red, *then* update
     the implementation.  Never ship a commit where implementation and tests
     describe different contracts — the Nix build will catch the mismatch but
     only after a full build cycle.
   - **Bug fixes**: write a reproducing test that fails before fixing the bug.

   For first-time documentation of *existing* code with no tests yet, a
   characterisation pass (pinning what the code currently does) is fine as a
   starting point — but treat it as technical debt to be replaced with
   specification-first tests when that code next changes.

2. **Lexical-binding tests, dynamic free vars** — `let'-binding a free
   variable that the byte-compiled module accesses via `varref`
   (e.g. `decknix--hub-wip`) requires the variable to be globally
   `special-variable-p`.  Forward declarations in
   `decknix-test-helpers.el` use `(defvar X nil)` (with initialiser)
   for hub-data vars so the binding is dynamic; without a value
   `(defvar X)` is only a compiler hint and the let binds lexically.
3. **Tmp-isolated persistence** — `decknix-test-with-tmp-progress-dir`
   shadows `decknix-progress--dir` to a per-test mktemp dir and
   clears the index cache, so persistence tests can't escape into
   the user's `~/.config`.
4. **Test files do not ship** — `mkEmacsTestedPackage' stages tests
   in a sibling tmp dir for the test run, so they never enter
   `installPhase' or get native-compiled into the daemon's
   load-path.
5. **Sidebar buffer name comes from upstream** — Carved modules that
   refresh the workspace sidebar (`agent-shell-workspace-sidebar-refresh`)
   must consult the upstream variable `agent-shell-workspace-sidebar-buffer-name`,
   NOT the literal `"*Agent Sidebar*"`.  Each carved module that
   guards a refresh on buffer existence forward-declares the variable
   with an initial value matching upstream so test runs (which don't
   load `agent-shell-workspace`) see a bound symbol:
   `(defvar agent-shell-workspace-sidebar-buffer-name "*Agent Sidebar*")`.
   At daemon load time the upstream defvar runs first (hard dep) and
   the carved defvar is a no-op; values are identical so they can't
   drift.  Skipping the variable lookup (using the literal) silently
   breaks live toggle refresh because the actual buffer name has a
   capital `A` / space / capital `S` — easy to mis-spell.

## Package Sourcing

```
Priority: stable nixpkgs → unstable nixpkgs → custom derivations
```

- Packages from `pkgs.unstable.emacsPackages` must be rebuilt via
  `pkgs.emacsPackages.trivialBuild` to ensure native-compiled `.eln` files
  match the daemon's Emacs build hash. See the `agent-shell.nix` header.
- Custom packages use `pkgs.emacsPackages.trivialBuild` with local source.

## Agent Shell Module (`agent-shell.nix`)

The largest module (~4400 lines). Key subsystems:

### Session Management
- **Session picker** (`C-c A s`): Uses `consult--multi` with sectioned groups
  (like `C-x b`): **Live Sessions** → **Saved Sessions** → **New**. Each section
  has a horizontal divider. Live sessions show workspace + tags; current buffer
  is excluded. Saved sessions read `~/.augment/sessions/*.json` via parallel
  `jq`, cached with 2-min TTL, pre-fetched on daemon start. Default view is
  **conversation-collapsed** (one row per conversation). `C-u C-c A s` expands
  to show all individual session snapshots.
  In-picker action keys: `M-w` toggles the **workspace filter** (all workspaces
  ↔ the workspace of the calling buffer); the active filter appears in the prompt
  as `[~/path/to/ws]`. `C-k` kills the highlighted live session buffer(s);
  `C-d` permanently deletes saved/previous sessions from disk and metadata.
  `C-SPC` marks multiple candidates for batch `C-k`/`C-d`/`RET`.
- **Conversation identity**: Derived by hashing `firstUserMessage` (SHA-256,
  truncated to 16 chars). Provides stable identity across resumed sessions (#78).
- **Session creation** (`C-c A n`): Guided flow — workspace dir, name, tags.
  If multiple agent providers (Auggie, Claude, Pi) are registered, prompts for
  provider selection.  Passes `--workspace-root` to the chosen agent CLI via
  closure (survives deferred `:client-maker` invocation).
- **Session close** (`C-c A q` / `C-c s q`): Kills the buffer. If other live
  sessions exist, switches to the next one (or opens the picker if multiple).
  If last session, returns to the welcome screen or `*scratch*`.
- **Session restart** (`C-c s R`): Restarts the current session in place by
  killing the buffer (which saves the session) and re-resuming the same
  conversation — restoring workspace, provider, model, and history. Unlike the
  upstream sidebar restart (which starts a *blank* session and only works on a
  *live* buffer), this resumes from the latest on-disk snapshot, so it revives
  even a `killed` buffer whose agent process has already exited. The pure
  name-recovery helper is carved + tested in
  `agent-shell/agent/decknix-agent-session-restart.el`.
- **Session resume**: Restores history into comint buffer. Buffer is renamed
  to `*Auggie: <name>*` (or `*Claude: <name>*`, etc.) using tags (if any) or
  first-message preview, matching the naming convention of new sessions.
  **Workspace is restored** from `agent-sessions.json` — passes
  `--workspace-root` to the agent CLI and sets `default-directory` so the
  agent operates in the original project directory.  The correct provider is
  detected and used automatically based on the session ID.
- **Workspace persistence**: Workspace directory is stored per conversation in
  `~/.config/decknix/agent-sessions.json` alongside tags. Saved on session
  creation, restored on resume.
- **Model persistence** (`C-c C-v`): The `C-c C-v` binding wraps the
  upstream **ACP-generic** `agent-shell-set-session-model` verb, which lists
  whatever models the running session's ACP bridge advertised (the
  `models.availableModels` from the `session/new` response) and switches the
  live session via an ACP `session/set_model` request — so it works for any
  provider whose bridge reports models, not just auggie. What's auggie-specific
  is the decknix wrapper's **persistence**: the chosen model is recorded against
  the conversation in `agent-sessions.json` and re-applied on resume by passing
  `--model <id>` to the auggie CLI (only auggie takes `--model`). The global
  default model for new auggie sessions is configured via
  `decknix.cli.auggie.settings.model` (written to `~/.augment/settings.json`).
  - **Claude**: live `C-c C-v` works; the per-conversation choice is *not*
    persisted by decknix across resume. Set the default via
    `agent-shell-anthropic-default-model-id` (or `ANTHROPIC_MODEL` in
    `agent-shell-anthropic-claude-environment`) instead.
  - **Pi**: `agent-shell-pi-make-agent-config` wires no `:default-model-id`;
    model choice defers entirely to Pi's own config. `C-c C-v` only populates
    if `pi-acp` advertises a model list (otherwise it reports "No session
    models available").

## Agent Providers

The `agent-shell` subsystem supports multiple AI backends via a generic provider
registry (`decknix-agent-provider.el`).

### Supported Providers

| Provider | ID | Glyph | Status | ACP bridge |
|----------|----|-------|--------|------------|
| Auggie | `auggie` | `A` | ✅ Fully working | built into `auggie` CLI |
| Claude Code | `claude-code` | `C` | ⚠️ Needs ACP bridge | `claude-agent-acp` (see below) |
| Pi | `pi` | `P` | ⚠️ Needs ACP bridge | `pi-acp` (see below) |

**Default provider**: `claude-code` — `C-u C-c A n` (QUICK) creates a Claude
session without prompting. Regular `C-c A n` prompts for provider selection.

#### Claude Code — First-class Setup

The `claude-code` CLI and the ACP bridge (`claude-agent-acp`) are both installed
via `decknix.ai.claude.enable = true` — no manual npm steps required after
`decknix switch`.

Authentication defaults to login-based (`agent-shell-anthropic-authentication`
`:login t`). Run `claude` once standalone to complete the OAuth flow, then
agent-shell picks up the token automatically.

Session files live in `~/.claude/projects/` (`.jsonl` format). The jq filter
in the registry extracts metadata for the session picker.

#### Pi — First-class Setup

The `decknix.ai.pi` module (`decknix.ai.pi.enable = true`) installs the `pi-acp`
ACP bridge via Nix — no manual npm steps required after `decknix switch`.

Sessions live in `~/.pi/sessions/`. Session file format will be discovered on
first use; the `:session-jq-filter` in the registry is pending (sessions won't
appear in `C-c A s` until the field is populated).

### Provider Selection
- **New sessions** (`C-c A n`): Prompts for provider if more than one is
  registered. `C-u C-c A n` (QUICK) skips provider selection and uses the
  default provider (`claude-code`).
- **Forking** (`C-c A f` / `C-c s f`): Prompts for the new session's
  provider (which may differ from the source), pre-seeds the source
  session's workspace and tags, then **hands off context** — the new
  session's first user message is auto-sent (mirroring the quickaction
  send path) describing the source provenance: provider label, source
  session id, best-effort transcript path, and source tags. This lets a
  fork into a *different* agent pick up the prior context (the new agent
  may read the named transcript if accessible). The hand-off embeds the
  source session id so forks of distinct sources derive distinct
  conversation keys. When invoked outside an agent-shell buffer there is
  no source, so fork degrades to a plain `decknix-agent-session-new`
  (no hand-off message). Pure message builders are carved + tested in
  `agent-shell/fork/decknix-agent-fork.el`.
- **Resuming**: Automatically restores the correct provider based on session
  metadata.
- **Sidebar**: Displays the provider glyph (A/C/P) for each live session.

### Future Providers — Assessment

Providers that could be added via the same registry pattern.
All require both a CLI tool AND an ACP bridge (either built-in or separate).

| Provider | CLI tool | ACP bridge | Nixpkgs? | Notes |
|----------|----------|-----------|----------|-------|
| **OpenCode** | `opencode` (✅ in `home.packages`) | built-in (`opencode --acp`?) | CLI is in nixpkgs | Already installed; register once ACP mode confirmed |
| **Gemini CLI** | `gemini` | built-in `--experimental-acp` flag | Not in nixpkgs | `npm install -g @google/gemini-cli`; uses login auth |
| **Goose** | `goose` | built-in | Not in nixpkgs | `curl install`; open-source by Block Inc |
| **Mistral Vibe** | `mistral-vibe` | built-in | Not in nixpkgs | `uv tool install mistral-vibe`; needs `MISTRAL_API_KEY` |
| **Cursor** | Cursor IDE | `cursor-agent-acp` npm pkg | Neither | `npm install -g @blowmage/cursor-agent-acp`; IDE-dependent |
| **Kimi Code** | `kimi` CLI | built-in | Not in nixpkgs | `curl` install; China-based provider |
| **Kiro** | `kiro` CLI | built-in | Not in nixpkgs | `curl` install; AWS-backed |
| **Qwen Code** | `qwen-code` | built-in | Not in nixpkgs | `npm install -g @qwen-code/qwen-code` |
| **CodeBuddy** | `codebuddy` | built-in `--acp` | Not in nixpkgs | Install via CodeBuddy docs |

**Priority order** (based on ecosystem relevance and auth simplicity):
1. **OpenCode** — already installed, confirm ACP mode and register
2. **Gemini CLI** — broad availability, login auth (no API key needed)
3. **Goose** — open-source, OpenAI-compatible
4. Others as needed

To register a new provider, add an entry in `agent-shell.nix` matching the
`decknix-agent-register-provider` pattern at lines 2168–2201, then add
`:make-config-fn`, `:acp-command-var`, `:sessions-dir`, `:label`, `:glyph`,
and `:supports-workspace-root`.

### Quick Actions
- **PR review** (`C-c A c r`): DWIM workflow — prompts for GitHub PR URL
  (defaults to clipboard), workspace, and session name. Parses `owner/repo/number`
  from URL (lightweight, no `gh` CLI). Auto-generates name (`pr-<repo>-<number>`)
  and tags (`review`, `<repo>`). Creates session and auto-sends
  `/review-service-pr <url>` once the process is ready.
- **Batch process** (`C-c A c B`): Opens a compose editor for launching multiple
  sessions. Uses `---` grouping syntax:
  ```
  --- <group-name> [: <workspace>]
  <url>
  <url>
  ```
  Lines within a `---` group share a single session. Ungrouped lines each get
  their own session. `C-c C-c` to launch, `C-c C-k` to cancel.
- **Batch compose mode**: Minor mode (`decknix-batch-compose-mode`) with
  font-lock for `---` dividers, GitHub URLs, and `#` comments. Header-line
  shows keybindings.
- **Summary buffer**: `*Batch Launch*` shows ✓/✗ per session after batch launch.
- Built on reusable `decknix--agent-quickaction-start` — any future quick action
  (e.g., investigate-issue) follows the same pattern: name + tags + workspace +
  auto-send command.

### Compose Editor
- Decoupled input buffer (sticky or transient mode).
- Header-line shows available keys with `C-c` prefix factored out.
- `which-key` labels for all sub-maps including the `k` (interrupt) prefix.
- **History navigation**: `M-p`/`M-n` cycle through the **current session's**
  prompts only (from `comint-input-ring`). `M-P`/`M-N` (shifted) cycle through
  **all sessions** (current first, then on-demand from saved session files).
- **Interrupt-and-submit** (`C-c k C-c`): Interrupts the agent, then submits
  the compose buffer after a 0.3s delay. The compose buffer stays visible until
  the submit fires (not closed prematurely).

### Unified Header-Line
Every agent-shell buffer displays a persistent header-line combining:
1. **Status icon + label** — Circle shape-family: `○ initializing` (grey),
   `◐ working` (yellow), `◐ waiting` (red), `● ready` (green),
   `● finished` (cyan), `● killed` (red). Shape encodes lifecycle stage;
   colour encodes state within that stage. Uses `agent-shell-workspace`'s
   rich detection when available, falls back to `shell-maker--busy`.
2. **Session tags** — from `agent-sessions.json`, shown as `#tag1 #tag2`.
3. **Workspace path** — abbreviated (e.g., `~/tools/decknix`).
4. **Context panel items** — issues, PRs, CI, reviews (when context module enabled).

Auto-refreshed every 2 seconds via a buffer-local timer. Detects `working → ready`
transitions and shows `✔ finished` until the user views the buffer.

The `decknix--context-update-header` function delegates to the unified header
(`decknix--header-update`) so context data is always incorporated.

### Context Panel
- Tracks GitHub issues, PRs, CI status, review threads.
- Data is rendered as part of the unified header-line (merged, not standalone).
- `C-c i` prefix for context commands.

### Hub Integration (`decknix-hub`)
- Surfaces data from the `decknix-hub` background daemon in the workspace
  sidebar — zero Emacs CPU overhead (all polling happens in the Rust daemon).
- **Requests** section: PR reviews assigned to me, ordered oldest first
  by default.  Flip direction with `s` in the sidebar toggles transient
  (`T`) — the section header grows a `⇅` badge while reversed.  The same
  flag seeds the `r` picker so the sidebar and picker start in sync;
  inside the picker, `M-s` flips the order ephemerally without touching
  the persisted state.  Shows age (color-coded: 3d+ = red, <3d = yellow),
  repo, PR number, CI status icon (●/◐/○), and title.  `RET` opens the
  PR in the browser.  **Active-review tint**: when a live agent-shell
  session is already reviewing a request (matched on the `pr-<repo>-<n>`
  buffer-name pattern), the row is tinted gold (`#d7af5f`, the same
  warm hue as the `me` @-mention badge) so it reads at a glance as
  "already in flight, do not dispatch a second review session".  The
  tint composes with per-column faces via `add-face-text-property`
  (`append`), so repo / age / CI / status icons keep their semantic
  colours and only the neutral text (title, `#NUMBER`, separators)
  receives the gold.  The `◉` glyph on the row is preserved as a
  compact secondary cue.  The same tint is applied in the `r` picker
  (consult, transient, and consult-multi variants).
  **Layouts (cycle with `D`)**:
  - **Layout A (full)**: the current default. Everything always visible (age, number, CI, bot, cmt, approval, DTSP).
  - **Layout B (scoped)**: phase-aware columns. Hides irrelevant signals based on the PR's state (e.g. hiding review columns for drafts or local branches).
  - **Layout C (label)**: primary signal plus readable state description (e.g. "CI failing", "awaiting review").
  - **Layout D (minimal)**: high-signal, compact view. Only primary glyph, optional mention/reply, phase tag (e.g. `[draft]`, `[open]`), and title. Using the unified shape-family system: `○` pre-PR, `★` draft, `◐`/`●` open, `▣`/`■` post-merge.
- **Requests picker (`r`)**: a single entry-point for navigating reviews.
  Toggles are all minibuffer-local and never leak into the sidebar's
  global filters (a refresh-suspend flag freezes sidebar re-renders
  during the picker's `recursive-edit` so timer ticks can't paint the
  sidebar with the picker's local state):
  - `M-m` — @-mention only
  - `M-r` — ready-for-review only (CI passing, not conflicting, not
    draft, not yet reviewed by me) — replaces the old `R` key
  - `M-b` — cycle bot-authored PRs (hide → show → mentioned → hide,
    where `mentioned` means I am directly @-mentioned/requested OR my
    team is requested without any other individuals tagged, so
    team-noise that someone else is already on stays hidden)
  - `M-s` — reverse sort
  - `C-SPC` — multi-select (launch reviews for every marked item)
  When a toggle filters the list to zero items, the picker stays open
  with a dimmed placeholder so the user can adjust toggles or `C-g` to
  quit — it no longer closes on them.
- **WIP** section: My open PRs grouped by repository, with CI status and
  branch names. `RET` opens the PR in the browser.  **Worktree placeholders**
  (spec §3.6.7): every `(repo, branch)` in the local worktree registry that
  doesn't have a matching open PR in `github-wip.json` is rendered as a
  dim `wip` row under the same repo sub-header (`⎇  2h wip  feature/foo`).
  This surfaces freshly-created worktrees at t=0 instead of waiting for
  `gh pr create` + GitHub Search indexing (~30s–2min).  Placeholder rows
  carry no URL, so URL verbs (`o/b/c/r/s/M/R/m/x/C/D`) gracefully no-op;
  the worktree submenu (`w`) is the verb that matters and works as usual.
- Data is read from `~/.config/decknix/hub/` JSON files via
  `file-notify-add-watch` on the directory — sidebar refreshes the instant
  any hub file changes.
- Header-line shows review count: `⚡3 reviews`.
- Controlled by `programs.agent-shell.decknix.hub.enable` (default: true).
- Requires `decknix.services.hub.enable = true` in the darwin config to run
  the background daemon. See `modules/darwin/hub.nix` for service options.
- Future adapters (Jira, TeamCity, Slack) will add more sidebar sections
  reading from additional JSON files in the same hub directory.

### Workspace (`agent-shell-workspace`)
- Dedicated `Agents` tab-bar tab with buffer isolation (`C-c w` to toggle).
- Sidebar sections (top to bottom): **Requests** → **WIP** → **Live** →
  **Sessions** → **Keys/Toggles** footer.  The **Sessions** heading
  aligns with the Navigate `s` key so the label matches the shortcut.
- Agent management: `c` new, `k` kill, `r` restart, `R` rename, `d` delete killed.
- Tiling controls: `a a` add, `a x` remove.
- **Session attention icons** (Live + Previous rows): linked PRs drive
  an `inbox/sent` aggregate parallel to the Requests signals:
  - `📥 N` — N linked PRs awaiting my action (review request not yet
    submitted, WIP with `needs_reply` or `CHANGES_REQUESTED`).
  - `📤 N` — N linked PRs where I have acted (review submitted, WIP
    pushed with no pending reply).
  - `↩` — shown once when any linked PR has `replies_to_me`.
  - Terminal PRs (MERGED/CLOSED) are excluded so stale links do not add
    noise. Rendered immediately after the `[N⬆ N✓]` count badge.
- **Linked PR rows** (expanded under a session when PRs toggle is on):
  rendered as fixed-width columns so pipeline progress stays scannable
  across every expand mode:
  ```
  #N  age  state  CI b c ✓ [⚠] DTSP
  ```
  (Two spaces separate the state word from the signal zone; columns
  inside the signal zone are single-spaced for compactness.)
  - State word: `open` (light blue `#61afef`), `draft` (yellow),
    `merged` (green), `closed` (dim). Left-padded to 6 chars so the
    downstream columns line up. Drafts also render `#N` in the comment
    face to mirror the Reviews/WIP sections.
  - `CI` = `⟳` glyph tinted green (pass) / yellow (running) / red
    (fail) / grey (idle). Always shown so pipeline mode still carries
    build state.
  - `b` = bot review column. Yellow when a bot posted last and the
    action is still pending (`bot_pending`); dim otherwise. Phase 1a
    will refine this with a per-bot signature list
    (`copilot-pull-request-reviewer[bot]`, `augment-code[bot]`,
    `dependabot[bot]`, `github-actions[bot]`).
  - `c` = human comments column. **Tier 1 attention heuristic**
    (per-thread `isResolved` + last-author): when the PR has inline
    review threads, yellow if any thread is unresolved AND the last
    commenter is not me; bright green (`#98c379`) if every thread is
    resolved (or the only unresolved ones have me as the last
    commenter). When the PR has NO inline threads, falls back to
    the legacy ladder: yellow on `needs_reply`, soft green
    (`#87d7af`) on `replies_to_me`, dim otherwise. Thread stats
    come from a `gh api graphql reviewThreads` call run in parallel
    with the standard `gh pr view` fetch in the hub.
  - `✓` = approval column. Green `✓` = APPROVED, red `✗` =
    CHANGES_REQUESTED, yellow `?` = review required / commented /
    pending, dim `?` otherwise. Sourced from `review_decision` for
    WIP kind and `my_review` for review kind.
  - `⚠` = merge-conflict flag (red), rendered only when GitHub reports
    `mergeable = CONFLICTING` on OPEN rows (draft or not). Non-conflict
    rows omit it entirely so the DTSP column stays put for the common
    case; a conflict shifts DTSP one slot right, which is the intended
    visual cue. MERGED can't conflict; CLOSED short-circuits earlier.
  - `DTSP` = deploy indicator (only in `pipeline` / `both` modes).
    For merged PRs the review columns collapse to dim `·` placeholders
    since bot/human/approval signals are moot post-merge; CI still
    reflects the default-branch build.
  - Closed PRs stop at the state word — every downstream signal is
    moot and rendering them as dim glyphs just adds noise.
  - Symbol-style toggle (`y`) still swaps non-column glyphs (Requests
    / WIP sections) between ascii and emoji; the columnar PR rows use
    ASCII always because Emacs faces cannot tint colour-emoji.
- **Linked repo rows** (for repos you work on by pushing directly to a
  branch — e.g. `decknix` / `decknix-config` — linked via `C-c A c L`
  or `C-c s L`). Intermixed with PR rows under the same repo group
  header, sorted by most-recent-activity first:
  ```
  <branch> <sha7> <age>  CI  DTSP
  ```
  - `<branch>` — tracked branch name in keyword face (e.g. `main`).
  - `<sha7>` — first 7 chars of the HEAD commit SHA, dim.
  - `<age>` — time since that commit, right-aligned to 3 chars to
    line up with PR rows in the same group.
  - `CI` = same `⟳` column as PR rows, tinted by the combined
    status-check rollup for the HEAD commit.
  - `DTSP` works identically (driven by repo+branch lookup in
    `teamcity-deploys.json`).
  - Repo rows intentionally have no state-word / bot / cmt /
    approval / conflict columns — there's no PR to review.
  - Data is fetched on demand via `gh api graphql`, cached per
    `OWNER/REPO#BRANCH` with a 5-minute TTL, and persisted to
    `~/.config/decknix/hub/repo-cache.el` so the sidebar re-renders
    instantly at startup while a background refresh runs.
  - Link multiple branches per repo by invoking `C-c A c L` again
    with a different branch.  Unlink via `C-c A c u` — the picker
    surfaces both PRs and repos with `[repo:main]` / `[authored]`
    prefixes so the type of the item being removed is always clear.
- **Row action menus** (#123): `RET` on any actionable row opens a
  row-specific Action Menu transient.  Five hub-row variants today:
  Request, WIP, Task, Linked PR, Linked Repo — each defined per
  `specs/sidebar-ret.md` §3.2.1.  `M-RET` (and `C-u RET`) skips the
  menu and runs the row's primary action directly: for hub rows that
  is "open URL in xwidget/EWW", for sessions and headers it falls
  through to the existing handler so behaviour is unchanged until
  #125 / #126 / #127 land.  The menus follow the spec's stable-shape
  policy: every verb that *could ever* apply to a row kind keeps a
  permanent slot and is dimmed via `:inapt-if` when the current row's
  state disqualifies it (e.g. `m`/`x` on a non-authored linked PR).
  Verbs awaiting their own follow-up issue render a placeholder that
  echoes "pending" so the menu shape is stable from day one.
- **Category submenus** (spec §3.7): the Action Menu reorganised
  review-family (`r s c R`) and link-family (`u i`) verbs into two
  category submenus — `R Review…` and `S Session…` — joining the
  existing `W Worktree…` (promoted from lowercase `w`).  Six verbs
  cost +1 keypress each (`R r` / `R s` / `R c` / `R R` / `S u` / `S i`)
  in exchange for clean uppercase shortcuts at sidebar-global level
  and a discoverable Action Menu.  Two complementary entry points:
  - **`RET` on a row** — discoverable hub.  Opens the Action Menu;
    the columns advertise the uppercase category keys so muscle
    memory accretes from looking at it.
  - **`R W S` at sidebar-global** — power-user fast path.  Skip the
    Action Menu and open the named submenu directly against the
    row at point.  Lowercase sidebar-global keys (`r w l p s a v h`,
    plus `T K P`) are unchanged; the uppercase trio is purely
    additive.  The submenu opens only on rows where it has at least
    one applicable verb; otherwise the echo area explains why
    (e.g. "No review actions on this task row").
- **Worktree integration** (#128 / #129 / #130, spec §3.6): every hub
  row that resolves a `(repo, branch)` pair carries a 2-column **row
  badge** showing local worktree state at a glance — `⎇*` (live in a
  session), `⎇ ` (separate worktree but no live session), `↓ ` (no
  local clone), or two spaces (primary HEAD / branch ref only).  The
  Action Menu's `w` key opens the **worktree submenu** with eight
  stable-shape verbs: `o` open, `n` create, `s` start session in
  worktree (auto-creates if missing), `x` remove (interlocked against
  any session whose workspace points at the worktree; `C-u x` forces
  via `--force`), `r` reveal in Finder, `d` status (Magit / `vc-dir`),
  `c` copy worktree path, `p` prune.  New worktrees use the sibling
  layout `<primary>-worktrees/<sanitised-branch>`.  Backed by the
  `decknix-hub-worktree-registry` cache (`~/.config/decknix/hub/worktrees.el`,
  60 s TTL, refreshed asynchronously on every mutation) so all UI is
  non-blocking.  See `specs/sidebar-ret.md` §3.6 for the full contract
  and `specs/worktree-cli.md` for the cross-editor CLI that consumes
  the same registry format.
- Toggles transient (`T`): Opens sectioned menu grouped by sidebar
  section. Suffixes within each section are ordered alphabetically by
  their display label (case-insensitive) to match the sidebar footer,
  which advertises the same toggles by label only (no keys shown).
  - **Global**: `g` focus (cycles `off → attention → both`; see Focus
    Steal), `O` org filter, `W` width
  - **Requests**: `@` mention, `F` age, `A` auto-review (cycles
    `off → bot+@ → human+@ → any+@`; auto-dispatches a review session
    for newly-arrived PRs that @-mention me — bot authors via
    `/review-and-ship-bot-pr`, humans via the background
    `/review-service-pr-factory` whose verdict surfaces through the
    attention indicator.  Every active state requires the @-mention as
    a safety guard so team-noise never spawns a paid session.
    Per-workspace command overrides live in `decknix-auto-review-commands`;
    the slash-command defaults are `decknix-auto-review-default-{review,ship}-command`.
    Default `off`, and `"incoming-only"`: enabling seeds the existing
    backlog as handled so it never floods, dispatching only genuinely
    new mentions.  A live-session guard plus a per-PR dedup set prevent
    double-dispatch.  Pure decision layer carved + tested in
    `agent-shell/auto-review/decknix-auto-review.el`), `b` 🤖 bot-review (hide PRs where
    a bot posted last — default on, since a fix is likely needed before
    approving sticks), `B` bot-authors (cycles hide → show → mention,
    where `mention` keeps bot PRs only when I am directly @-mentioned
    or my team is requested without other individuals tagged —
    filters out team-noise where someone else is already handling it),
    `C` ci, `c` 💬 comments (hide PRs whose latest non-bot activity is
    someone else), `M` ↩/👽 replies-to-me (show only PRs where a human or
    bot replied in a thread I participated in), `s` sort ⇅ (flip
    oldest→newest; picker honours the same flag, `M-s` inside a picker
    flips it ephemerally), `X` ⚠ conflict (hide PRs with a merge
    conflict — `mergeable = CONFLICTING` — default on; conflicting PRs
    need a rebase before reviewing makes sense, so they're hidden until
    the conflict is resolved), `x` 📝 draft (hide PRs still in draft —
    GitHub `isDraft = t` — default on; a draft is explicitly marked
    not-ready by its author, so reviewing one wastes a dispatch; it
    reappears automatically once the author flips it out of draft)
  - **Live**: `d` display mode, `H` hidden, `S` quick-switch,
    `N` repo-name cap (short/medium/full),
    `E` PRs (4-way cycle: off/PR/pipeline/both),
    `y` symbol style (ascii/emoji), `t` tile (cycles desired tile
    count `off → 2 → 3 → 4 → off`; the count is persisted via
    `decknix--sidebar-state-file` and auto-applied on every sidebar
    refresh, so setting `t` to `2` before resuming Previous sessions
    engages tiling the moment the second buffer comes up. Label
    shows `[off]`, `[N]` when active, or `[N pending]` when waiting
    for more live buffers; capped at upstream's 8)
  - **WIP**: `L` hide linked (PRs that are already live as sessions),
    `m` stale (hide MERGED/CLOSED rows — default on, since the row
    has nothing actionable left; flip off when auditing what to
    clean up on disk, #137 — terminal rows surfaced by the toggle-off
    path carry a `⊘` stale badge prefixed to the title and dimmed
    title face so they read as reference-only at a glance, #138),
    `P` pipeline/deploy indicators, `r` ↩/👽 replies-to-me (parallel
    to the Requests triad, independent state because WIP is about
    my own PRs — I usually want to see 🤖/👽 so I can push a fix),
    `n` 💬 comments, `u` 🤖 bot-review
  - **Sessions**: `a` age filter (cycles `all/1d/3d/7d/14d/30d`,
    shares presets with Requests `F`), `V` live-backed (default `[dim]`
    — saved rows whose conversation is currently live render shadowed
    as context; flip to `[hide]` to drop them entirely so Live owns
    them), `h` saved (show/hide the Saved Sessions section — hidden
    by default; Live / Previous / Requests / WIP remain), `U` unknown-ws (hide saved
    rows whose workspace can't be resolved OR whose workspace
    directory has been deleted from disk — e.g. a `git worktree
    remove` that ran after the session was archived, #139). Active
    filters surface in the `Sessions (N)` heading as a `[age: Nd]`
    badge; filter state persists via `decknix--sidebar-state-file`.
- All toggles are advertised in the sidebar footer under a `Toggles`
  heading (press `K` to hide).  Footer items are sorted by the same
  short labels (keys omitted — press `T` for the interactive transient).
  When the sidebar is wide (≥48 cols), Global+Requests and Live+WIP
  sections render side-by-side so the footer does not push content
  off-screen.
- Session ops prefix (`s`): `s s` picker, `s g` grep, `s r` recent.
- Auto-refreshes every 2 seconds (live sessions) plus instant refresh on hub
  file changes.

### Attention (`agent-shell-attention`)
- Global mode-line indicator `AS:n/m` showing pending/active session counts.
- `C-c j` jumps to the next session needing user input.
- `C-u C-c j` prompts with a completion list of all active sessions (annotated
  with Awaiting/Permissions/Running status).
- `C-u C-u C-c j` opens a tabulated dashboard of all agent-shell buffers.
- Tracks status via advice on `agent-shell--send-command` and
  `agent-shell--on-request` — no custom process sentinels needed.

### Multi-Session Concurrency
Multiple agent-shell sessions run **independently and concurrently**. Each
buffer has its own process. Switching away from a session does NOT pause it —
the agent continues working in the background. The attention indicator and
workspace sidebar surface which sessions need attention.

### Focus Steal (`decknix-focus`, default off)
- Optional: when enabled, Emacs raises its frame to the foreground when
  work needs your attention — complementing the passive attention
  indicator (`AS:n/m`). Off by default so attention never steals focus
  unless you opt in.
- 3-state cycle (`T` → Global → focus, key `g`; or the footer `focus`
  label): `off` → `attention` → `both`.
  - `attention`: raise the frame when a backgrounded session enters a
    `waiting` / needs-input state. Edge-triggered (once per transition)
    and skipped when you are already looking at that session.
  - `both`: also raise the frame when a new session is created (e.g. an
    auto-review dispatch). Wired as `:after` advice on
    `decknix--agent-quickaction-start`.
- The attention transition is detected in `decknix--header-build` (the
  per-buffer header timer), which calls `decknix-focus-note-status`
  under an `fboundp` guard. On the background daemon
  (`ProcessType=Background`) `raise-frame` alone can't pull the app
  forward, so an async `osascript … activate` is issued on macOS GUI
  frames.
- Seeded from `programs.emacs.decknix.ui.focus.steal`
  (`"off"` / `"attention"` / `"both"`); runtime cycling persists via
  `decknix--sidebar-state-file` and overrides the Nix default on reload.
- Navigation: `C-c A o` jumps to the sidebar window; `C-c A j`
  (`agent-shell-attention-jump`) jumps the other way, to the next
  session needing input. Pure decision layer + ERT tests live in
  `agent-shell/focus/decknix-focus.el`.

### Priority View (`decknix-priority`, opt-in)
- A ranked, lane-based "what to do next?" view over the hub's existing
  data, opened in a standalone read-only `*Agent Priority*` buffer. Off
  by default; enable with
  `programs.emacs.decknix.agentShell.hub.priority.enable = true`, which
  binds `C-c A p`. (Issue #142, phase 1.)
- Four ordered lanes, highest-leverage first: **Discussions** (a human
  awaits my reply on a PR) → **Reviews** (PRs awaiting my verdict) →
  **Tasks** (my non-done Jira issues) → **Queue** (my open WIP PRs).
  Within a lane, directly-mentioned items rank first, then oldest first.
- Derived from existing hub sources only (`decknix--hub-reviews`,
  `decknix--hub-wip`, `decknix--hub-jira-tasks`): a PR with
  `replies_to_me` moves to Discussions; terminal (merged/closed) WIP PRs
  and done tasks are excluded.
- In the buffer: `RET` opens the item URL, `g` refreshes, `q` quits.
- The decision layer (lane classification, ranking, `collect`) is pure
  and ERT-tested in `agent-shell/priority/decknix-priority.el`; the
  renderer reads the live hub defvars via `bound-and-true-p`, so the view
  is additive — no change to the main sidebar render path. Later phases
  (sidebar live-view mode, pins, generic GitHub Actions Queue enrichment)
  are tracked in #142 / #141.

### Output Formatting (`decknix-agent-table`, `decknix-agent-copy-region`)
- The agent emits raw markdown; the comint buffer renders it literally
  (collapsed tables, `**bold**`, `### head`).  Two pure, ERT-tested
  carved cores plus a thin command layer address this:
  - `agent-shell/table/decknix-agent-table.el` — parse a GFM table and
    re-render it **aligned** (columns padded so pipes line up) or, when
    the aligned width would exceed a target width, **reflowed** into a
    per-row bullet block with `- Header: value` sub-items.  All pure
    string transforms (`-parse`, `-render-aligned`, `-render-reflow`,
    `-aligned-width`, `-format`, `-transform-blocks`, `-block-bounds`).
  - `agent-shell/copy-region/decknix-agent-copy-region.el` — pure
    converters markdown → Slack mrkdwn / plain / table-normalised
    markdown, plus a pandoc-backed HTML path.  PDF export (`P`) is a
    file artefact: pure `pdf-engine`/`pdf-command`/`default-name` helpers
    (engine auto-detected from a preference list, ERT-tested) feed a thin
    `md->pdf` that shells out to pandoc + the engine.  `pandoc` and a PDF
    engine (`typst` by default) are installed via `home.packages` so this
    works after `decknix switch` with no manual install — gated by
    `agentShell.copyRegion.pandoc.enable` / `.pdfEngine` (set the engine
    to `null` for bring-your-own).  Also hosts the
    interactive commands and the `C-c x` transient (copy-as `m`/`s`/`h`/
    `p`, export-to-file `P` PDF, reformat-table `t`).  Per Rule 2 the
    commands live in the package (side effects only when invoked); only
    the key binding is in the heredoc.
- **Slack mapping** follows docs.slack.dev: `*bold*` (single star),
  `_italic_`, `~strike~` (single tilde), `<url|text>` links, headings →
  a bold line (Slack has no headings), `&`/`<`/`>` HTML-escaped, and
  tables wrapped as an aligned code block.  Bold is collapsed via
  sentinel chars *before* the italic pass so `**x**` → `*x*` is not
  re-eaten by the single-star italic rule.
- **Bindings** (D-C: both): `C-c x` is bound buffer-locally in
  agent-shell buffers and on `markdown-mode-map` (so it also covers the
  derived `decknix-agent-review-mode`).  `C-c y` is reserved for
  yasnippet, hence `C-c x`.
- The on-demand reformat (`C-c x t`) is width-aware: it aligns, or
  reflows to bullets when the aligned table would be wider than the
  window.  It honours `inhibit-read-only` since the user invokes it
  explicitly.
- **Auto overlay** (`agent-shell/table/decknix-agent-table-overlay.el`,
  shipped as an `extraSiteFiles` sibling of the table core): lays a
  `display` property over each table block carrying the aligned/reflowed
  rendering, leaving buffer text raw (so copy stays raw).  Two drivers,
  both wired in the heredoc: `:after` advice on `markdown-overlays-put`
  re-paints agent-shell output, and `decknix-agent-table-overlay-mode`
  (jit-lock-driven) paints review/markdown buffers incrementally
  (added to `decknix-agent-review-mode-hook`).  Gated by
  `programs.emacs.decknix.agentShell.tableOverlay.enable` (default on);
  the runtime flag is `decknix-agent-table-overlay-enable`.  Pure
  block→offset mapping (`decknix-agent-table-block-offsets`) keeps the
  overlay placement testable.

### Inline Review (`decknix-agent-review-mode`)
- Derived from `markdown-mode`. Captures the last exchange (prompt +
  response) from an agent session into a `*agent-review: <name>*` buffer
  with a read-only preamble describing the Option-1 reply contract.
- Entry points: `C-c A v` / `C-c v` in a session buffer, or `v` on a live
  row in the workspace sidebar (also reachable via `a v`). Prefix arg
  captures the full history instead of just the last exchange.
- Annotation snippets (yasnippet, `,` prefix, TAB to expand):
  `,c` comment, `,a` approve, `,r` reject, `,o` option, `,A` agent reply,
  `,m` mention (consult-style picker over persisted collaborators),
  `,f` follow-up. Identity resolves via `user-login-name`; collaborators
  are persisted to `~/.config/decknix/review-collaborators.el`.
- Follow-up stash: `C-c C-f` flags the paragraph near point and records a
  JSON entry in `~/.config/decknix/review-followups.json` with id, ts,
  session, workspace, author, title, and status. `C-c C-l` lists stashed
  items via completing-read with sub-actions `[d]one / [o]pen / [x]delete
  / [c]opy-id`.
- Submit/route (`C-c C-c`): `a` sends back to the source agent-shell
  (reusing compose's busy-prompt interrupt/queue dance), `p` copies to
  the kill-ring for PR comments, `j` writes a draft under
  `~/.config/decknix/review-jira-drafts/`, `f` saves to a user-chosen
  path. `q` cancels. The agent route strips the `🧭 review meta` header
  but preserves the `📋 instructions` block.

### In-Emacs Browser (`xwidget-webkit`)
- Hub items (PRs, links from the sidebar) open in `xwidget-webkit` by
  default via `decknix--open-url`. Subsequent opens **reuse the same
  WebKit buffer** so the workspace doesn't accumulate one buffer per
  link; pass a prefix arg (or set `decknix--use-xwidget-webkit` to nil
  for the system browser) to force a fresh session.
- WebKit buffers always land in the **main area** of the Agents tab,
  never inside the sidebar — enforced by `display-buffer-alist` matching
  `*xwidget-webkit*` and `*WebKit:`.
- Bindings follow two principles:
  1. **Motion is universal Emacs** — no need to relearn keys for the
     WebKit view. The xwidget DOM is opaque to Emacs, so JS-bridged
     scrolling is wired to the standard motion commands.
  2. **Mode-local commands live on `C-c C-<letter>`** — the Emacs
     major-mode convention used by org, magit, comint,
     `agent-shell-mode`, and `decknix-agent-review-mode`.
  EWW-aligned single-letter shortcuts are kept as a secondary tier for
  users with EWW muscle memory.

| Key | Command | Notes |
|-----|---------|-------|
| `C-n` / `C-p` | line scroll | JS-bridge to `xwidget-webkit-scroll-up-line`/`-down-line` |
| `C-v` / `M-v` | page scroll | bridge to `xwidget-webkit-scroll-up`/`-down` |
| `M-<` / `M->` | top / bottom of page | bridge to `-scroll-top`/`-scroll-bottom` |
| `SPC` / `DEL` (or `S-SPC`) | page forward / back | view-mode/EWW/Info convention |
| `s` | **find on page** (consult-line over `innerText`) | vertical candidate list + live preview; scrolls + highlights via `window.find` |
| `C-s` / `C-r` | in-page search (incremental) | JS-bridged isearch shim, kept alongside `s` for users who prefer incremental search |
| `TAB` / `S-TAB` | next / previous focusable | cycles links, buttons, inputs |
| `g` | reload | EWW-aligned |
| `l` / `r` | back / forward | EWW-aligned (history nav) |
| `&` | open in system browser | EWW-aligned |
| `w` | copy URL | EWW-aligned |
| `+` / `-` | zoom in / out | |
| `q` | quit window | |
| `C-c C-s` | find on page (consult-line) | primary-tier alias for `s` |
| `C-c C-r` | reload | primary tier |
| `C-c C-b` | back | primary tier |
| `C-c C-f` | forward | primary tier |
| `C-c C-o` | open current URL in system browser | |
| `C-c C-u` | prompt for new URL | |
| `C-c C-y` | copy URL | |
| `C-c C-w` | copy as markdown link `[title](url)` | |
| `C-c C-e` | switch to EWW (real Emacs buffer; consult-line, embark, occur work) | |
| `C-c C-i` | focus first text input on the page | |
| `C-y` / `s-v` | paste system clipboard into the focused `<input>` / `<textarea>` / contenteditable. xwidget intercepts native paste so password fields can't otherwise receive clipboard text; both the universal Emacs `C-y` and the macOS GUI `Cmd+V` are bridged to the same JS-inject command (today's `yank` in xwidget is a no-op against the read-only buffer, so nothing useful is displaced). macOS Passwords autofill stays Safari-only — manual "Copy from Passwords → `C-y`" is the workflow. |

### Key Prefix Map

| Prefix | Purpose |
|--------|---------|
| `C-c A` | Agent commands (global) |
| `C-c A b` | Switch agent buffer — live buffers only, MRU ordered (#96) |
| `C-c A s` | Session picker (sectioned: Live / Saved / New); `C-u` for all snapshots (#77) |
| `C-c A g` | Grep sessions — consult + ripgrep full-text search across all session content. Default fast path uses ripgrep + the in-memory session metadata cache (sub-second). Two-stage flow: pick a session, then the buffer opens **and jumps to the first match** of the typed term (case-insensitive); if the match is outside the loaded `decknix-agent-session-history-count` exchanges the buffer falls back to the prompt and the minibuffer reports it. `C-u` expands snapshots; `C-u C-u` runs the **thorough** path (parallel jq re-parse, ~5s) which finds sessions written since the last cache refresh; `C-u C-u C-u` combines expanded + thorough |
| `C-c A n` | New session |
| `C-c A q` | Quit/close session (switch to next or welcome) |
| `C-c A c` | Commands — quick actions and custom commands |
| `C-c A c r` | Review PR (quick action) |
| `C-c A c B` | Batch process (multi-session launcher) |
| `C-c A c c` | Run custom command (pick & insert) |
| `C-c A c n` | New custom command |
| `C-c A c e` | Edit custom command |
| `C-c A w` | Toggle Agents workspace tab (tab-bar with sidebar) |
| `C-c A j` | Jump to next session needing attention; `C-u` to pick, `C-u C-u` dashboard |
| `C-c A o` | Jump to the agent sidebar window (opens the Agents workspace if hidden) |
| `C-c A p` | Priority view (opt-in via `hub.priority.enable`): ranked lanes in `*Agent Priority*` |
| `C-c A v` | Review last exchange (inline review buffer); `C-u` for full history |
| `C-c A T` | Tags — global (list/filter conversations, rename, delete, cleanup) |
| `C-c s t` | Tags — conversation-scoped (show, add, remove) — in-buffer only (#78) |
| `C-c W` | Sidebar action transient — open Navigate / Quick / Actions / Toggles (`T`) from any agent-shell buffer |
| `C-c D` | Deckmacs — framework management (reload, status, diff, log) (#85) |
| `C-c D r` | Reload default.el from current Nix profile; `C-u` to force |
| `C-c D s` | Show framework status (loaded/current store paths, staleness) |
| `C-c D d` | Show diff between loaded and current store paths |
| `C-c D l` | Show reload history log |
| `C-c b` | Switch agent buffer — live buffers only (#96) |
| `C-c s g` | Grep all session content (in-buffer shortcut for `C-c A g`) |
| `C-c s R` | Restart current session in place — re-resumes the conversation (revives `killed` buffers, preserves history); in-buffer only |
| `C-c s c` | Toggle inline Context history section (▶/▼) — in-buffer only |
| `C-c s [` / `C-c s ]` | Page restored Context window to older / newer turns (#136). Also bound on the Context header itself as `[` / `]`. Header line shows `Context (a–b / N)` so the cursor position is discoverable. Cross-window jump-to-match: `C-c s g` selecting a hit outside the loaded window now seeds the cursor so the matched turn lands at the bottom and `point` lands on the match |
| `C-c i` | Context panel (in agent-shell buffers) |
| `C-c w` | Toggle Agents workspace (in-buffer shortcut) |
| `C-c j` | Jump to pending session (in-buffer shortcut) |
| `C-c v` | Review last exchange (in-buffer shortcut for `C-c A v`) |
| `C-c x` | Copy region as… / export / reformat table — transient (`m` markdown, `s` Slack mrkdwn, `h` HTML, `p` plain, `P` PDF file, `t` reformat table). Bound in agent-shell + markdown/review buffers |
| `C-c C-c` | Route review (review-mode only) |
| `C-c C-f` | Flag paragraph as follow-up (review-mode only) |
| `C-c C-l` | List stashed follow-ups (review-mode only) |
| `RET` | Sidebar: open the row's Action Menu transient (#123) |
| `M-RET` / `C-u RET` | Sidebar: run the row's primary action (open URL for hub rows) |
| `R` / `W` / `S` | Sidebar: open Review / Worktree / Session submenu for the row at point (spec §3.7) |

### Planned Features

- **Sub-agent tree** — Show spawned sub-agents as children in sidebar (#95) (Planned)
- **Hub: Slack adapter** — Unread mentions requiring follow-up (Planned)
- **Hub: Cross-linking** — Associate sessions with work items (reviews, tasks) (Planned)
- **Hub: Expandable Recent** — Expand a saved session to see related work items (Planned)
- **Hub: macOS notifications** — New review requests, CI failures (Planned)
- **Worktree-aware sessions** — git worktree per agent session (#69):
  registry / submenu / row badges shipped (#128, #129, #130).  Auto-create
  a worktree on `C-c A n` based on a chosen branch, and have session creation
  default `--workspace-root` to the worktree path, still pending.
- **Session board** — magit-style multi-session dashboard (#70) (Planned)
- **Session templates** — engineering, review, support workflows (#71) (Planned)
- **Automation** — push notifications, auto-created sessions (#72):
  auto-review (auto-dispatch review sessions for incoming @-mentioned
  PRs, `T → Requests → A`) and focus-steal (raise the frame on
  attention / new session, `T → Global → focus`) shipped; push
  notifications still (Planned)
- **Priority view** — ranked lane-based "what to do next?" (#142):
  phase 1 (standalone `*Agent Priority*` buffer over existing sources,
  `C-c A p`) shipped; sidebar live-view mode, pins, and generic GitHub
  Actions Queue enrichment (#141) still (Planned)
- **Full I/O decoupling** — hide comint prompt, read-only output (#67) (Planned)

## Keybinding Conventions

- Global agent prefix: `C-c A` (capital A)
- Framework prefix: `C-c D` (capital D — Deckmacs)
- Module-local prefix: `C-c <lowercase>` (e.g., `C-c i` for context)
- Compose mode: `C-c C-c` submit, `C-c k` interrupt sub-map, `C-c C-s` toggle
- Compose history: `M-p`/`M-n` local (current session), `M-P`/`M-N` global (all sessions)
- Batch compose: `C-c C-c` submit, `C-c C-k` cancel
- Always add `which-key` labels for new prefix maps

## Agent Response Formatting in Agent Shell

The user-level `~/.augment-guidelines` (generated by `agent-shell.nix`) bans
two categories of output in conversational responses inside the agent-shell:

1. XML tool-call narration: text like `<parallel_tool_calls>`, `<tool_call>`,
   or any angle-bracket pseudo-invocation. The correct behaviour is to execute
   tool calls natively and then summarise in plain prose. Narrating planned
   calls as XML is a model failure mode — the guidelines explicitly forbid it.

2. Markdown syntax: the comint buffer renders text as-is — `**bold**`,
   `| pipes |`, and `# heading` all show as literal characters. Space-aligned
   columns replace pipe-delimited tables; prefix labels (`Note:`, `Warning:`)
   replace bold emphasis.

Markdown remains correct for files, PR bodies, commit messages, and any tool
input that renders it. Future contributors must not paste markdown-heavy or
XML-heavy examples into the guidelines heredoc as model demonstrations.

