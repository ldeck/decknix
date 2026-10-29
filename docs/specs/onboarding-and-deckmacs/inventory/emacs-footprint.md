# Inventory: Emacs footprint, coupling and naming

Snapshot of `main` at `2d9316d7`. Counts are grep-based and may be off by a few percent. Paths are relative to `modules/home/options/editors/emacs/` unless they start with another top-level directory.

## 1. Size and structure

- 353 `.el`, 17 `.nix`, 25 `.md`, 3 `.rtf`, 1 `.sh` across 99 directories; about 125k lines total.
- Elisp outside tests: about 64k lines. Tests: 180 files, about 41k lines, 3,356 `ert-deftest`, all in `agent-shell/tests/`.
- Nix modules (about 13.9k lines): `agent-shell.nix` 8,546; `org.nix` 787; `welcome.nix` 734; `lsp.nix` 684; `languages.nix` 626; `ui.nix` 473; `default.nix` 453; `deckmacs.nix` 371; `magit.nix` 269; `completion.nix` 170; `treemacs.nix` 156; `editing.nix` 128; `recording.nix` 122; `development.nix` 106; `http.nix` 99; `undo.nix` 75; `project.nix` 71.
- `agent-shell.nix`: package derivations at lines 1 to 3080, options 3081 to 3340, then an Elisp `extraConfig` heredoc from `:3622` to the end (about 4.9k lines).
- Largest carved packages under `agent-shell/`: workspace-bulk (about 7.7k lines), main-bulk (7.3k), agent (6.1k), hub-bulk (4.2k), hub (3.8k), sidebar-layout (2.8k), board (2.5k), review-board (1.8k), sidebar (1.7k), progress (1.6k); about 75 more between 43 and 1,000 lines.
- Build: `mkEmacsTestedPackage` (`agent-shell.nix:116-203`) wraps `trivialBuild`, byte-compiles, runs the named ERT files in `postBuild` (a red test fails the system build), installs only the package's own files, then native-compiles. 156 such derivations plus 7 plain `trivialBuild` vendored packages (`agent-shell.nix:45-104`).

## 2. Option namespace

- Everything under `programs.emacs.decknix.*`, root at `default.nix:17` (`enable` default true).
- Sub-namespaces: agentShell, deckmacs, completion, http, editing, org, magit, treemacs, development, languages, ui, project, recording, lsp, undo, welcome. About 109 options.
- Nearly all default on. Off: `agentShell.hub.priority.enable`, `agentShell.broker.enable` (`agent-shell.nix:3141,3158`), `lsp.kotlin.useJetBrainsLsp` (`lsp.nix:238-240`).
- Daemon: `services.emacs.decknix.{enable,package,additionalPath}` (`modules/darwin/emacs.nix:45-60`).

## 3. Coupling to decknix CLI, hub, broker and launchd

Emacs calling the `decknix` binary:
- `agent-shell/archived/decknix-agent-archived.el:27,125,135`: `decknix session list --archived --json`, `decknix session restore`.
- `agent-shell/repo-sync/decknix-repo-sync-actions.el:108`: `decknix repos sync`, `fix-lock`; reads `~/.config/decknix/repo-sync.json` (`decknix-repo-sync.el:42`) written by `cli/src/repo_sync.rs`.
- `agent-shell/hub-bulk/decknix-agent-shell-hub.el:2007-2008`: `decknix repos list --json`.
- `agent-shell/hub-wt-stale/decknix-hub-wt-stale.el:137`: `decknix wt audit --json`.
- `agent-shell/workspace-bulk/decknix-agent-shell-workspace.el:4800` (also 1252, 5120) and `decknix-worktree-picker.el:817`: `decknix wt ...`.

Broker:
- `agent-shell/session-broker/decknix-agent-session-broker.el:40-71` wraps argv with `decknix-agent-broker-attach` (`agent-shell/scripts/decknix-agent-broker-attach.sh`; package `pkgs/decknix-agent-broker`).
- `broker-rehydrate/...:256` and `broker-reattach/...:133` use `$XDG_STATE_HOME/decknix/agent-sockets`, shared with `cli/src/session.rs`.

Hub: no socket. Emacs reads JSON the `decknix-hub` daemon writes under `~/.config/decknix/hub/` (`github-wip.json`, `jira-tasks.json`, `teamcity-*.json`, `github-reviews.json`, `meta.json`; list at `agent-shell/hub/decknix-hub-sidebar-paint.el:288-291`; writers in `pkgs/decknix-hub/src/{main,jira,teamcity}.rs`).

Shared session store: `~/.config/decknix/agent-sessions.json`, used by `cli/src/session.rs`, `cli/src/main.rs`, `modules/home/options/cli/auggie.nix`, and Emacs (`agent-shell.nix:1533`). Two constants must match across languages: `cli/src/session.rs:34,36` vs `decknix--agent-conv-key-canonical-length` and `decknix--agent-tags-canonical-key-version`.

Reverse coupling (decknix knows deckmacs symbols):
- `cli/src/main.rs:1015-1016`: `decknix switch` evaluates `deckmacs--loaded-store-path` and `(fboundp 'deckmacs-reload)`; `:1045`, `:1051-1116` kickstart hint and graceful `kill-emacs`.
- `modules/darwin/emacs.nix:151`: evaluates `deckmacs--loaded-store-path` and `deckmacs--resolve-current-default-el`.
- `pkgs/nix-open/src/main.rs:44,306`: polls emacsclient.

Other: an org-specific CLI is called from `dos-board/decknix-dos-board.el:53` and `support-dashboard/decknix-support-dashboard.el:825`, and calls back via emacsclient (`:907`). These are org-specific; slice 5 moved them, with their tests, to the org DoS tooling repo.

## 4. Identifier naming

- 3,542 unique defined symbols with the `decknix` prefix outside tests (1,704 private `decknix--`); 17 with `deckmacs`, all in `deckmacs.nix`; 374 more in tests.
- By form: 2,488 defun, 479 defvar, 160 defconst, 115 defvar-local, 113 defcustom, 139 transient suffixes and prefixes, 47 defface, 19 derived modes, 16 defgroup. `:group 'decknix` appears 95 times; no `(defgroup decknix ...)` found (unverified).
- 173 features `(provide 'decknix-...)`; none `deckmacs`. 156 Nix `pname = "decknix-..."`.
- Every Nix option name in the module contains `decknix` via `programs.emacs.decknix`.

Categories (approximate, boundaries unverified):
- (a) decknix integration (CLI, hub files, broker, sessions, repo-sync, worktrees): about 700 to 850 symbols. Packages: session-broker, broker-*, archived, repo-sync, hub-wt-stale, hub caches, hub-lookup, parts of hub-bulk and agent (session cache, session id), session-assoc, live-sessions.
- (b) Emacs-only UI (should be `deckmacs-`): about 2,700 to 2,800 symbols, 75 to 80 percent. Largest: workspace-bulk 364, main-bulk 263, board 232, sidebar-layout 190, review-board 111, sidebar 109, progress 99, support-dashboard 70, layout-persist 65, session-board 53, forge-board 50, welcome 48, context 48, org.nix 37, header 36.

Rename hazards:
- `deckmacs.nix:112,146` unloads features and strips advice by `string-prefix-p "decknix-"`; a partial rename silently breaks hot-reload.
- Buffer names already read `*deckmacs: Session Board*` and `*deckmacs: Forge Board*` (`session-board/decknix-session-board.el:34`, `forge-board/decknix-forge-board.el:57`), matched by `layout-persist/decknix-layout-persist.el:120`.
- `agent-shell.nix:7293-7302` adds sidebar save/restore to `deckmacs-pre-reload-hook` and `deckmacs-post-reload-hook`.
- The reference org overlay ships Elisp (a board and an inbox) loaded from `programs.emacs.extraConfig` that calls `decknix-` symbols; it must move in the same coupled change.

Existing deckmacs mentions: `deckmacs.nix` (issue #85), `agent-shell.nix` (4980, 6187, 6218, 7281-7390), `recording.nix:14,46,51`, the emacs `AGENTS.md`, five packages, one test, `cli/src/main.rs:1016`, `modules/darwin/emacs.nix:151`, `docs/src/modules/ai/agent-shell/comparison.md:20`; 7 commits mention it in their subject.

## 5. State and file paths

Shared with CLI or hub (paths must stay, or change in both repos together):
- `~/.config/decknix/agent-sessions.json`
- `~/.config/decknix/repo-sync.json`
- `~/.config/decknix/hub/{github-wip,jira-tasks,teamcity-deploys,teamcity-builds,github-reviews,meta}.json`
- `~/.config/decknix/hub/worktrees.el` (`hub-bulk/decknix-agent-shell-hub.el:1788`, also `cli/src/main.rs`)
- `~/.config/decknix/boards/` (`board/decknix-board.el:83`, also `ai/gortex.nix`)
- `$XDG_STATE_HOME/decknix/agent-sockets/`
- `~/.config/decknix/hub/stray.txt` (writer unknown)

Emacs-only (can move to deckmacs paths):
- `~/.config/decknix/sidebar-state.el`, `agent-previous-sessions.el`, `agent-previous-history.el` (`sidebar/decknix-sidebar-previous.el:13,87,122`)
- `agent-live-sessions.el` (`agent-shell.nix:644`), `agent-dismissed-sessions.el` (`live-sessions/...:29`)
- `agent-progress/<key>.json` (`progress/decknix-progress.el:749,756`)
- `agent-scatter.log`, `agent-deaths.log`, `session-watches.el`
- `review-collaborators.el`, `review-followups.json`, `review-jira-drafts/`
- `hub/{pr-cache,pr-memory,repo-cache,sidebar-layout,worktree-clones,worktree-picker-state}.el`, `hub/session-meta.eld`
- `$XDG_STATE_HOME/decknix/boards/NAME.md`, `emacs-layout.el`, `session-prs.eld`
- `user-emacs-directory`: `decknix/layout-groups.el`, `decknix-prompt-probe.log`, `backups`
- `$XDG_CACHE_HOME/decknix/kotlin-lsp-gradle` (`lsp.nix:116`)
- `~/Recordings/decknix` (`recording.nix:23`)

Migration implication: Emacs-only files need move-with-marker plus fallback reads, or sidebar toggles, previous sessions, layouts and review drafts are silently lost. On the reference machine `~/.config/decknix` holds about 17 `agent-sessions.json.bak*` copies and `$XDG_STATE_HOME/decknix/agent-sockets` has 1,136 entries, so the migration must be cheap on large directories.
