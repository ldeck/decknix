# Installation

This guide walks you through setting up decknix on a fresh or existing macOS system.

## Prerequisites

- macOS (Apple Silicon or Intel)
- Administrator access (for initial Nix installation)
- ~10GB disk space for the Nix store

## Option 1: Fresh Install (Recommended)

Run the bootstrap script to install everything from scratch:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ldeck/decknix/main/bin/bootstrap)"
```

This will:
1. Install Nix with flakes enabled
2. Install nix-darwin
3. Create your local config directory at `~/.config/decknix/`
4. Initialize a flake in `~/.config/decknix/`
5. Prompt you for username and hostname

## Option 2: Existing Nix Installation

If you already have Nix with flakes enabled:

```bash
# Create and enter your config directory
mkdir -p ~/.config/decknix && cd ~/.config/decknix

# Initialize from template
nix flake init -t github:ldeck/decknix

# Edit your settings
$EDITOR settings.nix
```

Edit `settings.nix` with your machine details:

```nix
{
  username = "your-username";     # macOS username
  hostname = "your-hostname";     # Machine name
  system   = "aarch64-darwin";    # or "x86_64-darwin" for Intel
  role     = "developer";         # "developer", "designer", or "minimal"
}
```

Then build and switch:

```bash
decknix switch
# Or if decknix CLI isn't installed yet:
sudo darwin-rebuild switch --flake .#default --impure
```

## For Organisation Members

If your team maintains an org config repo, check their README for a dedicated bootstrap script that sets up both decknix and the team configuration in one step.

See [Organisation Configs](../configuration/org-configs.md) for how org configs work.

## Next Steps

- [First Configuration](./first-config.md) — set up your identity and packages
- [Applying Changes](./applying-changes.md) — learn the day-to-day workflow

