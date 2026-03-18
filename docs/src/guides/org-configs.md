# Adding Org Configs for Your Team

This guide walks through creating a shared configuration repo for your organisation.

## Step 1: Create the Repo

```bash
mkdir my-org-config && cd my-org-config
git init
```

## Step 2: Create the Flake

```nix
# flake.nix
{
  description = "My Org - Decknix Config";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs, ... }: {
    darwinModules.default = import ./system.nix;
    homeModules.default = import ./home.nix;
  };
}
```

## Step 3: Define Team Packages

```nix
# home.nix
{ pkgs, ... }: {
  home.packages = with pkgs; [
    awscli2
    terraform
    jdk17
    nodejs
    python3
  ];
}
```

```nix
# system.nix
{ pkgs, ... }: {
  homebrew.casks = [
    "docker"
    "slack"
  ];
}
```

## Step 4: Push and Reference

```bash
git add . && git commit -m "Initial org config"
git remote add origin git@github.com:MyOrg/decknix-config.git
git push -u origin main
```

Team members add it to their `~/.config/decknix/flake.nix`:

```nix
inputs.my-org = {
  url = "github:MyOrg/decknix-config";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

And wire the modules:

```nix
outputs = inputs@{ decknix, ... }:
  decknix.lib.mkSystem {
    inherit inputs;
    settings = import ./settings.nix;
    darwinModules = [ inputs.my-org.darwinModules.default ];
    homeModules   = [ inputs.my-org.homeModules.default ];
  };
```

## Step 5: Test Before Merging

```bash
decknix switch --dev-path ~/Code/my-org/decknix-config
```

Or manually:

```bash
sudo darwin-rebuild switch --flake .#default --impure \
  --override-input my-org path:~/Code/my-org/decknix-config
```

## Step 6: Automate Updates

Add [Renovate](https://docs.renovatebot.com/) or Dependabot to auto-PR when the org config updates.

Team members pull updates with:

```bash
decknix update my-org
decknix switch
```

## Tips

- Keep the org config **minimal** — only team-wide requirements
- Let individuals override in `~/.config/decknix/<org-name>/`
- Add a `bootstrap.sh` for one-command onboarding
- Include a `secrets.nix.example` showing what credentials team members need

