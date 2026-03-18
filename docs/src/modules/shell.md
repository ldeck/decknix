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

