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

### Development Mode

Test local framework changes before pushing:

```bash
# Use your local decknix checkout
decknix switch --dev

# Or specify an explicit path
decknix switch --dev-path ~/projects/decknix
```

This passes `--override-input decknix path:~/tools/decknix` to darwin-rebuild.

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

