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
| `decknix space` | Space picker (GUI) |
| `decknix verify` | Verify system integration |

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

