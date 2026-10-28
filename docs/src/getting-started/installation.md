# Installation

This guide walks you through setting up decknix on a fresh or existing macOS system.

## Prerequisites

- macOS (Apple Silicon or Intel)
- Administrator access (the installer uses `sudo` to back up `/etc` shell files and to activate nix-darwin)
- ~10GB disk space for the Nix store

## Option 1: Fresh Install (Recommended)

Run the bootstrap script:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ldeck/decknix/main/bin/bootstrap.sh)"
```

The script (`bin/bootstrap.sh`) runs these steps:

1. **Choose a version.** Prompts for a git ref of decknix (default `main`).
2. **Install Nix**, if `nix` is not already on `PATH`. You choose an installer:
   1. the Nix community installer (a fork of the Determinate Systems installer), with your user added to `trusted-users`. This is the default and the one decknix is tested with;
   2. the official Nix installer;
   3. the Determinate Systems installer.
3. **Pre-flight.** Moves any real (non-symlink) `/etc/nix/nix.conf`, `/etc/zshenv`, `/etc/zshrc` and `/etc/bashrc` aside to `<file>.before-decknix.<timestamp>` with `sudo`, so nix-darwin can manage them.
4. **Initialise** `~/.config/decknix/` from the flake template (if it has no `flake.nix` yet) and write `settings.nix` after prompting for username, hostname and role.
5. **Activate** with `sudo nix run nix-darwin -- switch --flake .#default --impure` (or `darwin-rebuild switch` on a re-run).

Re-running the script on an installed machine skips the phases that are already done.

### Non-interactive install

Pass `--non-interactive` (or set `CI=true`) to skip every prompt. Defaults come from these environment variables:

| Variable | Default | Meaning |
|----------|---------|---------|
| `DECKNIX_REF` | `main` | decknix git ref to install |
| `DECKNIX_INSTALLER` | `1` | Nix installer choice (1, 2 or 3, as above) |
| `DECKNIX_USER` | `$(whoami)` | macOS username |
| `DECKNIX_HOST` | `$(hostname -s)` | Hostname |
| `DECKNIX_ROLE` | `developer` | Value written to `role` in `settings.nix` |

Set `SKIP_NIX=1`, `SKIP_PREFLIGHT=1`, `SKIP_INIT=1` or `SKIP_ACTIVATE=1` to skip a phase.

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
  username = "your-username";     # macOS username (whoami)
  hostname = "your-hostname";     # Machine name (hostname -s)
  system   = "aarch64-darwin";    # or "x86_64-darwin" for Intel
  role     = "developer";         # "developer", "designer" or "minimal" (currently informational)
}
```

If nix-darwin is not managing `/etc` yet, move the shell files it will replace out of the way first (this is what the bootstrap pre-flight does):

```bash
for f in /etc/nix/nix.conf /etc/zshenv /etc/zshrc /etc/bashrc; do
  [ -f "$f" ] && [ ! -L "$f" ] && sudo mv "$f" "$f.before-decknix"
done
```

Then build and activate. The `decknix` CLI is installed by this first activation, so use nix-darwin directly:

```bash
sudo nix run nix-darwin -- switch --flake .#default --impure
```

From then on, use `decknix switch`.

## For Organisation Members

If your team maintains an org config overlay, check its README for a dedicated bootstrap script that sets up both decknix and the team configuration in one step.

See [Organisation Configs](../configuration/org-configs.md) for how org configs work.

## Next Steps

- [First Configuration](./first-config.md): set up your identity and packages
- [Applying Changes](./applying-changes.md): learn the day-to-day workflow
