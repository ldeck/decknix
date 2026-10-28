# Settings Reference

The `settings.nix` file in your flake directory defines your machine identity:

```nix
# ~/.config/decknix/settings.nix
{
  username = "ldeck";            # Your macOS username
  hostname = "lds-mbp";         # Machine hostname
  system   = "aarch64-darwin";  # "aarch64-darwin" (Apple Silicon) or "x86_64-darwin" (Intel)
  role     = "developer";       # "developer", "designer" or "minimal" (currently informational)
}
```

## Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `username` | string | `"setup-required"` | Your macOS login username (`whoami`) |
| `hostname` | string | `"setup-required"` | Machine hostname (`hostname -s`) |
| `system` | string | `"aarch64-darwin"` | Nix system identifier |
| `role` | enum | `"developer"` | Recorded as `decknix.role`; currently has no effect on the build |

## Roles

`role` accepts `"developer"`, `"designer"` or `"minimal"` and is passed to home-manager as `decknix.role`. Nothing in the framework reads it today: the role starter templates in `modules/home/options.nix` are not applied by any installer or command, and no module changes its defaults by role. Any other value (for example `"tester"`) fails evaluation.

Role is due to be replaced by adoption tiers; until then it is safe to leave at `"developer"`. Add or remove packages in your `home.nix` regardless of role.

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
- Pass `role` to home-manager as `decknix.role`
- Configure `configLoader` paths

