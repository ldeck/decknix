# AI Agent Guidelines — decknix

> Universal guidelines for AI agents working in this repository.
> Applies to Augment, Cursor, Copilot, Claude Code, and any other AI tooling.

## Project Overview

**decknix** is a Nix-based macOS configuration framework combining nix-darwin,
home-manager, and Nix Flakes. It provides opinionated defaults for editors,
shell, git, AI tooling, and system configuration with a 3-layer override model
(framework → org → personal).

### Key Paths

| Path | Purpose |
|------|---------|
| `lib/default.nix` | `mkSystem` + `configLoader` (identity discovery, module wiring) |
| `modules/darwin/` | macOS system-level config (launchd, system packages) |
| `modules/darwin/hub.nix` | decknix-hub launchd service + Nix options |
| `modules/home/options/` | home-manager modules (editors, shell, git, AI) |
| `modules/home/options/editors/emacs/` | Emacs configuration (13+ modules) |
| `pkgs/decknix-hub/` | Background work-item aggregator (GitHub, Jira, TeamCity) |
| `pkgs/nix-open/` | Nix-aware macOS app launcher/restarter |
| `cli/` | Rust CLI (`decknix switch`, `decknix update`, etc.) |
| `docs/` | mdBook documentation |
| `templates/` | Flake templates for `nix flake init` |

### Build & Test

```bash
# Build the full system (from a decknix-config repo)
cd ~/.config/decknix
decknix switch              # Apply configuration
decknix switch --dry-run    # Build without activating

# Override any flake input with a local path (repeatable, for pre-PR testing)
decknix switch --override decknix=~/tools/decknix
decknix switch --override decknix=~/tools/decknix --override nc-config=~/Code/my-org/decknix-config

# Build just the system derivation (for CI or validation)
nix build .#darwinConfigurations.default.system --impure \
  --override-input decknix path:$HOME/tools/decknix
```

## Rules for AI Agents

### 1. Documentation Must Stay Current

**Every code change must include corresponding documentation updates.** This is
non-negotiable. Specifically:

- **README.md files**: Update module READMEs when adding, changing, or removing
  features, keybindings, options, or behaviour.
- **AGENTS.md files**: Update when architecture, conventions, or workflows change.
- **Inline comments**: Nix modules and Elisp code should have clear comments
  explaining *why*, not just *what*.
- **Issue references**: Link to GitHub issues when implementing tracked features.
- **Planned features**: Mark unimplemented but tracked features as **(Planned)**
  in documentation rather than omitting them.

### 2. Nix Conventions

- All framework defaults use `lib.mkDefault` so user overrides always win.
- Module options follow the pattern: `programs.<tool>.decknix.<module>.<option>`.
- Use `mkEnableOption` for feature flags with `default = true` for batteries-included.
- Package sourcing priority: stable nixpkgs → unstable nixpkgs → custom derivations.
- Always use `with lib;` at the top of modules.

### 3. Commit Conventions

- Use conventional commits: `feat(scope):`, `fix(scope):`, `perf(scope):`,
  `docs(scope):`, `refactor(scope):`.
- Scope is the module or area: `emacs`, `cli`, `shell`, `darwin`, `agent-shell`.
- Reference issues: `(#73)`, `(#74)`.
- Do NOT add co-author footers (e.g. `Co-authored-by:`) to commits or messages.
- **Commit incrementally** on the main branch — after each logically complete unit of work
  (e.g. after tests pass, after a bug fix is verified), commit immediately without waiting
  for explicit user instruction. This keeps the history clean and progress visible.
- Do NOT **push** (to remote) without explicit user permission.

### 4. Testing Changes — Follow TDD

The build runs all ERT test suites as part of the Nix derivation. A red test
breaks the build for everyone. The test suite is the authoritative specification
of intended behaviour — not a trailing record of what the code happens to do.

**The TDD cycle for every code change:**

1. **Red** — Before touching implementation, write or update the test(s) to
   describe the *intended* new behaviour. The test must fail at this point.
2. **Green** — Change the implementation until the tests pass.
3. **Refactor** — Clean up while keeping the tests green.

This applies to all change types:

- **New behaviour**: write the failing test first, then implement.
- **Changing an existing contract** (glyphs, faces, data shapes, function
  signatures): update the tests to the new contract first (red), then update the
  implementation (green). Never ship a contract change where implementation and
  tests diverge — the Nix build will catch it, but it creates wasted cycles.
- **Bug fixes**: write a reproducing test first, then fix.

**Quick local test run** (faster feedback than a full Nix build):

```bash
# Elisp — run one test file in isolation
emacs -Q -batch \
  -L modules/home/options/editors/emacs/agent-shell/hub/ \
  -L modules/home/options/editors/emacs/agent-shell/tests/ \
  -l decknix-hub-teamcity -l decknix-test-helpers \
  -l decknix-hub-teamcity-test \
  --eval "(ert-run-tests-batch-and-exit t)"

# Rust (cli / decknix-hub)
cargo test --manifest-path cli/Cargo.toml
cargo test --manifest-path pkgs/decknix-hub/Cargo.toml
```

**Incremental & Full Build Verification** (required before declaring a change complete):

Before committing, always run incremental checks based on what changed:

- **Nix Packages**: If you changed `Cargo.toml`, `Cargo.lock`, or source code for a package in `pkgs/`, verify the `cargoHash`/`vendorHash` by running a build of that specific derivation.
- **Elisp Syntax**: For changes to standalone `.el` files, verify they parse and
  byte-compile with **zero warnings**:
  ```bash
  emacs -Q -batch -f batch-byte-compile <file>.el
  ```
  A clean run produces no output. Any warning line is a build risk — fix it before
  committing. Common causes and fixes:
  - `reference to free variable 'foo'` — add `(defvar foo)` to the forward
    declarations block at the top of the file.
  - `the function 'bar' is not known to be defined` — add
    `(declare-function bar "source-file-without-extension")` to the forward
    declarations block.
  - Escaped quotes `\"` inside string literals — standalone `.el` files must use
    plain `"`. Only Nix heredocs need `\"`. See **Heredoc Escaping** below.
  - Docstring line exceeds 80 characters — wrap it.
- **Elisp Declaration Hygiene**: Every cross-module reference must be declared at
  the top of the calling file:
  - Functions from other packages: `(declare-function fn-name "source-package")`
  - Variables defined elsewhere: `(defvar var-name)` (no initial value = compiler hint only)
  - Variables needed at runtime in tests: `(defvar var-name initial-value)` so
    `let`-binding works dynamically (see Emacs AGENTS.md §Tests rule 2)
  - Sidebar buffer name: always `agent-shell-workspace-sidebar-buffer-name` (forward-declared
    as `(defvar agent-shell-workspace-sidebar-buffer-name "*Agent Sidebar*")`),
    never the literal string.
- **Elisp Tests (MANDATORY when changing tested behaviour)**: A clean
  byte-compile is **not** sufficient — a glyph / face / data-shape / signature
  change compiles fine while silently diverging from its ERT suite, so the drift
  only surfaces in the full Nix build (a wasted ~10 min cycle). Whenever you
  touch a function that has a test file under `agent-shell/tests/`, run that
  suite locally **before committing** and confirm `0 unexpected`:
  ```bash
  emacs -Q -batch \
    -L modules/home/options/editors/emacs/agent-shell/hub/ \
    -L modules/home/options/editors/emacs/agent-shell/tests/ \
    -l decknix-<feature> -l decknix-<feature>-test \
    --eval "(ert-run-tests-batch-and-exit t)"
  ```
  If the change is a deliberate contract change, the test edit comes **first**
  (red → green); the local ERT run is what proves the implementation and the
  spec agree before the Nix build re-confirms it.
- **Nix Modules**: Verify the full system derivation builds (this catches Nix syntax errors and cross-module Elisp failures):

```bash
cd ~/.config/decknix && nix build .#darwinConfigurations.default.system \
  --impure --override-input decknix path:$HOME/tools/decknix
```

- For Elisp changes, verify parenthesis balance early — the byte compiler
  catches this during the Nix build, but catching it locally saves a full cycle.
- **Heredoc Escaping Warning**: When moving code between `agent-shell.nix` (which
  requires `\"` escaping for quotes) and standalone `.el` files (which require
  plain `"`), ensure you unescape/escape accordingly. A standalone `.el` file
  with `\"` causes "Too many arguments" parse errors — not "Interactive form
  missing" as one might expect. Run `emacs -Q -batch -f batch-byte-compile` on
  the file immediately after any such move.
- Test activation with `decknix switch --override decknix=~/tools/decknix` only
  when the user requests it.

### 5. Command Execution — Prefer Nix-managed Tools

This is a Nix-managed system. **Never hardcode paths** to system binaries like
`/usr/bin/python3`, `/usr/bin/env python3`, or `/usr/local/bin/node`. Instead:

- **Use bare command names** (`python3`, `node`, `ruby`, `java`) and rely on the
  Nix-first PATH to resolve them.
- The PATH has Nix paths **before** system paths:
  ```
  ~/.nix-profile/bin → /run/current-system/sw/bin → /nix/var/nix/profiles/default/bin → /usr/local/bin → /usr/bin → /bin
  ```
- If you need to verify which version will be used: `which python3` or
  `command -v node`.
- In generated Nix code (scripts, launchd services), use `${pkgs.python3}/bin/python3`
  to pin to a specific Nix-managed version.
- **Exception**: `#!/usr/bin/env bash` shebangs are acceptable — this is the
  standard portable idiom.

This rule is also enforced globally via `~/.augment-guidelines` (generated by
`agent-shell.nix`) so Augment sessions in any workspace inherit it.

### 6. Emacs-Specific Rules

See `modules/home/options/editors/emacs/AGENTS.md` for detailed Emacs conventions
including the dynamic binding pattern, package sourcing, and agent-shell architecture.

