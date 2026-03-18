# Settings Reference

The `settings.nix` file in your flake directory defines your machine identity:

```nix
# ~/.config/decknix/settings.nix
{
  username = "ldeck";            # Your macOS username
  hostname = "lds-mbp";         # Machine hostname
  system   = "aarch64-darwin";  # "aarch64-darwin" (Apple Silicon) or "x86_64-darwin" (Intel)
  role     = "developer";       # Bootstrap template: "developer", "designer", or "minimal"
}
```

## Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `username` | string | `"setup-required"` | Your macOS login username (`whoami`) |
| `hostname` | string | `"setup-required"` | Machine hostname (`hostname -s`) |
| `system` | string | `"aarch64-darwin"` | Nix system identifier |
| `role` | enum | `"developer"` | Determines which bootstrap template is applied |

## Roles

The `role` field selects a starter template for first-time setup:

| Role | What It Adds |
|------|-------------|
| `developer` | Git config template + nodejs |
| `designer` | Inkscape |
| `minimal` | Nothing extra — blank slate |

After the first build, the role has minimal impact. You can always add or remove packages in your `home.nix` regardless of role.

## Where Settings Are Used

Settings flow into the build via `mkSystem`:

```nix
# flake.nix
outputs = inputs@{ decknix, ... }:
  decknix.lib.mkSystem {
    inherit inputs;
    settings = import ./settings.nix;
  };
```

`mkSystem` uses them to:
- Set `networking.hostName`
- Set `system.primaryUser`
- Derive the home directory path
- Pass `role` to home-manager for template selection
- Configure `configLoader` paths

