# Onboarding, adoption tiers, uninstall and the deckmacs split

Status: approved 2026-10-29 with the decisions in section 13; layering (section 6.0) approved 2026-10-30. Slices 1 and 2 have landed on `main` locally.

Supporting inventories (evidence for every claim below):

- [inventory/current-state.md](inventory/current-state.md): installer, template, loader, CLI, launchd services, home modules, docs staleness.
- [inventory/emacs-footprint.md](inventory/emacs-footprint.md): Emacs size, coupling to the CLI/hub/broker, identifier naming, state paths.
- [inventory/org-overlay.md](inventory/org-overlay.md): what an org config overlay adds today and which parts are optional.
- [inventory/uninstall-artifacts.md](inventory/uninstall-artifacts.md): everything a full uninstall must handle, with risk notes.

Slice plan: [slices.md](slices.md).

Line references are to `main` at `2d9316d7` unless stated. "Unverified" marks an inference that was not run or traced end to end.

## 1. Problem

decknix started as "pick a role, install a machine". It has since grown into a large, batteries-included system:

- About 14k lines of Nix and about 105k lines of Elisp under `modules/home/options/editors/emacs/`, with 3,356 ERT tests run inside the build (see emacs inventory).
- A Rust CLI (`cli/src`, about 6.3k lines) whose commands cover switch, update, worktrees, sessions, repos and agent-artifact sync, but not install, uninstall, init or doctor (`cli/src/main.rs:29-94`).
- Five launchd user agents and three system daemons, most on by default (`modules/darwin/*`).

The onboarding path has not kept up:

- The documented one-line install 404s: `docs/src/getting-started/installation.md:16` and `README.md:12` fetch `bin/bootstrap`; the file is `bin/bootstrap.sh` (HTTP 404 vs 200, checked 2026-10-27).
- `bin/bootstrap.sh` is all or nothing: install Nix, move `/etc` shell files aside with sudo, `nix flake init`, `darwin-rebuild switch`. There is no plan screen, no tier choice, no verify step, no uninstall.
- `decknix.role` is accepted but does nothing (`modules/home/options.nix:46`, `_internal.templates` at `:79` is never read).
- An org overlay is wired in by hand-uncommenting template lines, or (in the reference overlay) by a `sed -i` edit of the user's `flake.nix` that depends on the template's exact text.
- The docs are visibly stale in at least 11 places, and the options reference omits 14 option-declaring home modules and all darwin modules.

Meanwhile a smaller sibling installer in a private org project showed a much gentler path: idempotent, asks before each change, `--yes` for automation, Determinate installer, flakes enabled in the user `nix.conf` only, a verify step, printed login hints, never writes secrets, and whole-script tests with PATH stubs. That is the bar for the first rung of the ladder.

Separately, the Emacs configuration has become a product of its own. Its identifiers mostly carry the `decknix-` prefix even though roughly 75 to 80 percent of them are Emacs-only UI (emacs inventory section 4). It should live in its own repository, `ldeck/deckmacs`, with decknix shipping a simple default.

## 2. Goals

1. A single entry point that installs exactly the tier the person chooses, shows a plan before changing anything, and can be re-run to add or remove tiers.
2. A gentle first rung: Nix with flakes and nothing else, enough to use any flake-based project (including the org's Nix build pipelines).
3. Clean, verified uninstall, per tier and in full, that never touches the person's data.
4. Extract the advanced Emacs configuration into `ldeck/deckmacs` with history, rename Emacs-only identifiers to `deckmacs-` with obsolete aliases, and migrate state paths without data loss.
5. decknix ships a basic default Emacs and offers deckmacs as tier 4 (the editor) and tier 5 (agent workspace and boards).
6. Org overlays declare their optional components so the installer can offer them; the overlay never has to edit the user's flake text.
7. Docs that are current, organised by tier, and kept current by CI (generated options and CLI reference, link check).
8. People who adopt the higher tiers need no bespoke Homebrew installs; people who keep Homebrew are not fought.
9. decknix and deckmacs are public and carry no association with any particular organisation: no org names, repositories, chat channels, issue trackers or org overlays in their code, docs, tests or history (decknix's history is scrubbed once, slice 6).
10. The working checkouts follow a predictable layout: personal projects in one personal workspace, org projects in the org workspace, each checkout named after its repository (section 14).

## 3. Non-goals

- Changing how the org's Nix build pipelines work. Those projects are owned elsewhere; decknix only needs to provide a machine they work on (section 10).
- NixOS system configuration, and tiers 1 and above on Linux. Linux gets tier 0 only for now (decision 5).
- Rewriting the agent-shell feature set. The deckmacs work is a move, a rename and a seam, not a redesign.
- Managing Mac App Store apps, vendor installers or company endpoint agents.
- A GUI installer.

## 4. Personas

- **Curious developer.** Wants Nix and flake dev shells for one or two repos. Will not hand their shell or `/etc` to a framework on day one. Needs: tier 0 only, fully reversible with one command.
- **AI-agent user.** Wants Claude Code, Pi, Gemini and friends installed and configured, plus the org's shared skills and commands. Happy with nix-darwin and home-manager, not interested in Emacs. Needs: tiers 1 and 2, plus the org AI component.
- **Workstation adopter.** Wants decknix to replace Homebrew: GUI apps, fonts, window manager, Linux builder for container builds. Needs: tier 3 and a Homebrew migration report.
- **Editor user.** Wants a good Emacs without the agent features. Needs: tier 4 only (deckmacs editor), usable without decknix's services.
- **Full decknix user.** Emacs as the cockpit: deckmacs, agent-shell, hub, broker, boards, launchd services. Needs: tier 5 and every org component.
- **Org config adopter (orthogonal).** Any of the above who also layers an org overlay: identity, git hooks, org services, org AI artifacts. Needs: per-component choice, secrets prompts that never go near the Nix store.

## 5. Adoption ladder

Tiers are cumulative. Each tier lists what it installs, where it comes from, and how to reverse it.

**Tier 0: Nix**
- Installs: upstream Nix via the Determinate installer (decision 3), flakes enabled in `~/.config/nix/nix.conf` only, optional direnv and nix-direnv via `nix profile`. GitHub access for private flakes is by env var only (`NIX_CONFIG="access-tokens = github.com=$(gh auth token)"`); tier 0 never writes a token file (decision 10).
- Platforms: macOS and Linux (decision 5). Every other tier is macOS only for now.
- Repos/flakes: none beyond nixpkgs. No decknix checkout, no nix-darwin, no home-manager.
- Reversible: `/nix/nix-installer uninstall` plus removal of the marker-guarded nix.conf and rc lines. The installer prints both.
- Enough for: any flake project, including the org's Nix build pipelines (they need Nix with flakes and a GitHub token for private inputs, and ship no dev shells; org overlay inventory section 7).

**Tier 1: Base**
- Installs: nix-darwin and home-manager through `decknix.lib.mkSystem`, a generated user flake in `~/.config/decknix`, the `decknix` CLI (switch, update, install, adopt, uninstall, doctor), zsh, starship, git, core CLI tools, Vim standard profile. Emacs: the basic default (decision 2). No launchd services.
- Repos/flakes: `github:ldeck/decknix`.
- Reversible: `decknix uninstall --tier 1` runs the nix-darwin uninstaller (which restores `*.before-nix-darwin` files), restores installer backups, removes home-manager links. Leaves tier 0.

**Tier 2: AI agents**
- Installs: the `decknix.ai.*` modules the person ticks (Claude, Pi, Gemini, Codex, OpenCode, Goose, Qwen), agent-sync for any artifact files, Gortex if a roster is configured (Gortex is tier 2, decision 7).
- Reversible: untick and switch. Agent-sync copies are removed only when unchanged since deploy; edited copies are moved to the uninstall backup.

**Tier 3: Workstation**
- Installs: GUI apps from nix-casks, fonts, window manager (AeroSpace, Hammerspoon or OmniWM), Linux builder (on demand), repo-sync and session-gc agents (tier 3, decision 7).
- Reversible: untick and switch, plus leftovers the switch cannot remove declaratively (rsync'ed app copies in `~/Applications/Nix Apps`, the Linux builder disk image under `/var/lib/linux-builder`, about 29.5 GB on the reference machine).

**Tier 4: deckmacs editor**
- Installs: the `github:ldeck/deckmacs` home-manager module with the Emacs distribution only (editing, LSP, UI) and the Emacs daemon agent. No agent features; usable without the decknix hub or broker.
- Reversible: untick and switch; deckmacs state is kept unless `--purge-state` is given.

**Tier 5: agent workspace and boards**
- Installs: the deckmacs packages `interactive-buffers`, `agent-workspace` and `boards` (section 6.5), plus the decknix services they talk to (hub agent, session broker).
- Reversible: untick and switch; drops back to the tier 4 editor. Session and board state is kept unless `--purge-state` is given.
- Note: slice 2 shipped tiers 0 to 4; tier 5 is added with the installer (slice 3), and until then tier 4 means "deckmacs with everything" as today.

**Org overlay (orthogonal, any tier from 1)**
- The overlay publishes a component manifest (section 6.4). Typical components: identity and git hooks, org AI artifacts, org background services (for example IAP proxies, an MCP server agent), org Emacs packages (require tier 4, or tier 5 when they build on the agent workspace or boards), heavy language tooling.
- Reversible per component, same mechanism as tiers.

**Org DoS tooling (orthogonal, requires the org overlay)**
- The org's support-rotation views (section 6.0) ship from the org DoS tooling repo next to the CLI they drive, and are offered as one overlay component. Requires tier 5.
- Reversible: untick the component and switch.

Existing installs: a machine with a pre-existing `~/.config/decknix` and no adoption file is treated as "everything currently enabled" so nothing changes on upgrade (section 12).

## 6. Design

### 6.0 Layers and where code lives

Approved 2026-10-30. Each layer is one repository (or one directory of one), depends only on the layers below it, and maps onto one installer choice.

1. **decknix** (public, `ldeck/decknix`): the Nix framework (`mkSystem`, modules, adoption tiers), the CLI, the background services (hub, session broker, repo-sync, session-gc), the installer and uninstaller. No Emacs code beyond the basic default (slice 14) once deckmacs exists.
2. **deckmacs** (public, `ldeck/deckmacs`, one repository): the Emacs distribution (editing, LSP, UI) with no agent features and usable on its own, plus a `packages/` directory of separately installable, Nix-packaged Emacs packages with declared dependencies that tests enforce:
   - `interactive-buffers`: the common interactive-buffer framework. Rows and sections, one key grammar for every list buffer, render from cache, refresh scheduling, async fetch, and a shared attention look.
   - `agent-workspace`: the agent-shell extensions (sidebar, sessions, compose, queue, attention, layout persistence). Depends on `interactive-buffers` and on the decknix hub and broker through the checked integration contract (section 6.5).
   - `boards`: boards built on the framework (Review Board, Session Board, coordination boards). Depends on `interactive-buffers`, and on `agent-workspace` where a board acts on sessions.
   A package moves to its own repository only when a consumer outside deckmacs needs it on its own. deckmacs has no association with any organisation (decision 1).
3. **Private org packages**, in two private repositories:
   - **The org DoS tooling repo** (the support-rotation CLI's home) carries the support-rotation views next to the CLI they drive, co-versioned with it: an on-support priority board and worksheet, a support dashboard and a guided support workflow. Its flake exports the CLI and the Emacs package (built and tested as a flake check), and a home-manager module the overlay consumes. The test for placement is what the code drives: anything that renders or drives that CLI or the rotation's tracker board lives here.
   - **The org overlay** carries every other org Emacs package (a pilot board, an agent inbox, snippets, org defaults, org board definitions, org CI check names for the hub) as tested packages behind its `emacs` component, built with a test-running builder. deckmacs will export that builder (`lib.mkTestedPackage`, slice 8); until then the overlay carries a copy of the builder decknix uses today.

Installer choices map onto layers, and uninstall works per layer:

- Nix only: tier 0.
- decknix base: tier 1 (and tier 3 workstation, which stays a decknix layer).
- AI agents: tier 2.
- deckmacs editor: tier 4.
- Agent workspace and boards: tier 5.
- The org overlay: the overlay's components (section 6.4).
- The org DoS tooling views: one overlay component sourced from the org DoS tooling repo; requires tier 5.

Removing a layer removes every layer that depends on it, and the plan screen lists them before anything changes (section 6.3).

### 6.1 Adoption state

- A machine-written file `~/.config/decknix/adoption.toml` records the chosen tier and component toggles. The installer and `decknix adopt` own it; people may edit it by hand.
- `mkSystem` reads it with `builtins.fromTOML` and maps it onto a new option tree `decknix.adoption.*` (tier, plus per-component `enable`).
- Module defaults change from unconditional `mkDefault true` to `mkDefault (tierAtLeast N)`. Personal overrides in `local/` still win, as today.
- This replaces `decknix.role` and the unused `_internal.templates`. `role` becomes a renamed/obsolete option mapping `minimal` to tier 1 and `developer` to the current full set.
- A `decknix.adoption.manifest` derivation, written at switch time to `/etc/decknix/manifest.json`, lists every launchd label, `/etc` file, agent-sync target and non-declarative leftover path the current generation owns. Uninstall and `doctor` read it rather than guessing.

### 6.2 Installer UX

Two stages so the shell part stays small and testable and the logic lives in Rust:

1. **`bin/install.sh`** (replaces `bin/bootstrap.sh`, which becomes a shim that execs it).
   - Entry: `curl -fsSL https://raw.githubusercontent.com/ldeck/decknix/main/bin/install.sh | bash`. Prompts read `/dev/tty` so piping works.
   - Does tier 0 itself, using the sibling installer's proven pattern: platform check, load an existing Nix profile, ask before installing Nix, probe flakes with `nix eval --expr 'builtins ? getFlake'`, marker-guarded append to `~/.config/nix/nix.conf`, optional direnv.
   - Hands off to `nix run github:ldeck/decknix#decknix -- install "$@"` for tier 1 and above.
2. **`decknix install`** (Rust).
   - Asks for tier, then per-component toggles, then org overlay (none, or a flake ref), then identity fields the overlay declares.
   - Shows a **plan screen** before any change: tier and components, flakes to fetch, files it will create or move (with backup paths), sudo actions, launchd services, secrets it will prompt for, estimated download. `--dry-run` stops here.
   - Generates the user flake from `templates/default` (inputs: decknix, optional org overlay, optional deckmacs; outputs: one `mkSystem` call) plus `settings.nix`, `adoption.toml` and an empty `local/home.nix` and `local/system.nix` with comments marking where personal overrides go. Existing files are never overwritten; a diff is shown instead.
   - Backs up any file it moves to `~/.local/share/decknix/backups/<timestamp>/` and records it in the backup index (used by uninstall).
   - Runs the first switch, then **verify** (`decknix doctor`): CLI on PATH, flake evaluates, each enabled launchd label loaded, each enabled agent CLI answers `--version`.
   - Prints login hints (Claude `/login`, `gh auth login`, `gcloud auth login`, overlay-declared hints). Never performs logins itself.
- **Re-runs** are idempotent: on an installed machine the same command shows the current state and offers to add or remove tiers and components ("update via the installer"). `decknix adopt <tier|component> [--remove]` is the non-interactive equivalent.
- **Non-interactive flags**: `--yes`, `--tier N`, `--with <component>` and `--without <component>` (repeatable), `--org <flake-ref>`, `--dry-run`, `--no-verify`, `--user`, `--host`. `CI=true` or no tty means every prompt answers no unless `--yes`.
- **Private overlays**: a private overlay can be selected by flake ref (`git+ssh://...`) once SSH or `gh` auth works. For a one-command start the overlay may ship its own thin `install.sh` fetched with `gh api repos/<org>/<repo>/contents/install.sh -H 'Accept: application/vnd.github.raw' | bash` that simply calls the decknix installer with `--org <ref>`.
- **Secrets**: the installer prompts only for secrets the overlay manifest declares, stores each with `decknix secrets set <name> --org <org>` (OS keychain; 0600 files under `~/.local/share/decknix/<org>/secrets/` without one), never inside `~/.config/decknix` (copied into the store on every switch), and never passes a secret through Nix evaluation. `--yes` without the matching env var skips the secret and lists it in the summary.

### 6.3 Uninstall UX

`decknix uninstall` and `install.sh --uninstall` (the latter works even when the CLI is broken, by reading the manifest with `jq` from nixpkgs).

- Scope: `--tier N` removes tiers above N-1 (so `--tier 5` keeps the deckmacs editor and drops the agent workspace and boards); `--component X` removes one component, including the org DoS tooling component; `--all` removes everything decknix installed including nix-darwin; `--all --nix` also runs `/nix/nix-installer uninstall`. Removing a layer also removes the layers that depend on it (section 6.0).
- **Plan screen** first, built from `/etc/decknix/manifest.json`, the backup index and the agent-sync manifest. `--dry-run` stops there.
- Order for `--all` (from the artifact inventory; order is unverified until slice 12 exercises it on a VM):
  1. Copy out generated files people rely on as real files (for example a generated `~/.authinfo`) when the plan flags them.
  2. Boot out decknix launchd agents and daemons listed in the manifest.
  3. Remove agent-sync copies whose hash matches the deployed hash; move edited ones to the backup.
  4. Remove non-declarative leftovers (app copies, Linux builder disk, sockets).
  5. Run the nix-darwin uninstaller, which restores `*.before-nix-darwin`; then restore the installer's own backups (including the legacy `*.before-decknix.<ts>` files from `bootstrap.sh`).
  6. Remove home-manager generations and GC roots, including `~/.config/decknix/result`.
  7. Optionally the Determinate uninstaller. A reboot is required to clear `/etc/synthetic.conf` entries; the summary says so.
- **Never touches**: secrets in `decknix secrets` (unless `--purge-secrets` with typed confirmation), `~/.config/decknix/local/`, the user flake itself (kept for reinstall), agent data in `~/.claude`, `~/.pi` and similar beyond files in the agent-sync manifest, source repositories, Emacs state (unless `--purge-state`), Homebrew, App Store and vendor apps.
- **Verify**: `decknix doctor --leftovers` scans every path class in the inventory and reports anything remaining. Slice 12 runs it on a fresh VM after install then uninstall.

### 6.4 Org overlay contract

- An overlay flake exports, alongside `darwinModules.default` and `homeModules.default`, a `decknixOrg` attribute: name, description, components (id, title, description, minimum tier, default on or off, depends on), declared secrets (name, prompt, help URL, required by component), identity fields, and login hints.
- The installer reads it with `nix eval --json <ref>#decknixOrg`, so the overlay never edits the user flake text.
- Overlay modules gate each component on `config.decknix.adoption.org.<id>.enable`. Components that touch Emacs additionally require `config.programs.deckmacs.enable or false`; today the reference overlay's Emacs customisations are unconditional (org overlay inventory section 3), which would break evaluation for a tier 1 to 3 user (unverified, slice 10 tests it).
- Org-specific settings that currently live in the generic framework move to the overlay. Example: the `netrc-file` setting for a private artifact registry in `modules/darwin/default.nix:76-83`. A fresh count on 2026-10-29 (`grep -rniIE` for the org's names, domains, repository owners and tool prefixes over modules, lib, cli, pkgs, templates and bin) finds about 194 non-test lines, about 125 of them in the Emacs tree, plus several hundred in test fixtures. All of them leave decknix in slice 5 (section 15): whole org-only packages move to the org DoS tooling repo or the overlay, org defaults become empty customisation points set by the overlay, and names in comments, fixtures and docs become neutral placeholders. The term list used to check this lives in the overlay, never in a public repository.

### 6.5 deckmacs split

**New repository `ldeck/deckmacs`**, public, MIT like decknix (decision 1). Layout (section 6.0): the distribution at the top level and `packages/{interactive-buffers,agent-workspace,boards}`, each with its own Nix derivation, ERT suite and declared dependencies. A dependency test fails the build when a package requires a feature from a package it does not declare (for example `interactive-buffers` requiring anything from `agent-workspace`). Flake outputs:
- `homeManagerModules.default`: options under `programs.deckmacs.*`, with one toggle per package (`programs.deckmacs.packages.<name>.enable`) so tier 4 installs the distribution alone and tier 5 adds the packages.
- `darwinModules.daemon`: the Emacs server launchd agent, moved from `modules/darwin/emacs.nix:81`.
- `packages.<system>.*`: the carved Elisp packages (today 156 `mkEmacsTestedPackage` derivations, `agent-shell.nix:116-203`), grouped by layer, plus `emacs-deckmacs` for trying it standalone.
- `lib.mkTestedPackage`: the test-running package builder, for downstream private packages (section 15).
- `checks.<system>.*`: the ERT suites and the dependency test, so CI can run them without a full system build.

The carve into `packages/` (slice 8) follows the extraction (slice 7) and precedes the rename (slice 9), so the rename map is generated per package.

**What moves**: everything under `modules/home/options/editors/emacs/` (17 Nix modules, agent-shell packages, tests, specs, `db/`), `modules/darwin/emacs.nix`, `EMACS_SETUP.md`, the Emacs and agent-shell docs pages.

**What stays in decknix**: the CLI, hub daemon (`pkgs/decknix-hub`), session broker (`pkgs/decknix-agent-broker`, its sockets are shared with `cli/src/session.rs`), repo-sync, session-gc, `nix-open`, the shared file formats, and a simple default editor module.

**Simple default in decknix**: `decknix.editors.emacs.flavour = "none" | "basic" | "deckmacs"`. `basic` is a small home-manager `programs.emacs` with a handful of well-known packages and no daemon. `basic` is the default for new installs; tier 4 selects `deckmacs` (decision 2). Existing installs with no adoption file keep `deckmacs` (section 12).

**Interface between them** (the seam):
- decknix publishes a versioned **integration contract** doc and JSON schemas for every file deckmacs reads or writes jointly with the CLI or hub: `~/.config/decknix/agent-sessions.json`, `repo-sync.json`, `hub/*.json`, `hub/worktrees.el`, `boards/`, and `$XDG_STATE_HOME/decknix/agent-sockets/` (emacs inventory section 5), plus the `--json` output of `decknix session list`, `session restore`, `repos list`, `repos sync`, `wt audit` and `wt` refresh.
- Versioning (decision 9): the contract carries a semver `contractVersion`. A breaking change to any schema or constant bumps the major version; deckmacs declares the major range it accepts and its build fails outside it. decknix and deckmacs release independently.
- Two constants must agree across Rust and Elisp today (`cli/src/session.rs:34,36` vs `decknix--agent-conv-key-canonical-length` and `decknix--agent-tags-canonical-key-version`). The contract gives them one source: decknix exports them in a generated `decknix-contract.json`, deckmacs reads it at build time and fails the build on mismatch.
- deckmacs integration features are optional: `programs.deckmacs.integrations.decknix.{sessions,hub,broker,repoSync,worktrees}.enable`, default on when the decknix CLI is present (detected by the decknix home module setting a flag), off otherwise. With them off, deckmacs is a standalone Emacs config.
- The reverse coupling goes away: `decknix switch` currently evaluates `deckmacs--loaded-store-path` and `deckmacs-reload` over emacsclient (`cli/src/main.rs:1015-1016`, `:1045-1116`), as does `modules/darwin/emacs.nix:151`. Replace this with a generic post-switch hook registered through the existing extension mechanism (`/etc/decknix/extensions.json`, `cli/src/main.rs:519-524`): deckmacs registers `deckmacs-post-switch`, and the CLI only knows "run post-switch hooks".

**Naming migration** (`decknix-` to `deckmacs-`):
- Elisp convention is one prefix per package, so every symbol in deckmacs gets the `deckmacs-` prefix. Integration code moves into features named `deckmacs-decknix-*` (for example `deckmacs-decknix-hub`) so the dependency is visible in the name. Estimated split: about 2,700 to 2,800 Emacs-only symbols and about 700 to 850 integration symbols out of 3,542 (unverified category boundaries; emacs inventory section 4).
- Public symbols (no `--`) get `define-obsolete-function-alias` / `define-obsolete-variable-alias` (which also carries `defcustom` customisations) generated mechanically, kept for two tagged releases of deckmacs (decision 8). Faces get `face-alias`. Old feature names get one shim file each that `require`s the new feature and `provide`s the old name. Private `decknix--` symbols are renamed without aliases.
- Nix options `programs.emacs.decknix.*` (about 109) move to `programs.deckmacs.*` with `mkRenamedOptionModule` for each, so existing personal and overlay config keeps evaluating with a warning.
- Hot-reload unloads features by matching `string-prefix-p "decknix-"` (`deckmacs.nix:112,146`). During the transition it must match both prefixes, or reload silently leaves stale code loaded.
- The rename is a generated, reviewable mechanical change (a script in deckmacs produces the rename map and the alias file; the map is committed). Overlay Elisp that calls `decknix-` symbols is updated in the same coupled change.

**State path migration**:
- New customs `deckmacs-config-directory` (default `~/.config/deckmacs`) and `deckmacs-state-directory` (default `$XDG_STATE_HOME/deckmacs`).
- Emacs-only files move (sidebar state, previous sessions and history, live and dismissed sessions, progress, logs, session watches, review drafts and followups, layout, session PRs, layout groups, hub-side caches; full list in emacs inventory section 5).
- Shared files stay where they are and are reached through `deckmacs-decknix-*-file` customs whose defaults come from the contract.
- Migration is a one-time, idempotent move on first start: for each known file, if the new path is absent and the old one exists, move it and leave a marker; reads fall back to the old path for two releases (decision 8). A dry-run command `deckmacs-migrate-state` shows what it will move.

**History**:
- Use `git filter-repo` on a fresh clone of decknix, keeping every historical path of the Emacs tree (found with `git log --name-only --format= -- <paths>` across renames) plus `modules/darwin/emacs.nix` and `EMACS_SETUP.md`, then `--path-rename` into the deckmacs layout. `git subtree split` is rejected because it follows one prefix and loses pre-rename history.
- decknix then removes the tree in one commit whose message names the deckmacs commit it was split at.
- Organisation neutrality (goal 9). Org-specific code leaves decknix before the split (slice 5), so it never enters deckmacs at its new paths. History needs more: decknix's tree and history carry org names in defaults (URLs, repository names, CLI names), examples, comments, test fixtures, docs pages, committed agent transcripts and commit messages. decknix is public, so its own history is scrubbed once before deckmacs is split from it (slice 6): (1) drop org-only paths from all history with `--invert-paths`, including the paths they had before renames, (2) rewrite file contents with `--replace-text` and commit messages with `--replace-message` from a term map kept in the overlay (never in a public repository), mapping each term to the same neutral placeholder slice 5 used, and (3) gate on an acceptance check: `git grep` across every commit and `git log --all --format=%B` match none of the private terms, and the rewritten `main` tree equals the pre-rewrite `main` tree. Author identities are unchanged. The cut-over force-pushes `main` and re-pushes tags, so it needs the owner's explicit confirmation; GitHub can keep orphaned commits reachable by SHA until support purges them, and caches or forks may retain them.
- deckmacs is then split from the scrubbed decknix history, so it inherits a clean history; the same acceptance check runs on deckmacs before its first push.
- The private repositories (the org overlay and the org DoS tooling repo) are not scrubbed.

**Consumers**:
- Transition: decknix takes `deckmacs` as a flake input and its emacs module imports `deckmacs.homeManagerModules.default` with identical defaults, so existing users see no change.
- End state: decknix no longer depends on deckmacs; the generated user flake adds the `deckmacs` input only when tier 4 or 5 is chosen. The org overlay consumes deckmacs only through options, behind its Emacs component toggle; it never pins deckmacs itself (the user flake does, with `follows`). The org DoS tooling repo's Emacs package is consumed by the overlay through that repo's home-manager module.

### 6.6 Homebrew policy

- The reference machine has no Homebrew at all (`command -v brew` empty; all GUI apps are nix-casks copies or vendor/App Store installs). So "no bespoke Homebrew" is already achievable at tier 3.
- Adopters will usually arrive with Homebrew. decknix does not manage or remove it by default. Nix paths already come first on PATH.
- `decknix brew audit` (read-only) lists `brew leaves` and casks and classifies each: duplicated by an enabled decknix package, available in nixpkgs or nix-casks (with the option or package to enable), or no Nix equivalent (keep in Homebrew). It prints the `brew uninstall` commands for duplicates but never runs them.
- Audit only for now (decision 4). nix-darwin's declarative `homebrew` module is not offered; revisit once the audit has run on real adopter machines.

## 7. Documentation

Public decknix site (`docs/src`), reorganised by the ladder:

- **Start here**: what decknix is, the ladder, choose your tier.
- **Quickstarts**: one page per tier (0 to 5), each ending with "how to undo this".
- **Concepts**: layers (framework, org overlay, personal), adoption state, generated user flake, agent-sync, launchd services, the integration contract.
- **Reference (generated)**: options for every home and darwin module, CLI reference from `clap`, launchd label list, file and state path list.
- **Guides**: org overlays (written generically: how to build one and publish a component manifest), secrets, Homebrew migration, troubleshooting, uninstall.
- **deckmacs**: a short page linking to the deckmacs site.

deckmacs site: its own mdBook in the deckmacs repo, carrying the current Emacs and agent-shell pages.

Private overlay doc: lives in the overlay repo, names its components, secrets and login steps, and links to its build-pipeline docs. The public site never names private org projects (it may say "an org config overlay").

**Freshness checks** (CI on every PR, not only on push to `main`):
- Options JSON generated by evaluating the real module tree (the same `find.nixFiles` import the flake uses, `flake.nix:164`) instead of the hand list in `docs/generate-options.nix:18-43`, including darwin modules; fail if any declared `decknix*` option is missing from the reference.
- Generate options for the pinned nixpkgs (25.11 in `flake.nix:5`), not `nixos-24.11` (`.github/workflows/docs.yml`).
- CLI reference generated from `clap`; fail on drift.
- Link check (for example lychee) over the built book, which would have caught the 404 install URL.
- `mdbook build` on PRs.

## 8. Testing

- `install.sh`: whole-script tests with PATH-stubbed `nix`, `curl`, `uname`, `git`, temp `HOME`, `CI=true`, and a call log, as in the sibling installer's test suite. Cover: idempotent second run, marker written once, no `--yes` means no changes, piped run via `bash -s`, refusal on unexpected state.
- `decknix install|adopt|uninstall|doctor`: Rust unit tests on plan generation from fixtures (manifest, backup index, adoption file), plus golden plan-screen output.
- Fresh machine: macOS VMs (for example tart on Apple silicon) running tier 0, tier 1, tier 4 and tier 5 install, re-run, tier down, full uninstall, then `doctor --leftovers` must be empty. A fresh macOS user account is the fallback where a VM is not possible.
- deckmacs: ERT suites and the package dependency test as flake checks in deckmacs CI; a contract test in each repo against the shared schemas.
- Private org packages: ERT suites as flake checks in the overlay and in the org DoS tooling repo, using the same test-running builder.

## 9. Success criteria

- Time to first working shell at tier 0 under 10 minutes on a fresh VM, and tier 1 under 30 minutes with a cold cache (targets, to be measured in slice 12).
- A second run of the installer at the same tier changes nothing and says so.
- Full uninstall on a fresh VM leaves `doctor --leftovers` empty, login shells work, and the reboot note is shown.
- Options reference covers 100 percent of declared `decknix*` and `deckmacs*` options; CI link check green; no stale page from the current audit remains.
- deckmacs history browsable back to the first Emacs commit; existing users upgrade with no config edits beyond rename warnings.
- A tier 1 to 3 user with the org overlay evaluates without deckmacs present; a tier 4 user evaluates without the agent workspace and boards.
- A grep of decknix and deckmacs (every commit and every commit message) for the private term list finds nothing.

## 10. Relationship to the org Nix build pipelines

- The pipelines give adopting repos a build, check and image flake plus reusable CI workflows, and assume only Nix with flakes, a GitHub token for private inputs, `gcloud` credentials for some bootstraps, and a Linux builder for container builds on a Mac. They ship no dev shells today (org overlay inventory section 7). They do not mention decknix.
- So tier 0 is sufficient to work on a pipeline repo; tier 3's Linux builder helps local container builds.
- decknix does not duplicate pipeline templates. The private overlay doc links to them.
- The token question is shared: tier 0 should prefer `NIX_CONFIG="access-tokens = github.com=$(gh auth token)"` (nothing written) and offer the 0600 include file only on opt-in, matching decknix's existing `!include ~/.config/nix/access-tokens.conf` (`modules/darwin/default.nix:70`).
- The tier 0 logic becomes a small shell library kept in decknix (`bin/lib/tier0.sh`, sourced by `bin/install.sh`), with a stable function interface and its own tests, so sibling installers can fetch a pinned revision and source it instead of copying it (decision 6).

## 11. Risks

- **Default flips break existing users.** Mitigation: no adoption file means current behaviour; the installer writes an explicit "full" adoption file on first upgrade run.
- **Rename churn.** 3.5k symbols and 109 options. Mitigation: generated rename map, obsolete aliases, `mkRenamedOptionModule`, one coupled change with the overlay, and the dual-prefix hot-reload fix landing first.
- **Silent state loss** if Emacs-only files move without fallback. Mitigation: move-with-marker plus fallback read for one release, and a dry-run command.
- **Contract drift** between CLI and deckmacs once they are in separate repos. Mitigation: generated contract file, schema tests on both sides, deckmacs build fails on constant mismatch.
- **Uninstall damage**: removing `/nix` before restoring `/etc` shell files breaks login shells; dangling `/etc/ssh` or cert links; a generated `~/.authinfo` vanishing. Mitigation: ordered plan from the manifest, backups, VM tests, never touching secrets by default.
- **Nix installer flavour**: decided as upstream Nix via the Determinate installer (decision 3), which keeps nix-darwin managing Nix (`nix.enable` stays true). Correction (2026-10-29): the reference machine's receipt (3.11.3, `nix --version` 2.31.2+1, an `add_channel` planner setting) indicates the nix-community fork of that installer (bootstrap option 1), not the Determinate Systems build, so the reference machine does not yet prove the chosen flavour. Unverified: which installer flags select upstream Nix in current releases, and for how long the Determinate installer keeps offering upstream Nix. Slice 3 checks both and pins the installer version; if upstream support is gone, the fallback is the nix-community fork of the same installer, recorded as an amendment. The stale `bootstrap.sh` warning that Determinate "may be incompatible" with nix-darwin is corrected in slice 1 (docs) and slice 3 (installer).
- **Private overlay auth** before SSH keys exist. Mitigation: `gh auth login` step in the overlay's thin installer, documented.
- **Build time** of the pre-commit full system build slows every docs and installer commit. Out of scope, noted.

## 12. Back-compatibility and migration of existing installs

- Existing `~/.config/decknix` keeps working untouched. The first `decknix install` run on such a machine detects it, writes `adoption.toml` reflecting what is enabled today, shows the plan (expected: no changes) and exits.
- `bin/bootstrap.sh` remains as a shim for one release.
- Old `decknix-` Emacs aliases and old state paths stay for two releases (decision 8).
- `decknix.role` is kept as an obsolete option that maps onto tiers with a warning.


## 13. Decisions

Approved by the owner on 2026-10-29. They replace the open questions in the draft.

1. **deckmacs visibility and licence**: public on `ldeck/deckmacs`, MIT like decknix, one repository with a `packages/` directory (section 6.0). It has no association with any organisation: no org names, repositories, chat channels, issue trackers or org overlays in code, docs, tests or history (goal 9, section 6.5, section 15). decknix meets the same bar, including a one-time scrub of its public history (layering approval, 2026-10-30).
2. **Default Emacs in decknix**: `basic`. Tier 4 adds the deckmacs editor; tier 5 adds its agent workspace and boards (layering approved 2026-10-30, section 6.0).
3. **Nix flavour**: upstream Nix via the Determinate installer. nix-darwin keeps managing Nix. The stale `bootstrap.sh` warning is corrected in the docs and installer slices.
4. **Homebrew**: audit only for now.
5. **Linux scope**: tier 0 only for now.
6. **Shared installer library**: the tier 0 shell logic becomes a library kept in decknix and reusable by sibling installers.
7. **Tier boundaries**: repo-sync and session-gc in tier 3; Gortex in tier 2.
8. **Alias lifetime**: old `decknix-` Emacs aliases and old state paths are kept for two releases.
9. **Contract versioning**: semver on the contract, plus a checked decknix to deckmacs contract (build fails on mismatch).
10. **Tier 0 GitHub token**: env var only. Tier 0 never writes a token file.

## 14. Workspace relocation

The owner's working checkouts move to a layout where each checkout's path says whose it is and matches its repository name:

- The decknix checkout moves from `~/tools/decknix` to the personal workspace, `~/Code/ldeck/decknix`.
- The new deckmacs checkout lives beside it at `~/Code/ldeck/deckmacs`.
- The org overlay checkout moves within the org workspace to a directory named exactly like its repository (today the directory and the repository name differ).

This is the owner's machine layout, not something decknix imposes. Public docs keep paths generic ("your decknix checkout", "your org overlay checkout") and never name the private overlay. The detailed move plan is prepared separately; this section fixes only the outcome.

Git identity follows the path, through the global `includeIf` rules in the Nix-managed git config: personal repositories under `~/Code/ldeck/` must resolve the personal address, and org repositories under the org workspace must resolve the work address. Moving decknix out of `~/tools/` changes which rule matches it, so the rules must cover `~/Code/ldeck/` before the move, and no repository may carry a repo-local `user.email`.

Acceptance criteria (slice 0):

- `git -C <path> config user.email` resolves the personal address for both personal checkouts and the work address for the overlay checkout, with no repo-local `user.email` in any of them.
- Every hard-coded reference to the old paths is updated or made generic: decknix `AGENTS.md` and docs, the overlay's build guard and git hooks (which name both framework repositories), `decknix switch --override` examples, agent-sync source paths, `decknix pull-local-changes` targets, repo-sync and worktree registries, Gortex rosters, and launchd agents whose arguments embed a path.
- The pre-commit full-build guard still runs and passes for both framework repositories at their new paths.
- `decknix switch` from the user flake builds with local overrides pointing at the new paths.
- Existing worktrees of the moved repositories are either moved with `git worktree move` or pruned, and `git worktree list` shows no stale entries.
- Agent session state that records working directories (session store, previous sessions, sockets) is either rewritten or left to age out, and the plan says which.
- Nothing is left at the old paths except, optionally, a symlink kept for one release and recorded for removal.

Ordering: slice 0 lands before the deckmacs extraction (slice 7), so deckmacs is created at its final path and its history never records the old one.

## 15. Org code once decknix and deckmacs are public

Some code in decknix is specific to the reference org. Part of it already lives in the org overlay (a pilot board, an agent inbox, snippets, agent-shell purpose settings, an alert-feed command for a support dashboard). Part of it still lives in decknix: whole org-only packages (a support dashboard, an on-support board and worksheet, and a support workflow, which drive the org's support-rotation CLI and its tracker board, about 2k lines with their tests), org defaults in otherwise generic code (CI check names keyed by org repositories, an org helper-script path, a workspace path, org wiring in the agent-shell module), and org names in comments, tests, docs pages, example board definitions and committed agent transcripts. All of it leaves decknix in slice 5, before the history scrub (slice 6) and the deckmacs split (slice 7).

Options considered on 2026-10-29: (a) the org overlay, (b) a separate private org package repository, (c) a hybrid: tested packages in the overlay, liftable later. The layering approved on 2026-10-30 (section 6.0) settles it:

- **Support-rotation views go to the org DoS tooling repo**, next to the CLI they drive. They change with that CLI (its JSON output is their input), so co-versioning them removes a cross-repo pin bump from every CLI change. That repo's flake exports the Emacs package with its ERT suite as a flake check, and its home-manager module adds the package and its key bindings when the overlay enables it.
- **Everything else org-specific goes to the overlay** as tested packages behind its `emacs` component (option (c)), with their ERT suites as overlay flake checks.
- Both use a test-running builder: today a copy of the builder decknix uses, later `deckmacs.lib.mkTestedPackage`.
- Generic seams the moved code needs (a dashboard command variable, board scopes, CI check names, a workspace root, a helper-script directory) stay in decknix, and then deckmacs, as empty, documented customisation points with neutral examples; the overlay sets them.
- A further private package repository is still deferred until there is a second consumer or a cadence that differs from the overlay's.

Live-setup continuity: the overlay consumes the org DoS tooling repo as a pinned remote flake input, so a local commit there is not visible to a switch until it is pushed and the pin bumped. Slice 5 therefore keeps a temporary copy of the views wired in the overlay until that push, then switches the overlay to the DoS tooling repo's module and drops the copy.

The org-named inventory behind this section, and the private term list, are kept in the overlay, outside this public repository.
