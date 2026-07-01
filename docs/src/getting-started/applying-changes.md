# Applying Changes

## Day-to-Day Workflow

The core loop is: **edit → switch → done**.

### Switch to Your New Configuration

```bash
decknix switch
```

This runs `darwin-rebuild switch` under the hood, applying both system and home-manager changes atomically.

### Dry Run (Build Without Activating)

```bash
decknix switch --dry-run
```

Builds the configuration to check for errors without actually switching to it.

### Update Framework and Dependencies

```bash
# Update all flake inputs (decknix, nixpkgs, etc.)
decknix update

# Update a specific input
decknix update decknix
```

After updating, run `decknix switch` to apply.

### Test Local Framework or Org-Config Changes

Point `decknix switch` at a local checkout of any flake input using
`--override INPUT=PATH` (repeatable):

```bash
# Test a local decknix checkout
decknix switch --override decknix=~/tools/decknix

# Test decknix and your org-config together
decknix switch \
  --override decknix=~/tools/decknix \
  --override nc-config=~/Code/my-org/decknix-config
```

Each `--override` becomes `--override-input <INPUT> path:<PATH>` on the
underlying `darwin-rebuild` call.

If you use the same overrides every day, pin them in
`~/.config/decknix/settings.toml` so plain `decknix switch` picks them up
automatically — see [`decknix switch` → Persistent overrides](../cli/core-commands.md#persistent-overrides-via-settingstoml).

## Common Patterns

### Edit Personal Config

```bash
$EDITOR ~/.config/decknix/local/home.nix
decknix switch
```

### Add a New Package

```nix
# ~/.config/decknix/local/home.nix
{ pkgs, ... }: {
  home.packages = with pkgs; [
    kubectl
    helm
  ];
}
```

```bash
decknix switch
```

### Disable a Module

```nix
# ~/.config/decknix/local/home.nix
{ ... }: {
  programs.emacs.decknix.welcome.enable = false;
  decknix.wm.aerospace.enable = false;
}
```

```bash
decknix switch
```

## Troubleshooting

### "command not found: decknix"

The CLI isn't in your path yet. Use the full command:

```bash
sudo darwin-rebuild switch --flake ~/.config/decknix#default --impure
```

### Build Errors

Check the trace output to see which files were loaded:

```
[Loader] home + /Users/you/.config/decknix/local/home.nix
[Loader] system + /Users/you/.config/decknix/local/system.nix
```

### Reset to Clean State

```bash
rm -rf ~/.config/decknix
# Re-run bootstrap or nix flake init
```

