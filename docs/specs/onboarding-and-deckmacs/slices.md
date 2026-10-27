# Slice plan: onboarding, uninstall and the deckmacs split

Derived from [spec.md](spec.md). Each slice is one PR-sized, self-contained change that leaves `main` building and every existing install unchanged unless the slice says otherwise. decknix and the org overlay commit directly to `main`; "PR-sized" means one reviewable commit series, not necessarily a GitHub PR.

Legend:
- **Repo**: where the change lands. "overlay" is the private org config overlay.
- **External**: actions outside a local commit (repo creation, publishing, pushes). Each needs the user.
- **Approval**: a human decision required before the slice starts.

Dependency summary:

```
1 docs-freshness ──┬─────────────────────────────────────────────► 10 docs IA
                   │
2 adoption-state ──┼─► 3 installer v2 ─► 4 uninstall ─► 9 fresh-machine harness
                   │        │                 ▲
                   │        └─► 8 brew audit  │
                   │                          │
                   └─► 7 overlay toggles ─────┘
5 deckmacs extract ─► 6 rename + state migration ─► 11 default Emacs + optional deckmacs
                                                     │
                                                     └─► 12 contract hardening
```

## 1. Docs freshness audit and generators

- Repo: decknix. External: none (docs publish happens on the next push, which needs the user). Approval: none.
- Change: replace the hand list in `docs/generate-options.nix` with the real module tree (home and darwin); generate the CLI reference from `clap`; fix the 11 stale pages in `inventory/current-state.md` section 7 (including the 404 install URL, by pointing at `bin/bootstrap.sh` until slice 3 lands); delete or redirect the orphan root pages; run `mdbook build`, options generation for the pinned nixpkgs, and a link check on PRs as well as `main`.
- Acceptance: every option declared under `decknix*` in home and darwin modules appears in the generated JSON; CLI reference matches `decknix --help` for every subcommand; link check passes; no listed stale discrepancy remains.
- Verify: CI job output; a deliberate drift (remove one option from docs) fails the check locally.

## 2. Adoption state and tier-aware defaults

- Repo: decknix. External: none. Approval: open decision 7 (tier boundaries).
- Change: `decknix.adoption.*` option tree; `mkSystem` reads `~/.config/decknix/adoption.toml` with `builtins.fromTOML` when present; module defaults become `mkDefault (tierAtLeast N)`; absent file means current behaviour ("full"); `decknix.role` becomes an obsolete alias onto tiers; `/etc/decknix/manifest.json` generated from the active generation (launchd labels, `/etc` files, agent-sync targets, leftover paths); fix the template `settings.nix` role comment and `welcomeText`.
- Acceptance: the reference machine's system derivation is byte-identical with no adoption file; each tier fixture (0 to 4 where applicable) evaluates; manifest lists every launchd label in `inventory/current-state.md` section 5 that the generation enables.
- Verify: `nix build` of the reference config before and after (compare out paths); eval tests per tier fixture as flake checks.

## 3. Installer v2 with tiers, plan screen and dry-run

- Repo: decknix. External: none until docs publish. Approval: open decisions 3 (Nix flavour), 5 (Linux scope for tier 0), 10 (tier 0 token).
- Depends on: 2.
- Change: `bin/install.sh` (tier 0 plus handoff; `bin/bootstrap.sh` becomes a shim); `decknix install` and `decknix adopt` in the CLI (tier and component prompts, plan screen, `--dry-run`, `--yes`, `--tier`, `--with`, `--without`, `--org`, `--no-verify`); generated user flake with commented personal override files; backup index; `decknix doctor` verify; login hints; detection of existing installs (writes an adoption file reflecting current state, plan shows no changes).
- Acceptance: whole-script `install.sh` tests (stubbed PATH, temp HOME) cover idempotent re-run, single nix.conf marker, no changes without consent, piped run, refusal on unexpected directory; Rust golden tests for plan output from fixtures; existing-install detection produces an empty plan on the reference machine (`--dry-run`).
- Verify: test suites; `decknix install --dry-run` on the reference machine; a manual tier 0 run in a throwaway macOS user account.

## 4. Uninstall per tier and full

- Repo: decknix. External: none. Approval: none beyond spec approval; the first real run on the reference machine is not part of this slice.
- Depends on: 2, 3.
- Change: `decknix uninstall --tier|--component|--all [--nix] [--dry-run] [--purge-state] [--purge-secrets]` and `install.sh --uninstall` fallback; ordered plan from the manifest, backup index and agent-sync manifest (hash-checked); restore of `*.before-nix-darwin` and legacy `*.before-decknix.<ts>` backups; `decknix doctor --leftovers` scanning every path class in `inventory/uninstall-artifacts.md`.
- Acceptance: plan for `--all` on a fixture of the reference machine lists every artifact class in the inventory in the recommended order; secrets and `local/` never appear as removals without `--purge-secrets`; edited agent-sync copies go to backup, not deletion.
- Verify: Rust fixture tests; end-to-end run is slice 9.

## 5. deckmacs repository extraction with history

- Repo: new `ldeck/deckmacs`, then decknix. External: **create `ldeck/deckmacs` on GitHub and push** (user). Approval: open decision 1 (visibility, licence).
- Depends on: none (can run in parallel with 1 to 4), but must not overlap slice 6 or any in-flight Emacs work in decknix (one writer).
- Change: `git filter-repo` on a fresh clone keeping every historical path of the Emacs tree, `modules/darwin/emacs.nix`, `EMACS_SETUP.md` and the Emacs docs pages, with `--path-rename` into the deckmacs layout; deckmacs flake exporting `homeManagerModules.default`, `darwinModules.daemon`, packages and ERT checks, with option names unchanged (`programs.emacs.decknix.*`) for now; decknix gains a `deckmacs` flake input and its emacs module imports it; decknix removes the tree in one commit naming the split commit.
- Acceptance: reference system derivation unchanged in behaviour (same Emacs packages and config, out paths may differ only by source path); `git log --follow` in deckmacs reaches the earliest Emacs commit; `nix flake check` in deckmacs runs all 3,356 ERT tests.
- Verify: build both ways and diff `default.el`; ERT counts before and after.

## 6. Rename `decknix-` to `deckmacs-` with aliases, and state migration

- Repo: deckmacs, decknix (CLI hook), overlay (coupled Elisp). External: push deckmacs. Approval: open decision 8 (alias lifetime).
- Depends on: 5.
- Change, in order inside the slice: (a) hot-reload matches both prefixes (`deckmacs.nix:112,146`) and the CLI post-switch reload becomes a hook registered via `extensions.json` (removes `cli/src/main.rs:1015-1116` and `modules/darwin/emacs.nix:151` knowledge of deckmacs symbols); (b) generated rename map and alias file (public symbols get obsolete aliases, faces get `face-alias`, old feature names get shim files, private symbols renamed plainly); integration code grouped under `deckmacs-decknix-*`; (c) Nix options to `programs.deckmacs.*` with `mkRenamedOptionModule`; (d) `deckmacs-config-directory` and `deckmacs-state-directory`, move-with-marker migration and fallback reads for Emacs-only files, `deckmacs-migrate-state` dry-run; shared files untouched; (e) overlay Elisp and option references updated in the same coupled change.
- Acceptance: zero `decknix-` definitions left in deckmacs except aliases and shims; existing personal and overlay config evaluates with only rename warnings; a profile copied from the reference machine migrates every Emacs-only file in `inventory/emacs-footprint.md` section 5 with nothing lost (file count and checksum match); hot-reload works across the rename.
- Verify: ERT suites plus new migration tests; byte-compile with zero warnings; reload test in a separate `emacs -Q --batch`, never the user's daemon.

## 7. Overlay component manifest and adoption toggles

- Repo: overlay (and a small decknix loader change if needed). External: push overlay (user). Approval: confirm the component list in `inventory/org-overlay.md` section 6.
- Depends on: 2. Its Emacs component also needs 6.
- Change: overlay exports `decknixOrg` (components, secrets, identity fields, login hints); gates every component on `decknix.adoption.org.<id>.enable`; Emacs component also requires deckmacs; `bootstrap.sh` replaced by a thin installer that calls `decknix install --org <ref>`; stale hand-written options JSON replaced by generated output; org-specific settings moved out of the framework (for example the registry `netrc-file` in `modules/darwin/default.nix:76-83`); private overlay doc written (named components, secrets, logins, pipeline links).
- Acceptance: overlay evaluates at tiers 1, 2, 3 without deckmacs; the reference machine (all components on) is unchanged; installer plan lists overlay components and declared secrets.
- Verify: eval fixtures per tier in overlay CI or flake checks; reference build comparison.

## 8. Homebrew audit helper

- Repo: decknix. External: none. Approval: open decision 4 (audit only, or also declarative `homebrew`).
- Depends on: 3 (shares the plan rendering).
- Change: `decknix brew audit` (read-only) classifying brew leaves and casks as duplicate, migratable (with the decknix option or package), or keep; curated mapping file plus nixpkgs and nix-casks lookups; prints but never runs `brew uninstall`.
- Acceptance: fixture of brew output yields stable classification; command makes no changes (asserted by tests stubbing `brew`).
- Verify: tests; run on a machine with Homebrew (the reference machine has none).

## 9. Fresh-machine test harness

- Repo: decknix. External: VM images or a spare macOS user; possibly a self-hosted runner (user). Approval: choice of harness (tart VM vs fresh user account) and where it runs.
- Depends on: 3, 4.
- Change: scripted scenarios: tier 0 install; tier 1 install; tier 4 install; re-run (no changes); tier down; full uninstall with `--nix`; `doctor --leftovers` empty; login shell works after reboot. Records time to first shell per tier.
- Acceptance: all scenarios pass on a fresh macOS VM; timings recorded against spec section 9 targets.
- Verify: harness logs attached to the commit message or a docs page.

## 10. Docs information architecture

- Repo: decknix (public), deckmacs (its own book), overlay (private doc). External: **publish docs sites** (push to `main` triggers Pages; user). Approval: none beyond spec.
- Depends on: 1; content for tiers needs 3 and 4; deckmacs pages need 5.
- Change: restructure `docs/src/SUMMARY.md` around the ladder (start here, quickstart per tier with undo, concepts, generated reference, guides, uninstall, troubleshooting); move Emacs and agent-shell pages to the deckmacs book with redirects; public site names no private org projects.
- Acceptance: every tier has a quickstart that a VM run (slice 9) follows verbatim; link check green across both books.
- Verify: CI; a reviewer reads the tier 0 and tier 1 quickstarts against a slice 9 run.

## 11. Simple default Emacs and optional deckmacs

- Repo: decknix, template. External: none. Approval: open decision 2 (default flavour).
- Depends on: 5, 6.
- Change: `decknix.editors.emacs.flavour = none | basic | deckmacs`; `basic` module in decknix; decknix drops its hard `deckmacs` input; the generated user flake adds the deckmacs input only for tier 4; existing installs keep deckmacs via their adoption file.
- Acceptance: tier 1 to 3 builds fetch no deckmacs source; reference machine unchanged; switching flavour up and down is clean.
- Verify: build fixtures; `nix flake metadata` of a tier 1 user flake shows no deckmacs.

## 12. Integration contract hardening

- Repo: decknix and deckmacs. External: push both. Approval: open decision 9 (contract versioning).
- Depends on: 6, 11.
- Change: published contract doc and JSON schemas for shared files and CLI `--json` outputs; generated `decknix-contract.json` with the shared constants; contract tests in both repos; deckmacs integration toggles default on only when the decknix CLI is present.
- Acceptance: a changed constant or schema in either repo fails the other's check; deckmacs builds and runs standalone with integrations off.
- Verify: CI in both repos; standalone `emacs-deckmacs` package smoke test.

## Open decisions blocking slices

- Slice 2: tier boundaries (7).
- Slice 3: Nix flavour (3), Linux scope (5), tier 0 token (10); optionally shared installer library (6).
- Slice 5: deckmacs visibility and licence (1).
- Slice 6: alias lifetime (8).
- Slice 8: Homebrew coexistence (4).
- Slice 11: default Emacs (2).
- Slice 12: contract versioning (9).
