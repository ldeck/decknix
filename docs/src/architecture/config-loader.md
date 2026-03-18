# Config Loader

The config loader (`decknix.lib.configLoader`) is the engine that discovers and merges personal override files from `~/.config/decknix/`.

## How It Works

1. **Scan** `~/.config/decknix/` for all subdirectories
2. For each directory, look for:
   - `home.nix` — home-manager module
   - `system.nix` — nix-darwin module
   - `secrets.nix` — secrets (merged into home-manager)
   - `home/**/*.nix` — recursively loaded home modules
3. Also check for root-level files (`~/.config/decknix/home.nix`, etc.)
4. **Import** every discovered file and trace what was loaded

## Discovery Order

```
~/.config/decknix/
├── local/home.nix          ← loaded
├── local/system.nix        ← loaded
├── local/secrets.nix       ← loaded (merged into home)
├── my-org/home.nix         ← loaded
├── my-org/home/
│   └── extra.nix           ← loaded (recursive)
├── secrets.nix             ← loaded (root-level)
└── home.nix                ← loaded (root-level)
```

All files are merged — ordering within a layer is discovery order (alphabetical by directory name).

## Trace Output

When you build, the loader traces what it finds:

```
[Loader] home + /Users/you/.config/decknix/local/home.nix
[Loader] home + /Users/you/.config/decknix/my-org/home.nix
[Loader] system + /Users/you/.config/decknix/local/system.nix
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
    home   = [ ... ];  # List of imported home + secrets modules
    system = [ ... ];  # List of imported system modules
  };
  allDirs = [ "local" "my-org" ];  # Discovered directory names
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
3. `configLoader` output (personal overrides from filesystem)

