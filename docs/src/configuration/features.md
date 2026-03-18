# Enabling & Disabling Features

Every decknix default uses `lib.mkDefault`, making it easy to override in your personal config.

## Emacs Modules

```nix
# ~/.config/decknix/local/home.nix
{ ... }: {
  # Disable specific modules
  programs.emacs.decknix.welcome.enable = false;
  programs.emacs.decknix.org.presentation.enable = false;
  programs.emacs.decknix.http.enable = false;

  # Disable specific language modes
  programs.emacs.decknix.languages.rust.enable = false;
  programs.emacs.decknix.languages.go.enable = false;

  # Disable all Emacs config (use your own)
  programs.emacs.decknix.enable = false;
}
```

See [Emacs module reference](../modules/emacs.md) for all available options.

## Editor Profiles

Switch between pre-defined tiers instead of toggling individual modules:

```nix
{ ... }: {
  decknix.editors.emacs.profile = "standard";  # minimal | standard | full | custom
  decknix.editors.vim.profile = "minimal";     # minimal | standard | custom
}
```

## Window Manager

```nix
{ ... }: {
  # AeroSpace
  decknix.wm.aerospace.enable = false;

  # Or enable with custom workspaces
  decknix.wm.aerospace = {
    enable = true;
    workspaces = {
      "1" = { name = "Terminal"; };
      "2" = { name = "Browser"; };
      "3" = { name = "Code"; };
    };
  };
}
```

## AI Tooling

```nix
{ ... }: {
  decknix.cli.auggie.enable = false;
}
```

## Git Features

```nix
{ ... }: {
  # Disable Forge (GitHub PRs in Emacs)
  programs.emacs.decknix.magit.forge.enable = false;

  # Disable code-review
  programs.emacs.decknix.magit.codeReview.enable = false;
}
```

## System-Level Features

```nix
# ~/.config/decknix/local/system.nix
{ ... }: {
  # Disable Emacs daemon
  services.emacs.decknix.enable = false;

  # Disable AeroSpace system optimisations
  decknix.services.aerospace.enable = false;
}
```

## Using `lib.mkForce`

When a simple override doesn't work (because another module sets a value explicitly), use `mkForce`:

```nix
{ lib, ... }: {
  programs.emacs.decknix.enable = lib.mkForce false;
}
```

Use sparingly — in most cases, a normal override is sufficient because the framework uses `lib.mkDefault`.

