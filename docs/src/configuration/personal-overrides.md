# Personal Overrides

Personal overrides live in `~/.config/decknix/` and are auto-discovered by the [config loader](../architecture/config-loader.md).

## Directory Structure

```
~/.config/decknix/
├── local/                  # Generic personal config (always loaded)
│   ├── home.nix
│   ├── system.nix
│   └── secrets.nix         # Gitignored
├── my-org/                 # Per-org overrides (matches flake input name)
│   ├── home.nix
│   └── home/
│       └── kubernetes.nix  # Recursively loaded
└── secrets.nix             # Root-level secrets
```

## How Overrides Work

Decknix framework defaults all use `lib.mkDefault`, so any value you set in your personal files wins automatically:

```nix
# Framework sets:   programs.git.settings.pull.rebase = lib.mkDefault true;
# Your override:    programs.git.settings.pull.rebase = false;  ← wins
```

For cases where another module explicitly sets a value (without `mkDefault`), use `lib.mkForce`:

```nix
{ lib, ... }: {
  programs.emacs.decknix.welcome.enable = lib.mkForce false;
}
```

## Common Override Patterns

### Add Packages

```nix
# ~/.config/decknix/local/home.nix
{ pkgs, ... }: {
  home.packages = with pkgs; [
    kubectl
    helm
    terraform
    awscli2
  ];
}
```

### Shell Aliases

```nix
{ ... }: {
  programs.zsh.shellAliases = {
    k = "kubectl";
    tf = "terraform";
  };
}
```

### Environment Variables

```nix
{ ... }: {
  home.sessionVariables = {
    EDITOR = "emacsclient -c";
    AWS_PROFILE = "default";
  };
}
```

### macOS System Preferences

```nix
# ~/.config/decknix/local/system.nix
{ ... }: {
  system.defaults = {
    dock.autohide = true;
    finder.ShowPathbar = true;
    NSGlobalDomain.KeyRepeat = 2;
  };
}
```

### Homebrew Casks

```nix
# ~/.config/decknix/local/system.nix
{ ... }: {
  homebrew.casks = [
    "docker"
    "slack"
    "1password"
  ];
}
```

## Debugging

See which files are loaded:

```bash
decknix switch 2>&1 | grep "\[Loader\]"
```

Evaluate a specific option without building:

```bash
nix repl
:lf .
darwinConfigurations.default.config.home-manager.users.YOU.home.packages
```

