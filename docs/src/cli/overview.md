# decknix CLI

The `decknix` CLI is a Rust binary that provides the primary interface for managing your configuration.

## Usage

```
decknix [COMMAND]

Commands:
  switch    Switch system configuration
  update    Update flake inputs
  help      Show help (including extensions)
  <ext>     Run a user-defined extension
```

The CLI automatically discovers **user extensions** defined via Nix and displays them alongside built-in commands.

## Architecture

```
┌──────────────┐     ┌──────────────────────────┐
│  Rust Binary  │ ──→ │  darwin-rebuild / nix     │
│  (decknix)    │     │  (actual build commands)  │
└──────┬───────┘     └──────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────────┐
│  Extension Discovery                          │
│  /etc/decknix/extensions.json  (system)       │
│  ~/.config/decknix/extensions.json  (home)    │
└──────────────────────────────────────────────┘
```

The binary always runs from `~/.config/decknix/` so `--flake .#default` resolves correctly.

## Getting Help

```bash
# Show all commands (built-in + extensions)
decknix help

# Help for a specific command
decknix switch --help
decknix help board
```

## Next

- [Core Commands](./core-commands.md) — `switch`, `update`
- [Extensions](./extensions.md) — add custom subcommands

