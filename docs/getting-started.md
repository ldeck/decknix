# Getting Started with Decknix

This guide walks you through setting up decknix on a fresh or existing macOS system.

## Prerequisites

- macOS (Apple Silicon or Intel)
- Administrator access (for initial Nix installation)
- ~10GB disk space for Nix store

## Installation Options

### Option 1: Fresh Install (Recommended)

Run the bootstrap script to install Nix and decknix together:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ldeck/decknix/main/bin/bootstrap)"
```

This will:
1. Install Nix with flakes enabled
2. Install nix-darwin
3. Create your local config directory at `~/.local/decknix/`
4. Initialize a flake in `~/tmp/decknix-test/`
5. Prompt you for username and hostname

### Option 2: Existing Nix Installation

If you already have Nix installed:

```bash
# Create and enter your config directory
mkdir -p ~/tmp/decknix-test && cd ~/tmp/decknix-test

# Initialize from template
nix flake init -t github:ldeck/decknix

# Edit your settings
nano settings.nix
```

Edit `settings.nix`:

```nix
{
  username = "your-username";     # Your macOS username
  hostname = "your-hostname";     # Your machine name
  system   = "aarch64-darwin";    # or "x86_64-darwin" for Intel
  role     = "developer";         # "developer", "designer", or "minimal"
}
```

Then build and switch:

```bash
decknix switch
# Or if decknix CLI isn't installed yet:
nix run .#darwin-rebuild -- switch --flake .
```

## Directory Structure

After installation, you'll have:

```
~/.local/decknix/
├── default/
│   ├── home.nix        # Your home-manager config
│   └── system.nix      # Your darwin system config
└── .gitignore          # Ignores secrets.nix files

~/tmp/decknix-test/     # Or wherever you placed your flake
├── flake.nix           # Main flake (imports decknix)
├── flake.lock          # Locked dependencies
└── settings.nix        # Your machine settings
```

## First Configuration

### 1. Set Up Git Identity

Edit `~/.local/decknix/default/home.nix`:

```nix
{ pkgs, ... }: {
  programs.git.settings = {
    user.email = "you@example.com";
    user.name = "Your Name";
  };
}
```

### 2. Add Your Packages

```nix
{ pkgs, ... }: {
  home.packages = with pkgs; [
    nodejs
    python3
    go
  ];
}
```

### 3. Apply Changes

```bash
cd ~/tmp/decknix-test
decknix switch
```

## Updating

### Update Decknix Framework

```bash
cd ~/tmp/decknix-test
nix flake update
decknix switch
```

### Update Just Your Config

Edit files in `~/.local/decknix/`, then:

```bash
decknix switch
```

## Multiple Organizations

You can have multiple configuration "orgs" for different contexts:

```
~/.local/decknix/
├── default/          # Personal defaults
│   ├── home.nix
│   └── system.nix
├── work/             # Work-specific config
│   ├── home.nix
│   ├── system.nix
│   └── secrets.nix   # Work credentials (gitignored)
└── enabled-orgs.nix  # Optional: ["default" "work"]
```

All orgs are auto-discovered and merged. Create `enabled-orgs.nix` to explicitly control which orgs are active.

## Troubleshooting

### "command not found: decknix"

The CLI isn't in your path yet. Use the full command:

```bash
nix run .#darwin-rebuild -- switch --flake .
```

### Build Errors

Check the trace output - decknix logs which files it loads:

```
[Loader] Auto-discovered orgs: default work
[Loader] system + /Users/you/.local/decknix/default/system.nix
[Loader] home + /Users/you/.local/decknix/default/home.nix
```

### Reset to Clean State

```bash
# Remove generated config
rm -rf ~/tmp/decknix-test

# Re-initialize
nix flake init -t github:ldeck/decknix
```

## Next Steps

- [Configuration Guide](configuration.md) - Detailed customization options
- [Secrets Guide](secrets.md) - Set up GitHub tokens, SSH keys
- [Emacs Guide](../modules/home/options/editors/emacs/README.md) - Learn the Emacs setup

