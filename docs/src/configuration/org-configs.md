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

## Benefits

- **Version pinning** — `flake.lock` pins a known-good version
- **Reproducibility** — every team member gets the same tools
- **Easy updates** — `nix flake update my-org-config` to pull latest
- **Automated updates** — Renovate or Dependabot can watch for new versions
- **Personal overrides** — users can still override anything in `~/.config/decknix/<org-name>/`

## Testing Changes

Before merging changes to an org config, test locally:

```bash
cd ~/.config/decknix
decknix switch --dev-path ~/Code/my-org/decknix-config
# Or:
sudo darwin-rebuild switch --flake .#default --impure \
  --override-input my-org-config path:~/Code/my-org/decknix-config
```

See also: [Adding Org Configs for Your Team](../guides/org-configs.md) for a step-by-step walkthrough.

