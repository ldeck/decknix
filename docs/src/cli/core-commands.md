# Core Commands

## `decknix switch`

Build and activate your configuration.

```
Usage: decknix switch [OPTIONS]

Options:
    --dry-run          Build only — don't activate
    --dev              Use local framework checkout instead of pinned remote
    --dev-path <PATH>  Explicit path to local decknix checkout (implies --dev)
```

### Examples

```bash
# Normal switch
decknix switch

# Dry run (check for errors without activating)
decknix switch --dry-run

# Test local framework changes
decknix switch --dev

# Specify framework path explicitly
decknix switch --dev-path ~/projects/decknix
```

### How It Works

1. `cd ~/.config/decknix`
2. Runs `sudo darwin-rebuild switch --flake .#default --impure`
3. With `--dev`, adds `--override-input decknix path:<dev-path>`
4. With `--dry-run`, uses `build` instead of `switch`

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

