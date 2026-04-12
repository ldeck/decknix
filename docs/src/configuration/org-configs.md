# Organisation Configs

Org configs let teams share a standard set of tools, packages, and settings through versioned flake inputs.

## How It Works

An org config is a separate git repo that exports `darwinModules.default` and `homeModules.default`. These are wired into your flake as inputs:

```nix
# ~/.config/decknix/flake.nix
{
  inputs = {
    decknix.url = "github:ldeck/decknix";
    nixpkgs.follows = "decknix/nixpkgs";
    nix-darwin.follows = "decknix/nix-darwin";

    # Team config
    my-org-config = {
      url = "github:MyOrg/decknix-config";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ decknix, ... }:
    decknix.lib.mkSystem {
      inherit inputs;
      settings = import ./settings.nix;
      darwinModules = [ inputs.my-org-config.darwinModules.default ];
      homeModules   = [ inputs.my-org-config.homeModules.default ];
    };
}
```

## Creating an Org Config Repo

Minimal structure:

```
my-org-config/
├── flake.nix
├── home.nix          # Team home-manager modules
├── system.nix        # Team darwin modules
└── README.md
```

### flake.nix

```nix
{
  description = "My Org - Decknix Config";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs, ... }: {
    darwinModules.default = import ./system.nix;
    homeModules.default = import ./home.nix;
  };
}
```

### home.nix

```nix
{ pkgs, ... }: {
  home.packages = with pkgs; [
    awscli2
    terraform
    jdk17
  ];
}
```

## Per-User Identity

Each user creates an `identity.nix` in their org's config directory. The framework's config loader auto-discovers it and generates `config.<org>.user.*` options available in all Nix modules:

```nix
# ~/.config/decknix/my-org/identity.nix
{
  email = "you@my-org.com";
  name = "Your Name";
  githubUser = "your-github";
  gpgKey = "ABCDEF1234567890";   # optional
}
```

Org modules can then reference the identity without any imports:

```nix
# In org config system.nix:
{ config, lib, ... }: {
  decknix.services.hub.jira.email = lib.mkDefault config.my-org.user.email;

  programs.git.includes = [{
    condition = "gitdir:~/Code/my-org/";
    contents.user.email = config.my-org.user.email;
  }];
}
```

Org bootstraps should prompt for this identity on first setup and write `identity.nix` automatically. See [Config Loader — Identity Files](../architecture/config-loader.md#identity-files) for full details.

## Benefits

- **Version pinning** — `flake.lock` pins a known-good version
- **Reproducibility** — every team member gets the same tools
- **Easy updates** — `nix flake update my-org-config` to pull latest
- **Automated updates** — Renovate or Dependabot can watch for new versions
- **Personal overrides** — users can still override anything in `~/.config/decknix/<org-name>/`
- **Identity wiring** — per-user org identity flows automatically via `identity.nix`

## Testing Changes

Before merging changes to an org config, test locally:

```bash
cd ~/.config/decknix
decknix switch --override my-org-config=~/Code/my-org/decknix-config
# Or:
nix build .#darwinConfigurations.default.system --impure \
  --override-input my-org-config path:~/Code/my-org/decknix-config
```

See also: [Adding Org Configs for Your Team](../guides/org-configs.md) for a step-by-step walkthrough.

