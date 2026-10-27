# Inventory: current decknix architecture and onboarding

Snapshot of `main` at `2d9316d7` (2026-10-27). "Unverified" marks inferences.

## 1. Install and bootstrap

`bin/bootstrap.sh` is the only installer. Four phases, each skippable with `SKIP_NIX`, `SKIP_PREFLIGHT`, `SKIP_INIT`, `SKIP_ACTIVATE`. `--non-interactive` or `CI=true` disables prompts and reads `DECKNIX_REF`, `DECKNIX_INSTALLER`, `DECKNIX_USER`, `DECKNIX_HOST`, `DECKNIX_ROLE`.

1. Install Nix. Choice 1 is the nix-community installer (a fork of the Determinate installer) with `trusted-users`; 2 is the official installer; 3 is Determinate, labelled "May be incompatible with nix-darwin configuration of decknix" (`bin/bootstrap.sh:83-100`).
2. Preflight. Moves `/etc/nix/nix.conf`, `/etc/zshenv`, `/etc/zshrc`, `/etc/bashrc` to `*.before-decknix.<ts>` with sudo.
3. Init. `nix flake init -t github:ldeck/decknix/tree/<ref>` into `~/.config/decknix`, then writes `settings.nix` from a heredoc.
4. Activate. `sudo darwin-rebuild switch --flake .#default --impure`, or `sudo nix run nix-darwin -- switch ...` when darwin-rebuild is not installed yet.

Gaps: no plan screen, no tier choice, no verify, no uninstall, no idempotent re-run semantics beyond phase skips.

Documented one-liner is broken: `docs/src/getting-started/installation.md:16` and `README.md:12` fetch `.../main/bin/bootstrap`, which returns HTTP 404; `bin/bootstrap.sh` returns 200 (checked with curl, 2026-10-27).

## 2. Template and user flake

Only `templates/default/` (registered at `flake.nix:200-214`): `flake.nix`, `settings.nix`, `.gitignore`.

- Inputs: `decknix = github:ldeck/decknix`; nixpkgs, nix-darwin, nix-casks follow it. The org overlay is a commented-out input.
- Outputs: `decknix.lib.mkSystem { inherit inputs; settings = import ./settings.nix; }`. Org modules are wired by uncommenting `darwinModules` and `homeModules`.
- `settings.nix` ships `username = "REPLACE_ME"` and a role comment suggesting `'tester'`, but the option is `enum [developer designer minimal]` (`modules/home/options.nix:46`), so `tester` fails evaluation.
- `.gitignore` ignores `settings.nix` and `local/`; if the user `git init`s the directory, git flakes drop ignored files and `import ./settings.nix` breaks (unverified).
- `welcomeText` (`flake.nix:206-211`) says to edit `flake.nix` for `username`; it lives in `settings.nix`.

On the reference machine, `~/.config/decknix` is not a git checkout; it also holds `settings.toml` (CLI switch overrides) and a large amount of agent-shell runtime state.

## 3. Loader (`lib/default.nix`)

- `mkSystem` (`:12-91`) merges defaults (`setup-required`, `aarch64-darwin`, `developer`) with settings and builds `darwinConfigurations.default`: decknix darwin modules, org darwin modules, generated identity module, `loader.modules.system`; home-manager imports in the order decknix, org, identity, `loader.modules.home` (`:73-87`).
- `configLoader` (`:137-261`) scans `~/.config/decknix`. Each non-`local` subdirectory with `identity.nix` generates `options.<org>.user.{email,name,githubUser,gpgKey}` (`:177-215`). For each of home, system, secrets it loads `<dir>/<type>.nix`, `<dir>/<type>/**/*.nix` and a root `<type>.nix` (`:223-250`). Secrets are loaded into both home and system (`:254-255`). Needs `--impure`.
- `decknix.role` has no effect: `_internal.templates` (`modules/home/options.nix:79`) is never read, and nothing implements the `decknix init` that `options.nix:8` mentions.

## 4. CLI (`cli/src`, about 6.3k lines)

- `update [INPUT]`: `nix flake update` (`main.rs:29`).
- `switch`: preflight eval then darwin-rebuild; `--dry-run`, `--force`, `--override`, `--no-overrides`; kickstarts stopped agents on a no-op switch; queries the running Emacs for deckmacs reload state (`main.rs:34`, `:919`, `:1015-1116`).
- `wt`: worktree registry: list, refresh, prune-metadata, prune, clean-fork-remotes, registry, audit, orphans, finished, clean (`main.rs:99-200`, `wt_finished.rs`).
- `session` (`s`): list, archive, restore, gc, resume, new, tag, tags (`session.rs:49-191`, `session_archive.rs`).
- `repos` (`repo`): sync, fix-lock, list (`repo_sync.rs:42-99`).
- `pull-local-changes`: copy edited agent artifacts back to source repos (`main.rs:74`).
- `help`, plus external extensions from `/etc/decknix/extensions.json` and `~/.config/decknix/extensions.json` (`main.rs:94`, `:519-524`). Nix-registered extensions: `board`, `repo-jdk`, `space`, `cheatsheet`.
- Missing: `install`, `uninstall`, `init`, `doctor`, `adopt`.
- `decknix-hub` is a separate daemon binary (`pkgs/decknix-hub`), not a subcommand.

## 5. Darwin modules and launchd

All auto-imported via `find.nixFiles ./modules/darwin` (`flake.nix:164`).

- `emacs-server` user agent, KeepAlive (`modules/darwin/emacs.nix:81`), default **on** (`:48`).
- `decknix-hub` user agent, logs to `/tmp/decknix-hub.log` (`hub.nix:199`), default off (`:44`); the reference overlay turns parts of it on.
- `iap-proxy-<name>` user agents (`iap-proxy.nix:155-177`), default off (`:102`); enabled by the reference overlay.
- `decknix-repo-sync` user agent every 3h (`repo-sync.nix:52`), default **on** (`:28`).
- `decknix-session-gc` user agent weekly (`session-gc.nix:48`), default **on** (`:24`).
- `linux-builder`, `linux-builder-activator`, `linux-builder-idle-stop` system daemons (`linux-builder/default.nix:133,140,150`), default **on**, on demand (`:59,69`).
- Home-manager agents: `gortex` (`ai/gortex.nix:503`, on when a roster is configured), OmniWM (`wm/omniwm/default.nix:126`, module off by default).

Option namespaces are inconsistent: `decknix.services.{hub,iap-proxy,aerospace}`, `services.decknix.{repoSync,sessionGc}`, `services.emacs.decknix`, `decknix.linuxBuilder`.

`/etc` files written by decknix itself: only `decknix/extensions.json` (`modules/cli/default.nix:52`), plus what nix-darwin manages.

Homebrew: not used anywhere; casks come from the `nix-casks` input.

Nix settings: nix-darwin manages Nix (no `nix.enable = false`); `modules/darwin/default.nix:57-83` sets experimental features, trusted users, `!include ~/.config/nix/access-tokens.conf` and an org-specific `netrc-file` for a private artifact registry.

## 6. Home modules (`modules/home/options/`)

Auto-loaded by `modules/home/default.nix:21`.

- `ai/`: 8 files, about 1.3k lines. `gortex` on by default (`gortex.nix:236`); claude, codex, gemini, goose, opencode, pi, qwen are opt-in.
- `apps/`: Ungoogled Chromium, on by default on macOS.
- `cli/`: 6 files, about 700 lines. `repo-jdk` and `nix-github-auth` on; auggie and board off; agent-sync on when it has files.
- `editors/`: 20 Nix files, about 14k lines, plus 353 Elisp files. Emacs on with the full profile; Vim standard profile (`profiles.nix:43,55`).
- `shell/`: starship and zsh bits, about 130 lines.
- `wm/`: aerospace, hammerspoon, omniwm all off by default; spaces helpers.

## 7. Docs site

mdBook at `docs/src` (`docs/book.toml`). `SUMMARY.md` sections: Introduction; Getting Started (Installation, First Config, Applying Changes); Architecture; Configuration; Modules (Emacs, Vim, Shell, Git, Window Management, Linux Builder, AI with 15 agent-shell subpages); CLI; Guides (Hub, Org Configs, Development, Troubleshooting); Reference (Configuration Hub, Pair Protocol); Resources. Orphans outside SUMMARY: `docs/getting-started.md`, `docs/configuration.md`, `docs/secrets.md`, `docs/src/modules/ai-tooling.md`.

Options reference: `docs/generate-options.nix:18-43` evaluates a hand-maintained list of 27 home modules. 14 option-declaring home modules are missing (`ai/claude.nix`, `codex`, `gemini`, `goose`, `gortex`, `opencode`, `pi`, `qwen`, `apps/ungoogled-chromium.nix`, `cli/repo-jdk.nix`, `editors/emacs/deckmacs.nix`, `editors/emacs/recording.nix`, `shell/starship.nix`, `wm/omniwm/default.nix`), and no darwin module is evaluated (7 declare options: aerospace, emacs, hub, iap-proxy, linux-builder, repo-sync, session-gc).

CI (`.github/workflows/docs.yml`): builds and deploys on push to `main` only; generates options for `nixos-24.11` and `nixos-unstable` while the flake pins 25.11 (`flake.nix:5`). No PR build, no link check, no CLI or option drift check, no installer test.

### Stale pages

1. `getting-started/installation.md:16` (and `README.md:12`, `docs/getting-started.md:18`): 404 install URL; "Option 2" runs `decknix switch` or `darwin-rebuild` before either exists; no mention of the installer choice, `/etc` backups or role prompt.
2. `cli/overview.md:9-14` lists only switch, update, help; `cli/core-commands.md` lacks `repos`, `pull-local-changes`, `session archive|restore|gc`, `wt finished`. `README.md:68` documents `decknix switch --dev`, which does not exist (the flag is `--override`).
3. `cli/extensions.md:60` lists a `decknix verify` extension defined nowhere.
4. `architecture/directory-layout.md`: darwin list misses hub, iap-proxy, repo-sync, session-gc, linux-builder; home list misses ai, shell, apps, omniwm; CLI described as one file; omits `identity.nix`, `secrets/`, `settings.toml`, `extensions.json`.
5. `architecture/config-loader.md:12`: says secrets merge into home-manager only; they load into both (`lib/default.nix:254-255`).
6. `modules/overview.md`: `decknix.role` default shown as `developer` (option default is `minimal`, `options.nix:47`); AI described as Augment only; darwin table incomplete; package lists miss `yq-go` and `nix-open`.
7. `configuration/settings.md:24-31`: role "determines which bootstrap template is applied"; nothing applies templates.
8. `guides/decknix-hub.md`: `wipInterval` 120 vs code 60 (`hub.nix:68`); `teamcity.proxyUrl` port 8080 vs 58080 (`hub.nix:176`); `mergedRetentionDays` missing (`hub.nix:91`).
9. `modules/emacs.md:3-23`: "13+ modules", table misses `deckmacs` and `recording` (17 modules); Agent Shell described as Augment only.
10. `modules/ai/overview.md`: Augment-centric, no gortex, claude, codex, gemini, pi. `modules/window-management.md` never mentions OmniWM.
11. No docs at all for iap-proxy, repo-sync, session-gc.

Accurate on spot check: `modules/linux-builder.md` (defaults match `linux-builder/default.nix:57-100`) and the switch flags in `cli/core-commands.md:8-14`.
