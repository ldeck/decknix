# Config Loader

The config loader (`decknix.lib.configLoader`) is the engine that discovers and merges personal override files from `~/.config/decknix/`.

## How It Works

1. **Scan** `~/.config/decknix/` for all subdirectories
2. For each directory, look for:
   - `identity.nix` — org user identity (auto-wired to `config.<org>.user.*`)
   - `home.nix` — home-manager module
   - `system.nix` — nix-darwin module
   - `secrets.nix` — secrets (merged into home-manager)
   - `home/**/*.nix` — recursively loaded home modules
3. Also check for root-level files (`~/.config/decknix/home.nix`, etc.)
4. **Import** every discovered file and trace what was loaded

## Discovery Order

```
~/.config/decknix/
├── local/home.nix              ← loaded
├── local/system.nix            ← loaded
├── local/secrets.nix           ← loaded (merged into home)
├── nurturecloud/identity.nix   ← auto-wired to config.nurturecloud.user.*
├── nurturecloud/home.nix       ← loaded (can reference config.nurturecloud.user.*)
├── nurturecloud/system.nix     ← loaded
├── secrets.nix                 ← loaded (root-level)
└── home.nix                    ← loaded (root-level)
```

All files are merged — ordering within a layer is discovery order (alphabetical by directory name).

## Identity Files

When `<org>/identity.nix` exists, the loader auto-generates NixOS module options under `config.<org>.user.*` and injects them into both darwin and home-manager module systems. This means any Nix module — org configs, personal overrides, or framework modules — can reference the identity without imports.

### Creating an identity file

The file is a plain Nix attrset (not a module):

```nix
# ~/.config/decknix/nurturecloud/identity.nix
{
  email = "you@nurturecloud.com";
  name = "Your Name";
  githubUser = "your-github";
  gpgKey = "ABCDEF1234567890";   # optional — omit or leave empty
}
```

### Using identity in modules

The directory name becomes the option namespace. For a directory named `nurturecloud`, the following options are available everywhere:

```nix
{ config, ... }: {
  # In any darwin or home-manager module:
  some.service.email = config.nurturecloud.user.email;
  some.service.name  = config.nurturecloud.user.name;
  # etc.
}
```

### Available options

| Option | Type | Description |
|--------|------|-------------|
| `config.<org>.user.email` | `str` | User email for the organisation |
| `config.<org>.user.name` | `str` | User full name |
| `config.<org>.user.githubUser` | `str` | GitHub username |
| `config.<org>.user.gpgKey` | `str` | GPG signing key ID (empty if not set) |

### Multi-org support

Each org directory can have its own `identity.nix` with different values. A user working across two orgs might have:

```
~/.config/decknix/
├── nurturecloud/identity.nix   → config.nurturecloud.user.email = "me@nc.com"
└── sideproject/identity.nix    → config.sideproject.user.email = "me@sp.com"
```

The `local/` directory is excluded from identity discovery — it's for personal overrides only.

## Trace Output

When you build, the loader traces what it finds:

```
[Loader] identity + /Users/you/.config/decknix/nurturecloud/identity.nix
[Loader] system + /Users/you/.config/decknix/local/system.nix
[Loader] home + /Users/you/.config/decknix/local/home.nix
[Loader] No secrets modules found.
```

Use this to verify which files are being picked up:

```bash
decknix switch 2>&1 | grep "\[Loader\]"
```

## API Reference

### `configLoader`

```nix
decknix.lib.configLoader {
  lib       = nixpkgs.lib;       # Required
  username  = "your-username";   # Required
  hostname  = "your-hostname";   # Optional (default: "unknown")
  system    = "aarch64-darwin";  # Optional (default: "unknown")
  role      = "developer";       # Optional (default: "developer")
  homeDir   = "/Users/you";      # Optional (auto-derived from username + system)
  configDir = "/Users/you/.config/decknix";  # Optional (auto-derived)
}
```

**Returns:**

```nix
{
  modules = {
    home     = [ ... ];  # List of imported home + secrets modules
    system   = [ ... ];  # List of imported system modules
    identity = [ ... ];  # Auto-generated identity modules (config.<org>.user.*)
  };
  allDirs = [ "local" "nurturecloud" ];  # Discovered directory names
}
```

### `mkSystem`

The top-level builder that wires everything together:

```nix
decknix.lib.mkSystem {
  inputs;                         # Your flake inputs (must include decknix, nixpkgs, nix-darwin)
  settings    = import ./settings.nix;  # { username, hostname, system, role }
  darwinModules = [ ... ];        # Extra darwin modules (org configs)
  homeModules   = [ ... ];        # Extra home-manager modules (org configs)
  extraSpecialArgs = {};          # Additional args passed to modules
  stateVersion = "24.05";        # home.stateVersion
}
```

**Returns:** `{ darwinConfigurations.default = ...; }`

The build merges modules in this order:
1. Framework `darwinModules.default` / `homeModules.default`
2. Your `darwinModules` / `homeModules` args (org configs)
3. `configLoader` identity modules (config.<org>.user.*)
4. `configLoader` system/home modules (personal overrides from filesystem)

