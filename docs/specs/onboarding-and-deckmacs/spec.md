# Onboarding, adoption tiers, uninstall and the deckmacs split

Status: draft for approval. No implementation has started.

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
5. decknix ships a simple default Emacs (or none, see open decisions) and offers deckmacs as an opt-in tier.
6. Org overlays declare their optional components so the installer can offer them; the overlay never has to edit the user's flake text.
7. Docs that are current, organised by tier, and kept current by CI (generated options and CLI reference, link check).
8. People who adopt the higher tiers need no bespoke Homebrew installs; people who keep Homebrew are not fought.

## 3. Non-goals

- Changing how the org's Nix build pipelines work. Those projects are owned elsewhere; decknix only needs to provide a machine they work on (section 10).
- NixOS system configuration. Linux scope is an open decision (section 13).
- Rewriting the agent-shell feature set. The deckmacs work is a move, a rename and a seam, not a redesign.
- Managing Mac App Store apps, vendor installers or company endpoint agents.
- A GUI installer.

## 4. Personas

- **Curious developer.** Wants Nix and flake dev shells for one or two repos. Will not hand their shell or `/etc` to a framework on day one. Needs: tier 0 only, fully reversible with one command.
- **AI-agent user.** Wants Claude Code, Pi, Gemini and friends installed and configured, plus the org's shared skills and commands. Happy with nix-darwin and home-manager, not interested in Emacs. Needs: tiers 1 and 2, plus the org AI component.
- **Workstation adopter.** Wants decknix to replace Homebrew: GUI apps, fonts, window manager, Linux builder for container builds. Needs: tier 3 and a Homebrew migration report.
- **Full decknix user.** Emacs as the cockpit: deckmacs, agent-shell, hub, broker, boards, launchd services. Needs: tier 4 and every org component.
- **Org config adopter (orthogonal).** Any of the above who also layers an org overlay: identity, git hooks, org services, org AI artifacts. Needs: per-component choice, secrets prompts that never go near the Nix store.

## 5. Adoption ladder

Tiers are cumulative. Each tier lists what it installs, where it comes from, and how to reverse it.

**Tier 0: Nix**
- Installs: Nix via the Determinate installer (flavour is an open decision), flakes enabled in `~/.config/nix/nix.conf` only, optional direnv and nix-direnv via `nix profile`, optional GitHub access-token include for private flakes (written only on explicit opt-in, mode 0600, or left to the `NIX_CONFIG` env var).
- Repos/flakes: none beyond nixpkgs. No decknix checkout, no nix-darwin, no home-manager.
- Reversible: `/nix/nix-installer uninstall` plus removal of the marker-guarded nix.conf and rc lines. The installer prints both.
- Enough for: any flake project, including the org's Nix build pipelines (they need Nix with flakes and a GitHub token for private inputs, and ship no dev shells; org overlay inventory section 7).

**Tier 1: Base**
- Installs: nix-darwin and home-manager through `decknix.lib.mkSystem`, a generated user flake in `~/.config/decknix`, the `decknix` CLI (switch, update, install, adopt, uninstall, doctor), zsh, starship, git, core CLI tools, Vim standard profile. Emacs: the simple default or none. No launchd services.
- Repos/flakes: `github:ldeck/decknix`.
- Reversible: `decknix uninstall --tier 1` runs the nix-darwin uninstaller (which restores `*.before-nix-darwin` files), restores installer backups, removes home-manager links. Leaves tier 0.

**Tier 2: AI agents**
- Installs: the `decknix.ai.*` modules the person ticks (Claude, Pi, Gemini, Codex, OpenCode, Goose, Qwen), agent-sync for any artifact files, Gortex if a roster is configured.
- Reversible: untick and switch. Agent-sync copies are removed only when unchanged since deploy; edited copies are moved to the uninstall backup.

**Tier 3: Workstation**
- Installs: GUI apps from nix-casks, fonts, window manager (AeroSpace, Hammerspoon or OmniWM), Linux builder (on demand), repo-sync and session-gc agents.
- Reversible: untick and switch, plus leftovers the switch cannot remove declaratively (rsync'ed app copies in `~/Applications/Nix Apps`, the Linux builder disk image under `/var/lib/linux-builder`, about 29.5 GB on the reference machine).

**Tier 4: deckmacs**
- Installs: `github:ldeck/deckmacs` home-manager module, the Emacs daemon agent, and the decknix integrations deckmacs can use (hub agent, session broker, boards).
- Reversible: untick and switch; deckmacs state is kept unless `--purge-state` is given.

**Org overlay (orthogonal, any tier from 1)**
- The overlay publishes a component manifest (section 6.4). Typical components: identity and git hooks, org AI artifacts, org background services (for example IAP proxies, an MCP server agent), org Emacs customisations (requires tier 4), heavy language tooling.
- Reversible per component, same mechanism as tiers.

Existing installs: a machine with a pre-existing `~/.config/decknix` and no adoption file is treated as "everything currently enabled" so nothing changes on upgrade (section 12).

## 6. Design

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
- **Secrets**: the installer prompts only for secrets the overlay manifest declares, writes each as a raw file `~/.config/decknix/<org>/secrets/<name>` with mode 0600 in a 0700 directory, and never passes a secret through Nix evaluation. `--yes` without the matching env var skips the secret and lists it in the summary.

### 6.3 Uninstall UX

`decknix uninstall` and `install.sh --uninstall` (the latter works even when the CLI is broken, by reading the manifest with `jq` from nixpkgs).

- Scope: `--tier N` removes tiers above N-1; `--component X` removes one component; `--all` removes everything decknix installed including nix-darwin; `--all --nix` also runs `/nix/nix-installer uninstall`.
- **Plan screen** first, built from `/etc/decknix/manifest.json`, the backup index and the agent-sync manifest. `--dry-run` stops there.
- Order for `--all` (from the artifact inventory; order is unverified until slice 3 exercises it on a VM):
  1. Copy out generated files people rely on as real files (for example a generated `~/.authinfo`) when the plan flags them.
  2. Boot out decknix launchd agents and daemons listed in the manifest.
  3. Remove agent-sync copies whose hash matches the deployed hash; move edited ones to the backup.
  4. Remove non-declarative leftovers (app copies, Linux builder disk, sockets).
  5. Run the nix-darwin uninstaller, which restores `*.before-nix-darwin`; then restore the installer's own backups (including the legacy `*.before-decknix.<ts>` files from `bootstrap.sh`).
  6. Remove home-manager generations and GC roots, including `~/.config/decknix/result`.
  7. Optionally the Determinate uninstaller. A reboot is required to clear `/etc/synthetic.conf` entries; the summary says so.
- **Never touches**: secrets under `~/.config/decknix/<org>/secrets/` (unless `--purge-secrets` with typed confirmation), `~/.config/decknix/local/`, the user flake itself (kept for reinstall), agent data in `~/.claude`, `~/.pi` and similar beyond files in the agent-sync manifest, source repositories, Emacs state (unless `--purge-state`), Homebrew, App Store and vendor apps.
- **Verify**: `decknix doctor --leftovers` scans every path class in the inventory and reports anything remaining. Slice 9 runs it on a fresh VM after install then uninstall.

### 6.4 Org overlay contract

- An overlay flake exports, alongside `darwinModules.default` and `homeModules.default`, a `decknixOrg` attribute: name, description, components (id, title, description, minimum tier, default on or off, depends on), declared secrets (name, prompt, help URL, required by component), identity fields, and login hints.
- The installer reads it with `nix eval --json <ref>#decknixOrg`, so the overlay never edits the user flake text.
- Overlay modules gate each component on `config.decknix.adoption.org.<id>.enable`. Components that touch Emacs additionally require `config.programs.deckmacs.enable or false`; today the reference overlay's Emacs customisations are unconditional (org overlay inventory section 3), which would break evaluation for a tier 1 to 3 user (unverified, slice 7 tests it).
- Org-specific settings that currently live in the generic framework move to the overlay. Example: the `netrc-file` setting for a private artifact registry in `modules/darwin/default.nix:76-83`. There are about 105 lines naming the reference org in framework code (`grep -rn` over modules, lib, cli, pkgs); most are in the Emacs tree and move with deckmacs.

### 6.5 deckmacs split

**New repository `ldeck/deckmacs`** (visibility and licence are open decisions). Flake outputs:
- `homeManagerModules.default`: options under `programs.deckmacs.*`.
- `darwinModules.daemon`: the Emacs server launchd agent, moved from `modules/darwin/emacs.nix:81`.
- `packages.<system>.*`: the carved Elisp packages (today 156 `mkEmacsTestedPackage` derivations, `agent-shell.nix:116-203`), plus `emacs-deckmacs` for trying it standalone.
- `checks.<system>.*`: the ERT suites, so CI can run them without a full system build.

**What moves**: everything under `modules/home/options/editors/emacs/` (17 Nix modules, agent-shell packages, tests, specs, `db/`), `modules/darwin/emacs.nix`, `EMACS_SETUP.md`, the Emacs and agent-shell docs pages.

**What stays in decknix**: the CLI, hub daemon (`pkgs/decknix-hub`), session broker (`pkgs/decknix-agent-broker`, its sockets are shared with `cli/src/session.rs`), repo-sync, session-gc, `nix-open`, the shared file formats, and a simple default editor module.

**Simple default in decknix**: `decknix.editors.emacs.flavour = "none" | "basic" | "deckmacs"`. `basic` is a small home-manager `programs.emacs` with a handful of well-known packages and no daemon. Which one is the default is an open decision.

**Interface between them** (the seam):
- decknix publishes a versioned **integration contract** doc and JSON schemas for every file deckmacs reads or writes jointly with the CLI or hub: `~/.config/decknix/agent-sessions.json`, `repo-sync.json`, `hub/*.json`, `hub/worktrees.el`, `boards/`, and `$XDG_STATE_HOME/decknix/agent-sockets/` (emacs inventory section 5), plus the `--json` output of `decknix session list`, `session restore`, `repos list`, `repos sync`, `wt audit` and `wt` refresh.
- Two constants must agree across Rust and Elisp today (`cli/src/session.rs:34,36` vs `decknix--agent-conv-key-canonical-length` and `decknix--agent-tags-canonical-key-version`). The contract gives them one source: decknix exports them in a generated `decknix-contract.json`, deckmacs reads it at build time and fails the build on mismatch.
- deckmacs integration features are optional: `programs.deckmacs.integrations.decknix.{sessions,hub,broker,repoSync,worktrees}.enable`, default on when the decknix CLI is present (detected by the decknix home module setting a flag), off otherwise. With them off, deckmacs is a standalone Emacs config.
- The reverse coupling goes away: `decknix switch` currently evaluates `deckmacs--loaded-store-path` and `deckmacs-reload` over emacsclient (`cli/src/main.rs:1015-1016`, `:1045-1116`), as does `modules/darwin/emacs.nix:151`. Replace this with a generic post-switch hook registered through the existing extension mechanism (`/etc/decknix/extensions.json`, `cli/src/main.rs:519-524`): deckmacs registers `deckmacs-post-switch`, and the CLI only knows "run post-switch hooks".

**Naming migration** (`decknix-` to `deckmacs-`):
- Elisp convention is one prefix per package, so every symbol in deckmacs gets the `deckmacs-` prefix. Integration code moves into features named `deckmacs-decknix-*` (for example `deckmacs-decknix-hub`) so the dependency is visible in the name. Estimated split: about 2,700 to 2,800 Emacs-only symbols and about 700 to 850 integration symbols out of 3,542 (unverified category boundaries; emacs inventory section 4).
- Public symbols (no `--`) get `define-obsolete-function-alias` / `define-obsolete-variable-alias` (which also carries `defcustom` customisations) generated mechanically, kept for at least two tagged releases. Faces get `face-alias`. Old feature names get one shim file each that `require`s the new feature and `provide`s the old name. Private `decknix--` symbols are renamed without aliases.
- Nix options `programs.emacs.decknix.*` (about 109) move to `programs.deckmacs.*` with `mkRenamedOptionModule` for each, so existing personal and overlay config keeps evaluating with a warning.
- Hot-reload unloads features by matching `string-prefix-p "decknix-"` (`deckmacs.nix:112,146`). During the transition it must match both prefixes, or reload silently leaves stale code loaded.
- The rename is a generated, reviewable mechanical change (a script in deckmacs produces the rename map and the alias file; the map is committed). Overlay Elisp that calls `decknix-` symbols is updated in the same coupled change.

**State path migration**:
- New customs `deckmacs-config-directory` (default `~/.config/deckmacs`) and `deckmacs-state-directory` (default `$XDG_STATE_HOME/deckmacs`).
- Emacs-only files move (sidebar state, previous sessions and history, live and dismissed sessions, progress, logs, session watches, review drafts and followups, layout, session PRs, layout groups, hub-side caches; full list in emacs inventory section 5).
- Shared files stay where they are and are reached through `deckmacs-decknix-*-file` customs whose defaults come from the contract.
- Migration is a one-time, idempotent move on first start: for each known file, if the new path is absent and the old one exists, move it and leave a marker; reads fall back to the old path for one release. A dry-run command `deckmacs-migrate-state` shows what it will move.

**History**:
- Use `git filter-repo` on a fresh clone of decknix, keeping every historical path of the Emacs tree (found with `git log --name-only --format= -- <paths>` across renames) plus `modules/darwin/emacs.nix` and `EMACS_SETUP.md`, then `--path-rename` into the deckmacs layout. `git subtree split` is rejected because it follows one prefix and loses pre-rename history.
- decknix then removes the tree in one commit whose message names the deckmacs commit it was split at.

**Consumers**:
- Transition: decknix takes `deckmacs` as a flake input and its emacs module imports `deckmacs.homeManagerModules.default` with identical defaults, so existing users see no change.
- End state: decknix no longer depends on deckmacs; the generated user flake adds the `deckmacs` input only when tier 4 is chosen. The org overlay consumes deckmacs only through options, behind its Emacs component toggle; it never pins deckmacs itself (the user flake does, with `follows`).

### 6.6 Homebrew policy

- The reference machine has no Homebrew at all (`command -v brew` empty; all GUI apps are nix-casks copies or vendor/App Store installs). So "no bespoke Homebrew" is already achievable at tier 3.
- Adopters will usually arrive with Homebrew. decknix does not manage or remove it by default. Nix paths already come first on PATH.
- `decknix brew audit` (read-only) lists `brew leaves` and casks and classifies each: duplicated by an enabled decknix package, available in nixpkgs or nix-casks (with the option or package to enable), or no Nix equivalent (keep in Homebrew). It prints the `brew uninstall` commands for duplicates but never runs them.
- Whether to also offer nix-darwin's declarative `homebrew` module for the "keep in Homebrew" list is an open decision.

## 7. Documentation

Public decknix site (`docs/src`), reorganised by the ladder:

- **Start here**: what decknix is, the ladder, choose your tier.
- **Quickstarts**: one page per tier (0 to 4), each ending with "how to undo this".
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
- Fresh machine: macOS VMs (for example tart on Apple silicon) running tier 0, tier 1, tier 4 install, re-run, tier down, full uninstall, then `doctor --leftovers` must be empty. A fresh macOS user account is the fallback where a VM is not possible.
- deckmacs: ERT suites as flake checks in deckmacs CI; a contract test in each repo against the shared schemas.

## 9. Success criteria

- Time to first working shell at tier 0 under 10 minutes on a fresh VM, and tier 1 under 30 minutes with a cold cache (targets, to be measured in slice 9).
- A second run of the installer at the same tier changes nothing and says so.
- Full uninstall on a fresh VM leaves `doctor --leftovers` empty, login shells work, and the reboot note is shown.
- Options reference covers 100 percent of declared `decknix*` and `deckmacs*` options; CI link check green; no stale page from the current audit remains.
- deckmacs history browsable back to the first Emacs commit; existing users upgrade with no config edits beyond rename warnings.
- A tier 1 to 3 user with the org overlay evaluates without deckmacs present.

## 10. Relationship to the org Nix build pipelines

- The pipelines give adopting repos a build, check and image flake plus reusable CI workflows, and assume only Nix with flakes, a GitHub token for private inputs, `gcloud` credentials for some bootstraps, and a Linux builder for container builds on a Mac. They ship no dev shells today (org overlay inventory section 7). They do not mention decknix.
- So tier 0 is sufficient to work on a pipeline repo; tier 3's Linux builder helps local container builds.
- decknix does not duplicate pipeline templates. The private overlay doc links to them.
- The token question is shared: tier 0 should prefer `NIX_CONFIG="access-tokens = github.com=$(gh auth token)"` (nothing written) and offer the 0600 include file only on opt-in, matching decknix's existing `!include ~/.config/nix/access-tokens.conf` (`modules/darwin/default.nix:70`).
- Whether the tier 0 logic becomes a small shared library used by decknix and the sibling installers is an open decision.

## 11. Risks

- **Default flips break existing users.** Mitigation: no adoption file means current behaviour; the installer writes an explicit "full" adoption file on first upgrade run.
- **Rename churn.** 3.5k symbols and 109 options. Mitigation: generated rename map, obsolete aliases, `mkRenamedOptionModule`, one coupled change with the overlay, and the dual-prefix hot-reload fix landing first.
- **Silent state loss** if Emacs-only files move without fallback. Mitigation: move-with-marker plus fallback read for one release, and a dry-run command.
- **Contract drift** between CLI and deckmacs once they are in separate repos. Mitigation: generated contract file, schema tests on both sides, deckmacs build fails on constant mismatch.
- **Uninstall damage**: removing `/nix` before restoring `/etc` shell files breaks login shells; dangling `/etc/ssh` or cert links; a generated `~/.authinfo` vanishing. Mitigation: ordered plan from the manifest, backups, VM tests, never touching secrets by default.
- **Nix installer flavour**: `bootstrap.sh:85` warns Determinate "may be incompatible" with nix-darwin, yet the reference machine runs the Determinate installer (receipt 3.11.3, Nix 2.31.2) with nix-darwin managing Nix. Which Nix that installer installs by default, and whether nix-darwin must then set `nix.enable = false`, is unverified.
- **Private overlay auth** before SSH keys exist. Mitigation: `gh auth login` step in the overlay's thin installer, documented.
- **Build time** of the pre-commit full system build slows every docs and installer commit. Out of scope, noted.

## 12. Back-compatibility and migration of existing installs

- Existing `~/.config/decknix` keeps working untouched. The first `decknix install` run on such a machine detects it, writes `adoption.toml` reflecting what is enabled today, shows the plan (expected: no changes) and exits.
- `bin/bootstrap.sh` remains as a shim for one release.
- `decknix.role` is kept as an obsolete option that maps onto tiers with a warning.

## 13. Open decisions (need the user)

1. **deckmacs visibility and licence**: public on `ldeck/deckmacs` under the same licence as decknix, or private first.
2. **Default Emacs in decknix**: `none`, `basic`, or `deckmacs` (keep today's experience as the default).
3. **Nix flavour**: Determinate Nix (with nix-darwin `nix.enable = false`) or upstream Nix via the Determinate installer, or the nix-community installer the current bootstrap prefers.
4. **Homebrew coexistence**: audit-only, or also offer nix-darwin's declarative `homebrew` module for apps with no Nix equivalent.
5. **Linux scope**: tier 0 only, or also tiers 1 and 2 via standalone home-manager.
6. **Shared installer library**: whether the tier 0 shell logic becomes a library shared with the sibling org installers, and where it lives.
7. **Tier boundaries**: whether repo-sync and session-gc belong to tier 3 or tier 4, and whether Gortex belongs to tier 2.
8. **Alias lifetime**: how many releases the `decknix-` obsolete aliases and old state-path fallbacks live.
9. **Contract versioning**: semver on the contract file, or lockstep releases of decknix and deckmacs.
10. **Tier 0 GitHub token**: env var only, or also offer writing the 0600 include file.
