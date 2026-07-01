# Core Commands

## `decknix switch`

Build and activate your configuration.

```
Usage: decknix switch [OPTIONS]

Options:
    --dry-run                    Build only — don't activate
    --force                      Bypass the preflight equality check and always activate
    --override <INPUT=PATH>      Override a flake input with a local path (repeatable)
    --no-overrides               Ignore [switch.overrides] in settings.toml
    --dev                        Use local framework checkout instead of pinned remote
    --dev-path <PATH>            Explicit path to local decknix checkout (implies --dev)
```

### Examples

```bash
# Normal switch (skips sudo activation if nothing changed)
decknix switch

# Dry run (check for errors without activating)
decknix switch --dry-run

# Force re-activation even when the built system matches the current one
decknix switch --force

# Test local framework changes
decknix switch --dev

# Specify framework path explicitly
decknix switch --dev-path ~/projects/decknix
```

### How It Works

1. `cd ~/.config/decknix`
2. **Preflight** (unless `--dry-run` or `--force`): evaluates the system
   derivation via `nix build --no-link --print-out-paths` and compares the
   resulting store path with `readlink /run/current-system`.
   - **Match** → skips `sudo darwin-rebuild switch` entirely, verifies user
     LaunchAgents (`org.nixos.*`) are running, kickstarts any that are down,
     and exits.
   - **Differ** → prints old/new store paths and proceeds with activation.
3. Runs `sudo darwin-rebuild switch --flake .#default --impure` (reusing the
   cached preflight build).
4. With `--dev`, adds `--override-input decknix path:<dev-path>`.
5. With `--dry-run`, uses `build` instead of `switch` and skips the preflight.

### Why the preflight

Once you've applied a configuration, re-running `decknix switch` with no code
changes should be a fast no-op. The preflight lets Nix's evaluation cache do
the work (typically 1–3s) instead of paying for a full `sudo darwin-rebuild
switch` (30–90s of activation scripts). The `--force` flag is there for when
you deliberately want to re-run activation — for example, after manually
editing a launchd plist or when debugging an activation script.

### Persistent overrides via `settings.toml`

If you routinely run `decknix switch` with the same `--override` flags (e.g.
you keep local checkouts of the framework and your org config), you can pin
them once in `~/.config/decknix/settings.toml`:

```toml
[switch.overrides]
decknix = "~/tools/decknix"
nc-config = "~/Code/my-org/decknix-config"
```

Every `decknix switch` then applies those overrides by default. Precedence,
from highest to lowest:

1. `--override INPUT=PATH` on the command line (per-input; wins over config)
2. `[switch.overrides]` in `settings.toml`
3. The published flake inputs (from `flake.lock`)

The status line annotates each override with `[config]` when it came from
`settings.toml`, so it's always clear where a given path was sourced from:

```
🔄 Switching (decknix=/Users/you/tools/decknix [config], nc-config=/Users/you/Code/foo/decknix-config [config])...
```

To force a switch against the published inputs (ignoring `settings.toml`
entirely), pass `--no-overrides`:

```bash
# Ignore settings.toml — use whatever is pinned in flake.lock
decknix switch --no-overrides

# Ignore settings.toml but apply one one-off override
decknix switch --no-overrides --override decknix=~/experiments/decknix
```

`settings.toml` lives alongside your user config; it is a personal file and
should not be checked into a shared `decknix-config` repo. If your
`decknix-config` doesn't already ignore it, add it:

```gitignore
settings.toml
```

### Dev Path Resolution

When `--dev` is used, the framework path is resolved in order:

1. `--dev-path` flag (highest priority)
2. `DECKNIX_DEV` environment variable
3. `~/tools/decknix` (default fallback)

## `decknix update`

Update flake inputs (dependencies).

```
Usage: decknix update [INPUT]

Arguments:
    [INPUT]  Specific input to update (optional)
```

### Examples

```bash
# Update all inputs
decknix update

# Update only decknix
decknix update decknix

# Update only nixpkgs
decknix update nixpkgs
```

Runs `nix flake update [input]` under the hood. After updating, run `decknix switch` to apply.

## `decknix help`

Show help for all commands, including dynamically discovered extensions.

```bash
# Show all commands
decknix help

# Help for a specific command or extension
decknix help switch
decknix help board
```

Extensions show their description and underlying command.

