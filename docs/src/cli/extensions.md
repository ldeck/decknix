# Extensions

The decknix CLI supports user-defined subcommands via a Nix-based extension system.

## How It Works

Extensions are defined in Nix and compiled into JSON config files that the Rust binary reads at runtime:

```
/etc/decknix/extensions.json          ← system-level (from programs.decknix-cli.subtasks)
~/.config/decknix/extensions.json     ← home-level (from decknix.cli.extensions)
```

Both files are merged. Extensions appear in `decknix help` and support `--help`.

## Defining Extensions (Home-Manager)

```nix
{ ... }: {
  decknix.cli.extensions = {
    board = {
      description = "Issue dashboard across repos";
      command = "${boardScript}/bin/decknix-board";
    };
    cheatsheet = {
      description = "Show WM keybinding cheatsheet";
      command = "${cheatsheetScript}/bin/decknix-cheatsheet";
    };
  };
}
```

## Defining Extensions (System-Level)

```nix
# system.nix
{ ... }: {
  programs.decknix-cli.subtasks = {
    cleanup = {
      description = "Garbage collect Nix store";
      command = "nix-collect-garbage -d";
      pinned = true;  # Also creates standalone 'cleanup' command
    };
  };
}
```

Setting `pinned = true` creates a standalone wrapper so you can run `cleanup` directly without the `decknix` prefix.

## Built-in Extensions

Decknix ships with several extensions:

| Command | Description |
|---------|-------------|
| `decknix board` | Issue dashboard across GitHub repos |
| `decknix cheatsheet` | Show window manager keybinding cheatsheet |
| `decknix repo-jdk` | Resolve the JDK a repository declares |
| `decknix space` | Space picker (GUI) |
| `decknix verify` | Verify system integration |

### `decknix board` — cross-repo issue dashboard

Prints a compact, colourised dashboard of GitHub issues across your configured
repos (open/closed counts per repo, then the open issues with their labels). It
is a thin wrapper over `gh issue list`, so it accepts that command's flags and
passes them through per repo:

```bash
# The board (open issues across all configured repos)
decknix board

# Filter by label / assignee / search, or show closed issues
decknix board --label enhancement
decknix board --assignee @me
decknix board --state closed --limit 20
decknix board --search "sidebar in:title"
```

Requires an authenticated `gh` (`gh auth status`). The repo set comes from the
extension's own configuration.

### `decknix repo-jdk` — per-repository JDK resolution

On a machine running both Nix and SDKMAN, the `java` that wins on `PATH` is an
accident of shell-init ordering: SDKMAN sources late and prepends its `current`
candidate, shadowing the Nix JDK. A build then runs on a JDK its own build files
never asked for, and it surfaces as something unhelpful — an annotation
processor rejecting a class file version, say — rather than as "wrong Java".

Pinning a different default does not fix it, because different repositories
legitimately need different JDKs. `repo-jdk` reads what the repository itself
declares and resolves that to an installed JDK:

```bash
repo-jdk                        # what is declared here, and what is installed
repo-jdk version                # 25
repo-jdk home                   # /nix/store/...-zulu-ca-jdk-25.0.0
eval "$(repo-jdk env)"          # export JAVA_HOME/PATH into the current shell
repo-jdk exec -- ./gradlew build
repo-jdk --dir ~/src/other-repo version
```

Detection walks up from the working directory to the repository root and takes
the first declaration it finds. Within a directory, an explicit toolchain pin
beats a build file's language level, because the pin states an *install* while
the build file states a *language level*:

| Priority | Source | Example |
|----------|--------|---------|
| 1 | `.sdkmanrc` | `java=25.0.1-zulu` |
| 2 | `.tool-versions` | `java temurin-21.0.9` |
| 3 | `.java-version` | `25` |
| 4 | `.mise.toml` | `java = "17"` |
| 5 | `build.gradle.kts` / `build.gradle` | `jvmToolchain(25)`, `JavaLanguageVersion.of(21)`, `JavaVersion.VERSION_17` |
| 6 | `pom.xml` | `<maven.compiler.release>21</maven.compiler.release>` |

Resolution never downloads anything — it selects from JDKs already on the
machine (the Nix installs listed in `org.gradle.java.installations.paths`,
SDKMAN candidates, Gradle's auto-provisioned downloads, and
`/Library/Java/JavaVirtualMachines`), reading each one's `release` file rather
than starting a JVM. Among JDKs matching the declared major it prefers the
Nix-provided one, since that is the only origin that reproduces on a fresh
machine, then the newest patch within that origin. A version named exactly in
`.sdkmanrc` is honoured verbatim.

It never substitutes a different major: a repo asking for 25 will not silently
build on 26.

Exit codes: `3` when nothing is declared, `4` when the declared JDK is not
installed (the message lists which majors are).

Tests live beside the script and are plain stdlib `unittest`:

```bash
cd modules/home/options/cli/repo-jdk
python3 -m unittest discover -s . -p 'test_*.py'
```

## Zsh Completion

Extensions automatically get zsh tab-completion. The module generates a completion script that includes all built-in commands plus discovered extensions.

## Using Extensions

```bash
# Run an extension
decknix board

# Pass arguments
decknix board open --no-color

# Get help
decknix board --help
# Or:
decknix help board
```

Arguments after the extension name are passed through as `$1`, `$2`, etc.

