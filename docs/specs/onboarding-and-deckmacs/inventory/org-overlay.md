# Inventory: the reference org config overlay

The reference overlay is a private repository consumed as a flake input of the user flake. This public spec deliberately does not name it or its sibling projects; file references below are relative to that overlay repository at its `main` as of 2026-10-27. The overlay's own docs will carry the named, org-specific version of this inventory (slice 10).

## 1. Shape

- Inputs (`flake.nix:4-72`): decknix (nixpkgs and nix-casks follow it), an org support-tooling flake, an org prompts flake (shared slash commands), an org setup flake used only for an eval-time consistency warning, and several non-flake sources (an MCP server, an IAP proxy, a vendored binary).
- `darwinModules.default` (`flake.nix:76-160`): imports `system.nix` and enables `decknix.services.iap-proxy` with five instances (one auto-started).
- `homeModules.default` (`flake.nix:163-179`): `home.nix`, git aliases, git hooks, and the support-tooling flake's home module.
- Consumers wire it by hand into `decknix.lib.mkSystem` via `darwinModules` and `homeModules`.

## 2. Bootstrap

`bootstrap.sh` (229 lines, `set -e`): runs the upstream decknix bootstrap if needed (`:29-34`); edits the user `flake.nix` with `sed -i ''` to add the input and module lines (`:42-72`), which depends on the template's exact text; prompts for identity fields and writes `<org>/identity.nix` and `local/home.nix` if absent (`:77-139`); copies a secrets example and writes the issue-tracker token to `<org>/secrets/<name>` with mode 0600 in a 0700 directory, reading it from an env var or a silent prompt (`:144-190`); then always runs `nix flake update` and `decknix switch` (`:197-206`). The secrets handling already matches the target design; the flake editing does not.

## 3. What it sets

The overlay declares no options of its own; it sets decknix and home-manager options. `<org>.user.*` options come from decknix's loader reading `<org>/identity.nix` (`lib/default.nix:174-200` in decknix).

Unconditional today:
- git hooks enabled (`home.nix:615`), including a staged-tree full-build guard for the framework repos and an identity guard for all org repos.
- AI: auggie, Claude, Pi (with cloud model env), Gemini; Claude MCP servers (issue tracker wrapper reading the secret file, Slack over SSE); Claude permission allow/deny lists (`:683-704`).
- Gortex roster for four repos (`:742-754`).
- A Slack MCP launchd agent (`:957`).
- git `includes` for the org workspace directory: email, signing key, gpgsign (`:1036`).
- zsh environment, about 180 git aliases inlined (`:63-253`).
- `home.file` entries for JDK toolchains, Testcontainers/Colima, Emacs Lisp files and snippets.
- Activation scripts: legacy symlink cleanup, a `gh` extension install, an `rsync` of Nix apps (`:1331+`).
- About 55 nixpkgs packages and 9 casks of heavy language and infrastructure tooling.

Agent artifacts via `decknix.cli.agentSync.files` (`:558-612`): 14 local commands, the org prompts flake's commands (discovered, about 8), 22 skills (25 files), 3 subagents, 1 rule, the workspace `AGENTS.md`, a workspace `.claude/settings.json`, and `~/.claude/CLAUDE.md` (forced).

Emacs customisations, unconditional: `programs.emacs.extraConfig` loads an org board and an agent inbox (`:849-850`), plus agent-shell purpose models, broker enable (`:841`), snippets. If the deckmacs options are absent this would fail to evaluate (unverified).

## 4. Modules

- git hooks (895 lines): `enable` is opt-in but `home.nix` turns it on; 14 sub-toggles, all default true; installs hooks and about a dozen helper scripts; sets `core.hooksPath`.
- build guard (85 lines): installed whenever git hooks are on.
- git aliases module (148 lines): imported but never enabled (the aliases are inlined in `home.nix` instead).
- org board (about 1.5k lines Elisp plus 715 test lines): always deployed and loaded.
- agent inbox (226 lines Elisp plus CLI): Elisp always deployed; CLI behind a toggle.
- Review, PR, status, smoke test and helper script modules, each behind a git-hooks sub-toggle.

launchd: the IAP proxies (system level, from `flake.nix`), the Slack MCP agent, and a support capture agent (off).

## 5. Docs

mdBook with built output committed; CI checks a generated packages JSON and deploys. The options JSON (`docs/book/data/org-options.json`) is hand-written placeholder content describing options and files that do not exist. The overlay's `docs/book.toml` and `bootstrap.sh` disagree on the repository name.

## 6. Proposed optional components

- `core`: identity, git `includes`, git hooks and guards, hub issue-tracker and CI settings. Default on.
- `ai`: agent CLIs, MCP registrations, permissions, agent-sync artifacts, Gortex roster, helper scripts. Requires tier 2.
- `services`: IAP proxies, Slack MCP agent. Requires tier 1; prompts for its secrets.
- `emacs`: org board, agent inbox, snippets, agent-shell purpose settings, support dashboard feed. Requires tier 4.
- `tooling`: heavy language and infrastructure packages and casks, JDK toolchains, Testcontainers/Colima config. Requires tier 1 (casks need tier 3).

Each becomes `config.decknix.adoption.org.<id>.enable`, declared in the overlay's `decknixOrg` manifest (spec section 6.4).

## 7. Relationship to the org Nix build pipelines

The org's Nix build pipeline projects (owned elsewhere, read-only for this work) give adopting service repos a library flake (`mkService` for Gradle, Maven, Go, Rust; Avro contracts), `nix flake init` templates, packages, checks, maintenance apps and reusable CI workflows. They assume a developer machine has:
- Nix with flakes (no particular installer named),
- a GitHub token for private inputs, via `NIX_CONFIG="access-tokens = github.com=$(gh auth token)"`,
- on macOS, a multi-user daemon (they work around the daemon not seeing registry credentials with a prefetch app),
- `gcloud` application default credentials for some bootstraps,
- a Linux builder (or CI) for container images.

They ship no dev shells and do not mention decknix. Tier 0 covers them; tier 3's Linux builder helps container builds.

## 8. Sibling installers (patterns to reuse)

- A Nix-first org installer (about 410 lines) with seven gated steps: platform check, Nix via the Determinate installer with the undo command printed, flakes probe and marker-guarded user `nix.conf` append with a per-call fallback, repository checkout, opt-in direnv, verify, printed login hints. `-y/--yes`, `/dev/tty` prompts, `CI` means no. Never writes secrets. Tests stub `nix`, `git`, `uname`, `curl` on PATH with a temp `HOME` and assert on a call log, including a piped `bash -s` run and an idempotent second run. Reusable functions: output helpers, `tty_ok`/`confirm`, profile loading, flakes probe, nix.conf append, `nix profile add` fallback, direnv rc wiring, piped-run detection, the test harness.
- A non-Nix org support-tooling installer (about 1.9k lines) that doubles as a health dashboard, collects tokens into the OS keychain with a 0600 file fallback, and already reads a decknix path for one token. Its keychain secret helper is a candidate for an optional secrets backend (open decision, not in scope).
