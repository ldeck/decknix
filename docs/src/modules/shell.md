# Shell & Terminal

Decknix configures Zsh as the default shell with modern enhancements.

## Zsh

Enabled by default with:

- **Completion** — case-insensitive, menu-driven completion
- **Autosuggestion** — fish-like suggestions from history
- **Syntax highlighting** — command validation as you type
- **History** — 50,000 entries, shared across sessions, prefix-based search

## Starship Prompt

[Starship](https://starship.rs/) provides a fast, customisable prompt showing git status, language versions, and more.

Customise the prompt character:

```nix
{ ... }: {
  programs.starship.settings.character = {
    success_symbol = "[➜](bold green)";
    error_symbol = "[✗](bold red)";
  };
}
```

### Inline Timestamp

The prompt line shows a wall-clock timestamp grouped with the
command-duration so they read as a pair:

```
~/.config/decknix on ☁️  lachlan@example.com · 2026-04-30T14:32:15 · took 45s
➜
```

Configure via `programs.starship.decknix.timestamp.*`:

```nix
{ ... }: {
  programs.starship.decknix.timestamp = {
    enable    = true;                   # default
    format    = "%Y-%m-%dT%H:%M:%S";    # default (ISO 8601)
    separator = " · ";                  # default
    style     = "dimmed";               # default
  };
}
```

`format` accepts any [Chrono strftime](https://docs.rs/chrono/latest/chrono/format/strftime/) string. Common alternatives:

| Format               | Renders as              |
|----------------------|-------------------------|
| `%Y-%m-%dT%H:%M:%S`  | `2026-04-30T14:32:15`   |
| `%T`                 | `14:32:15`              |
| `%H:%M`              | `14:32`                 |
| `%a %H:%M`           | `Tue 14:32`             |
| `%I:%M %p`           | `02:32 PM`              |

Set `enable = false` to drop the timestamp and revert `cmd_duration`
to upstream defaults.

## Delta (Diff Viewer)

[Delta](https://github.com/dandavison/delta) is configured as the default git pager, providing syntax-highlighted diffs.

## Default Shell Aliases

Decknix doesn't impose shell aliases — add your own:

```nix
{ ... }: {
  programs.zsh.shellAliases = {
    ll = "ls -la";
    gs = "git status";
    gp = "git pull --rebase";
  };
}
```

## Extra Init

Add custom shell initialization:

```nix
{ ... }: {
  programs.zsh.initExtra = ''
    # Source work credentials
    [[ -f ~/.config/secrets/env.sh ]] && source ~/.config/secrets/env.sh
  '';
}
```

## Session Variables

```nix
{ ... }: {
  home.sessionVariables = {
    EDITOR = "emacsclient -c";
    VISUAL = "emacsclient -c";
  };
}
```

