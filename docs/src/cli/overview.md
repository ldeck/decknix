# decknix CLI

The `decknix` CLI is a Rust binary that provides the primary interface for managing your configuration.

## Usage

```
decknix [COMMAND]

Commands:
  update              Update flake inputs
  switch              Switch system configuration
  wt                  Manage git worktrees
  session             Find, create, and resume agent sessions (alias: s)
  repos               Keep local clones fresh (alias: repo)
  pull-local-changes  Pull local changes to agent skills/commands back into repositories
  help                Show help (including extensions)
  <ext>               Run a user-defined extension
```

The full, generated flag reference for every built-in command is in [Command Reference](./reference.md).

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

- [Core Commands](./core-commands.md): what each command does, with examples
- [Command Reference](./reference.md): every flag, generated from the CLI itself
- [Extensions](./extensions.md): add custom subcommands
