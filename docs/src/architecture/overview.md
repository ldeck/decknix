# How Decknix Works

Decknix uses a **3-layer configuration model** where each layer can override the one below it.

## The 3 Layers

```
┌─────────────────────────────────────────┐
│  Layer 3: Personal Overrides            │  ~/.config/decknix/local/
│  Your packages, identity, preferences   │  ~/.config/decknix/<org>/
├─────────────────────────────────────────┤
│  Layer 2: Organisation Configs          │  Flake inputs (versioned repos)
│  Team tools, standards, shared settings │  e.g. inputs.my-org-config
├─────────────────────────────────────────┤
│  Layer 1: Decknix Framework             │  github:ldeck/decknix
│  Sensible defaults for everything       │  darwinModules + homeModules
└─────────────────────────────────────────┘
```

### Layer 1 — Framework

The decknix flake provides `darwinModules.default` and `homeModules.default` containing opinionated defaults for shell, editors, git, window management, and more. **Every value uses `lib.mkDefault`**, so it can be overridden by any higher layer without `lib.mkForce`.

### Layer 2 — Organisation Configs

Teams create separate repos (e.g. `github:MyOrg/decknix-config`) that export their own `darwinModules.default` and `homeModules.default`. These are added as flake inputs and supply team-specific tools, packages, and settings.

### Layer 3 — Personal Overrides

Each user's `~/.config/decknix/` directory contains personal overrides that are auto-discovered and merged at build time. These live outside git (or in a personal dotfiles repo) and let you customise without touching shared configs.

## How Builds Work

When you run `decknix switch`:

1. **`mkSystem`** reads your `settings.nix` (username, hostname, system, role)
2. Constructs a `darwinConfigurations.default` that merges:
   - Framework modules (Layer 1)
   - Org modules passed via `darwinModules` / `homeModules` (Layer 2)
   - `configLoader` output from `~/.config/decknix/` (Layer 3)
3. Calls `darwin-rebuild switch` to atomically activate the new generation

## Key Design Decisions

- **`lib.mkDefault` everywhere** — the framework never fights your preferences
- **Filesystem auto-discovery** — drop a `.nix` file in the right place and it's loaded
- **Flake inputs for teams** — version-pinned, reproducible, Renovate-watchable
- **Secrets separated** — `secrets.nix` files are gitignored and loaded alongside `home.nix`
- **Impure builds** — `--impure` is required so the config loader can read `~/.config/decknix/` at build time

## Next

- [Directory Layout](./directory-layout.md) — where everything lives
- [Config Loader](./config-loader.md) — how files are discovered and merged

