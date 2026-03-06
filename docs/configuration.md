# Configuration Guide

Decknix uses a layered configuration approach where framework defaults can be overridden at multiple levels.

## Configuration Hierarchy

1. **Decknix Framework** (`darwinModules.default`, `homeModules.default`)
   - Sensible defaults using `lib.mkDefault`
2. **Organization Configs** (`~/.config/decknix/<org>/`)
   - Your customizations, merged in discovery order
3. **Explicit Overrides** (`lib.mkForce`)
   - Force specific values when needed

## Organization Structure

Org configs can be loaded two ways:

1. **Flake inputs** (recommended for teams) — versioned, reproducible, shareable
2. **Filesystem auto-discovery** (local fallback) — quick personal overrides

### Flake Inputs (Recommended)

Org configs become separate git repos used as flake inputs. Each org repo exports
`darwinModules.default` and `homeModules.default`:

```nix
# In your ~/.config/decknix/flake.nix
inputs.my-org-config = {
  url = "github:my-org/decknix-config";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Then wire the modules into your configuration:

```nix
# System modules
modules = [
  decknix.darwinModules.default
  inputs.my-org-config.darwinModules.default
  # ...
];

# Home modules
imports = [
  decknix.homeModules.default
  inputs.my-org-config.homeModules.default
];
```

Benefits:
- **Version pinning** — `flake.lock` pins a known-good version
- **Reproducibility** — `nix flake update my-org-config` to update
- **Distribution** — team members reference the same repo
- **Automated updates** — Renovate can watch for new versions

#### Minimal Org Config Repo

An org config repo needs a `flake.nix` that exports modules:

```nix
# my-org/decknix-config/flake.nix
{
  description = "My Org - Decknix Config";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs, ... }: {
    darwinModules.default = import ./system.nix;
    homeModules.default = import ./home.nix;
  };
}
```

### Filesystem Auto-Discovery (Local Fallback)

Decknix automatically discovers directories in `~/.config/decknix/`:

```
~/.config/decknix/
├── default/           # Always loaded first
│   ├── home.nix
│   └── system.nix
├── work/              # Additional org
│   ├── home.nix
│   └── system.nix
└── personal/          # Another org
    └── home.nix
```

All directories are loaded and merged. The loader traces what it finds:

```
[Loader] Auto-discovered orgs: default work personal
[Loader] home + /Users/you/.config/decknix/default/home.nix
[Loader] home + /Users/you/.config/decknix/work/home.nix
```

### Explicit Org List

Control which orgs are active with `enabled-orgs.nix`:

```nix
# ~/.config/decknix/enabled-orgs.nix
[ "default" "work" ]  # Only these orgs will be loaded
```

### Nested Configurations

For complex setups, use subdirectories:

```
~/.config/decknix/work/
├── home.nix           # Main home config
├── home/              # Additional home modules
│   ├── kubernetes.nix
│   └── aws.nix
└── system.nix
```

All `.nix` files in `home/` subdirectory are automatically loaded.

## Home Manager Options

### Packages

```nix
{ pkgs, ... }: {
  home.packages = with pkgs; [
    kubectl
    helm
    terraform
    awscli2
  ];
}
```

### Git Configuration

```nix
{ ... }: {
  programs.git = {
    settings = {
      user.email = "you@company.com";
      user.name = "Your Name";
      core.editor = "emacsclient -c";
      pull.rebase = true;
    };
  };
}
```

### Shell Aliases

```nix
{ ... }: {
  programs.zsh.shellAliases = {
    k = "kubectl";
    kgp = "kubectl get pods";
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

## Darwin (System) Options

### Homebrew Casks

```nix
{ ... }: {
  homebrew.casks = [
    "docker"
    "slack"
    "1password"
  ];
}
```

### System Preferences

```nix
{ ... }: {
  system.defaults = {
    dock.autohide = true;
    finder.ShowPathbar = true;
    NSGlobalDomain.KeyRepeat = 2;
  };
}
```

## Decknix-Specific Options

### Emacs

```nix
{ ... }: {
  # Disable specific modules
  programs.emacs.decknix.welcome.enable = false;
  programs.emacs.decknix.org.presentation.enable = false;

  # Disable specific language modes
  programs.emacs.decknix.languages.rust.enable = false;
  programs.emacs.decknix.languages.go.enable = false;

  # Configure presentation text size
  programs.emacs.decknix.org.presentation.textScale = 3;
}
```

### Magit & Forge

```nix
{ ... }: {
  # Disable code-review (keep forge)
  programs.emacs.decknix.magit.codeReview.enable = false;

  # Disable forge entirely
  programs.emacs.decknix.magit.forge.enable = false;
}
```

### AeroSpace

```nix
{ ... }: {
  decknix.wm.aerospace = {
    enable = true;
    startAtLogin = true;

    workspaces = {
      "1" = { name = "Terminal"; };
      "2" = { name = "Browser"; };
      "3" = { name = "Code"; };
      "4" = { name = "Chat"; monitor = "secondary"; };
    };

    fuzzyPicker.enable = true;
  };
}
```

### decknix CLI Extensions

Add custom subtasks to the CLI:

```nix
# In system.nix
{ ... }: {
  programs.decknix-cli = {
    enable = true;
    subtasks = {
      cleanup = {
        description = "Garbage collect Nix store";
        command = "nix-collect-garbage -d";
        pinned = true;  # Creates standalone 'cleanup' command
      };
      logs = {
        description = "View system logs";
        command = "log show --last 1h";
      };
    };
  };
}
```

## Using lib.mkForce

When you need to completely override a default:

```nix
{ lib, ... }: {
  # Force disable even if another module enables it
  programs.emacs.decknix.enable = lib.mkForce false;

  # Force a specific package version
  home.packages = [ (lib.mkForce pkgs.nodejs-18_x) ];
}
```

## Debugging Configuration

### Check Loaded Modules

Build with trace to see what's loaded:

```bash
decknix switch 2>&1 | grep "\[Loader\]"
```

### Evaluate Without Building

```bash
nix eval .#darwinConfigurations.default.config.home-manager.users.YOU.home.packages
```

### Check Option Values

```bash
nix repl
:lf .
darwinConfigurations.default.config.programs.emacs.decknix.languages.kotlin.enable
```

