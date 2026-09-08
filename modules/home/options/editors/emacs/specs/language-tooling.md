# Language tooling — spec (draft)

Eglot, debugging and tree-sitter across the languages and build systems
actually used in `~/Code/nurturecloud/` and `decknix`, for three
purposes: writing code, debugging it, and reviewing someone else's.

## 1. Measured state, not remembered state

Installed and wired:

| Language | Server | Status |
|----------|--------|--------|
| Kotlin | `kotlin-language-server` (fwcd 1.3.13) | wired, **degraded** — see §3 |
| Java | `jdtls` | wired |
| Nix | `nixd` | wired |

Absent:

| Language | Server | nixpkgs | Notes |
|----------|--------|---------|-------|
| Terraform | `terraform-ls` | 0.38.3 | ✅ landed |
| Rust | `rust-analyzer` | 2025-10-28 | ✅ landed |
| Go | `gopls` | 0.20.0 | ✅ landed |
| Python | `basedpyright` | 1.34.0 | |
| TypeScript | `typescript-language-server` | — | |

Two things that read as working and are not:

- **`rust.enable` and `go.enable` are misleading.** They add `rust-mode`
  and `go-mode` and nothing else. No server is installed, no
  `eglot-server-programs` entry exists. Those buffers get syntax
  highlighting and no navigation, while the option name implies support.
- **`dape` is configured with a full `C-c d` keymap and no adapters.**
  No `dape-configs` entries for JVM, Rust or Go. The keys exist; nothing
  attaches.

~~No `treesit-language-source-alist` is configured~~ — ✅ resolved: nine
grammars now ship from nixpkgs on `treesit-extra-load-path`, and
`nix-ts-mode` (which does not exist as a package) is no longer
referenced.

## 2. What the workspace actually contains

```
Gradle/Kotlin   85 build files
Terraform      334 .tf files
Maven           23
Go              17
Node             7
Python           9
Rust             3   (+ decknix/cli)
```

The instinct is to reach for Rust and Go because they are conspicuously
missing. The numbers say otherwise: **Terraform is the biggest
unsupported surface**, and `terraform-platform` is where a great deal of
the real work happens. It has no language server at all.

Rust matters disproportionately to its file count because `decknix/cli`
is where this toolchain is developed — but it is one crate, not a fleet.

## 3. Kotlin is the load-bearing problem

The monolith, measured:

```
kotlin           2.4.10
jvmToolchain     25
JavaLanguageVersion.of(25)
local JDK        OpenJDK 25 (Zulu25.28+85)
```

Against `kotlin-language-server` **1.3.13**. That server cannot resolve
private repos or Google Artifact Registry, and is far behind both the
Kotlin and JDK versions in use. So Kotlin LSP is degraded on the single
largest codebase we work in, which is the opposite of where it should be
strongest.

`useJetBrainsLsp` exists and is deliberately **off**. The reason is
recorded in `lsp.nix` and is worth preserving: nix-casks builds a
derivation that *resolves* — the attribute evaluates, the build succeeds
— and produces a 0 MB stub whose `bin/kotlin-lsp` is a dangling symlink
into a `.sit` payload that was never extracted. Eglot then reports

```
[eglot] (warning) Searching for program: No such file or directory, kotlin-lsp
```

and **no** Kotlin server runs, not even fwcd's. Turning the flag on makes
things strictly worse rather than degrading gracefully.

The lesson that generalises: *the attribute resolving was not evidence
the binary worked*. Any replacement must be verified by running the
server, not by evaluating the derivation.

### 3.1 The real derivation

Groundwork already established: JetBrains' standalone
`kotlin-server-<ver>-aarch64.sit`, linked from the Kotlin/kotlin-lsp
release notes, is despite its extension a plain ZIP (`PK\x03\x04`). So
`unzip` unpacks it with no StuffIt handling, and it ships the
`kotlin-lsp.sh` launcher intended for editors other than VS Code.

Two traps:

- The VS Code `.vsix` build is **not** a substitute. It launches
  `intellij-server --socket 0` — TCP on an ephemeral port, not stdio — so
  `kotlinServerElisp` would need rewriting too.
- It is not in nixpkgs (checked). This has to be a local derivation with
  a pinned hash, which means a manual bump on each release.

### 3.2 Acceptance

Not "the derivation builds". A Kotlin buffer in `upside` must reach a
symbol defined in another module and in a Google Artifact Registry
dependency. That is precisely what fwcd cannot do, so it is the test that
distinguishes the two.

## 4. Design decisions

### 4.1 Make the options honest

`rust.enable` / `go.enable` should either install and wire a server, or
be renamed to say they only provide a major mode. Preference: wire them —
`rust-analyzer` and `gopls` are one line each and both are current in
nixpkgs.

### 4.2 Terraform

`terraform-ls` for `.tf`. Worth a note that `terraform-platform` is
large; if init/validate cost is high, the server may need
`terraform-ls`-specific settings rather than being enabled blind.

### 4.3 Tree-sitter

`*-ts-mode` variants are already referenced in `eglot-server-programs`
entries (`kotlin-ts-mode`, `java-ts-mode`, `nix-ts-mode`) while no
grammars are configured. Either configure
`treesit-language-source-alist` and install grammars, or stop referencing
the `-ts-` modes. Referencing modes that cannot load is how you get a
server wired to a mode that never activates.

Grammars are per-language builds; prefer the nixpkgs
`tree-sitter-grammars` set over `treesit-install-language-grammar`, which
compiles at runtime and will not reproduce on a fresh machine.

### 4.4 Debugging

`dape` needs adapters, in order of value:

1. **JVM** (Kotlin + Java) — the monolith. Hardest: needs
   `java-debug-adapter`, and attaching through Gradle is fiddly.
2. **Rust** — `codelldb`, for `decknix/cli`.
3. **Go** — `dlv`.

JVM first despite being hardest, because it is the only one where the
alternative (println debugging in a large service) is genuinely painful.

## 4.5 Gortex is a fourth layer, not a rival

Gortex is easy to mistake for overlapping with this work, because all of
it "understands code". The distinction that matters is **who is asking**:

| | Scope | Kind | Consumer |
|---|---|---|---|
| tree-sitter | one buffer | syntactic | the human, in the editor |
| eglot / LSP | one project, needs an import | semantic | the human, in the editor |
| gortex | 57 repos, one daemon, over MCP | graph | the **agent**, not the editor |

None substitutes for another. Gortex cannot produce font-lock or
indentation. Tree-sitter cannot say which service publishes an event
another repo consumes. Eglot cannot answer across repos, and needs a
Gradle import before it answers at all.

Verified live: the MCP entry is in `~/.claude.json`, Augment has its
hand-written entry, and pi has `~/.pi/agent/extensions/gortex/index.ts`.
All three agents already reach it; no wiring work is outstanding.

## 5. PR review is a different problem

#165 runs reviews in a **worktree checked out at the PR head**. LSP there
means a cold Gradle import per review — minutes on the monolith, per PR.

So "LSP works for PR review" is not the same task as installing servers.
Options, none yet chosen:

- **Share the Gradle cache** across worktrees so imports are warm. Likely
  the highest-value single change, and needs care: concurrent Gradle
  invocations against one cache are not automatically safe.
- **Accept degraded review support** — xref and syntax only, no full
  import — on the grounds that a reviewer reads a diff rather than
  navigating a whole project.
- **Import lazily**, on the first navigation request rather than on
  buffer open, so a review that never navigates never pays.

### 5.0 Measured

Taken on `upside` (11,274 files, 423 MB `.git`, 9 Gradle modules):

| What | Result |
|------|--------|
| `git worktree add` off `origin/development` | **166 s** (2m46), 96 MB checked out |
| Shared `~/.gradle` | **7.0 GB** — so a new worktree is warm for deps, cold for configuration |
| Cold `./gradlew projects`, contended | **331 s, then FAILED** on a kotlin-dsl cache lock |
| Cold `./gradlew projects`, clean | **672 s (11m 9s)**, BUILD SUCCESSFUL |
| `gortex track --as-worktree --wait` | **>900 s** — did not settle within a 15 min ceiling |

One caveat: the contended failure was **self-inflicted** — an earlier
backgrounded run orphaned a daemon holding the lock. The clean run is the
real figure.

**Eleven minutes.** With a 7 GB warm dependency cache, on a nine-module
project. That is configuration alone — no compilation, no indexing, no
LSP handshake — and it is what a review worktree pays before an editor
can answer a single question about it.

What the numbers establish:

- **Worktree creation alone costs ~2.8 minutes** on the monolith, before
  any language tooling runs at all. That is a floor per review, and it is
  paid by `#165` whether or not LSP is ever attached.
- **Gradle configuration is 11 minutes**, not the "minutes" first
  guessed. Roughly four times the checkout cost, and roughly the length
  of the whole review it is meant to support.
- **Concurrent Gradle against one shared cache serialises on locks and
  can fail outright**, not merely wait. Demonstrated, if accidentally.
  With several review sessions live this stops being a corner case: it is
  the normal operating condition.
- **Gortex indexing a monolith worktree is not the cheap alternative
  either.** It did not settle in 15 minutes.

### 5.0.1 What this decides

The shared-Gradle-cache option is the one the measurement damages most:
it does not just fail to help under concurrency, it introduces a failure
mode that does not exist when each review has no LSP at all.

**Accept degraded review support** is now the recommended default. The
agent navigates via gortex against the primary checkout (§4.5), the human
reads the diff, and neither pays a five-minute import per PR. Per-worktree
gortex indexing is rejected on the same evidence.

That leaves lazy import as the only remaining upgrade path worth
considering, and only for a review the human actually chooses to navigate.

### 5.1 Gortex changes this calculus

The cold-import cost only ever applied to whoever needs to NAVIGATE.
When an agent reviews a PR it navigates through gortex, whose graph is
already built and daemon-held, and which needs no Gradle import at all.
So the expensive option is being weighed for a need the agent does not
have.

That leaves the human reading the diff — who mostly reads a diff rather
than navigating the project. Which makes **accept degraded review
support** considerably stronger than it first looked, and the shared
Gradle cache correspondingly less urgent.

**But gortex tracks primary checkouts only.** Measured: 57 tracked
paths, 0 of them worktrees. So an agent reviewing a PR queries the repo
as indexed — essentially `main` — not the PR head. For "what calls this
function" that is usually fine and often better. For "did this change
break a caller" it is subtly wrong: the graph does not contain the diff
under review, so the agent can describe, confidently, a world the PR has
already altered.

`gortex track --as-worktree` exists precisely for this ("track a linked
git worktree as an independent instance even when its repo is already
tracked elsewhere"). So the fix is available: track on worktree creation
(#165 step 1), untrack on prune (#165 step 2).

Not yet done, because it trades one cost for another: indexing a
monolith worktree per review is not free either, and whether it is
cheaper than a Gradle import is exactly the measurement in §5. Do them
together.

## 6. Open questions

1. **Does the JetBrains server actually fix the monolith?** The claim is
   that fwcd cannot handle GAR and JDK 25. Worth confirming the
   JetBrains one *can*, on a real file, before building a derivation to
   ship it.
2. **`JAVA_HOME` is unset.** jdtls and Gradle both find JDK 25 on PATH
   today, but tooling that reads `JAVA_HOME` will not. Set it, or
   confirm nothing needs it.
3. **Maven (23 files) — is it live?** jdtls handles both, but if those
   are legacy the Java story is simpler than it looks.
4. **Is Terraform navigation actually wanted**, or is that work done
   mostly through `terraform plan` output rather than in the editor?
5. **How much of Go/Node/Python is ours** versus vendored or generated?
   17 `go.mod` files may be a handful of real services.
6. ~~**Is a per-review gortex index cheaper than a Gradle import?**~~
   Answered in §5.0: no. It exceeded 15 minutes on a monolith worktree.
   Neither is cheap; both are rejected for the default path.

## 7. Sequencing

1. Terraform, Rust, Go servers — small, and makes existing options honest ✅ landed
2. Tree-sitter grammars, or stop referencing `-ts-` modes ✅ landed (both)
3. Kotlin: the real JetBrains derivation (§3.1), acceptance per §3.2
4. Measure cold Gradle import in a review worktree (§5) ✅ landed — see §5.0
5. dape adapters, JVM first
6. Review-worktree strategy, decided on the §4 measurement

Steps 1–2 are independent and could land in any order. Step 3 is the
highest value and the highest effort. Steps 4–6 are one thread: do not
design the review-worktree strategy before the number in step 4 exists.
