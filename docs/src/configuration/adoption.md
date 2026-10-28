# Adoption Tiers

decknix is adopted in tiers. Each tier adds to the one below it, and each optional component can be switched on or off on its own. The choice lives in `~/.config/decknix/adoption.toml`.

| Tier | Name | Adds |
|------|------|------|
| 0 | Nix | Nix with flakes only. No decknix system; handled by the installer, not by `mkSystem` |
| 1 | Base | nix-darwin, home-manager, the `decknix` CLI, zsh, starship, git, core CLI tools, Vim |
| 2 | AI agents | Gortex code graph; the agent CLIs you enable (`decknix.ai.*`) |
| 3 | Workstation | GUI apps, Nerd Fonts, Linux builder, repo-sync and session-gc agents |
| 4 | deckmacs | The full decknix Emacs configuration and its daemon |

Agent CLIs, window managers, the hub and the session broker stay opt-in at every tier, as they always were.

## The file

```toml
# ~/.config/decknix/adoption.toml
version = 1
tier = 3

# Optional: override a component's tier default.
[components]
linux-builder = false

# Optional: org overlay components, by the id the overlay declares.
[org]
core = true
services = false
```

`mkSystem` reads it at evaluation time (`lib/adoption.nix`) and sets `decknix.adoption.*` in both the system and home-manager layers. Unknown keys, unknown components, a `tier` outside 1 to 4 and a missing `tier` all fail evaluation with a message naming the file. Tier 0 also fails, because there is no system to build for it.

## Components

| Component | Tier | Gates |
|-----------|------|-------|
| `gortex` | 2 | `decknix.ai.gortex.enable` |
| `apps` | 3 | `decknix.apps.ungoogledChromium.enable` |
| `fonts` | 3 | the system Nerd Fonts |
| `linux-builder` | 3 | `decknix.linuxBuilder.enable` |
| `repo-sync` | 3 | `services.decknix.repoSync.enable` |
| `session-gc` | 3 | `services.decknix.sessionGc.enable` |
| `emacs` | 4 | `programs.emacs.decknix.enable` and `services.emacs.decknix.enable` |

A component is on when the tier reaches its tier, unless `[components]` says otherwise. The gated options only change their *default*, so setting one of them in your `local/` modules still wins over the tier.

Turning `linux-builder` off makes nix-darwin delete the builder's disk image on the next switch.

## No adoption file

An install with no `adoption.toml` keeps exactly what it had before tiers existed: tier 4 with every component on. Its system derivation is unchanged; `tests/closure-unchanged.sh <baseline-rev>` proves that for a real user flake by comparing drv paths.

## Install manifest

Every generation computes a manifest of what it owns outside the Nix store: launchd labels (system and home), `/etc` entries, agent-sync targets and leftover paths a switch cannot remove (for example the Linux builder disk). Uninstall and `doctor` read it.

- It is always buildable: `nix build ~/.config/decknix#darwinConfigurations.default.config.system.build.decknixManifest --impure`.
- Once an `adoption.toml` exists it is also linked to `/etc/decknix/manifest.json` (`decknix.adoption.writeManifest`). Installs without the file do not get the `/etc` link, which keeps their system unchanged until they adopt.

## Roles

`role` in `settings.nix` is informational and does not map onto tiers. See [Settings Reference](./settings.md#roles).
