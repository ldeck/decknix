# Emacs Configuration for Decknix

This document describes the Emacs configuration that has been added to the decknix flake.

## What's Been Added

### 1. Home Manager Modules

Located in `modules/home/options/editors/emacs/`:

- **`default.nix`**: Core Emacs configuration with sensible defaults
  - Line numbers, column numbers, current line highlighting
  - Better scrolling, auto-refresh, backup file management
  - Winner mode for window configuration undo/redo
  
- **`magit.nix`**: Git integration via Magit
  - Magit package installed
  - Keybinding: `C-x g` for `magit-status`
  - Word-granularity diff refinement

### 2. Darwin Module

Located in `modules/darwin/emacs.nix`:

- Enables the Emacs daemon service via nix-darwin
- Provides `services.emacs.enable` option
- Adds `ec` command (emacsclient wrapper) to system packages
- Configurable package and additional PATH

## Testing Locally

### Option 1: Test in Your User Configuration

If you have a local flake that uses decknix, update it to use your local version:

```nix
{
  inputs = {
    # Point to your local decknix repo
    decknix.url = "path:/Users/ldeck/tools/decknix";
    
    nixpkgs.follows = "decknix/nixpkgs";
    nix-darwin.follows = "decknix/nix-darwin";
  };
}
```

Then rebuild:

```bash
darwin-rebuild switch --flake ~/.config/nix-darwin#default --impure
```

### Option 2: Test with the Template

Create a test directory:

```bash
mkdir -p ~/test-decknix-emacs
cd ~/test-decknix-emacs
nix flake init -t path:/Users/ldeck/tools/decknix
```

Edit `settings.nix`:
```nix
{
  username = "your-username";
  hostname = "your-hostname";
  system = "aarch64-darwin";  # or x86_64-darwin
  role = "developer";
}
```

Edit `flake.nix` to use local decknix:
```nix
{
  inputs = {
    decknix.url = "path:/Users/ldeck/tools/decknix";
    # ... rest of inputs
  };
}
```

Build and switch:
```bash
nix run nix-darwin -- switch --flake .#default --impure
```

## Verifying the Installation

After rebuilding, verify:

1. **Emacs daemon is running:**
   ```bash
   launchctl list | grep emacs
   ```

2. **Emacs is available:**
   ```bash
   which emacs
   emacs --version
   ```

3. **Emacsclient wrapper is available:**
   ```bash
   which ec
   ec --version
   ```

4. **Test opening a file:**
   ```bash
   ec test.txt
   ```

5. **Test Magit:**
   - Open emacs: `ec`
   - Press `C-x g` (should open Magit status if in a git repo)

## Configuration Options

### Disabling Emacs

In your local configuration:

```nix
{
  # Disable emacs entirely
  programs.emacs.decknix.enable = false;
  
  # Or just disable the daemon
  services.emacs.decknix.enable = false;
  
  # Or just disable magit
  programs.emacs.decknix.magit.enable = false;
}
```

### Using a Different Emacs Package

```nix
{
  programs.emacs.decknix.package = pkgs.emacs29;
  services.emacs.decknix.package = pkgs.emacs29;
}
```

### Adding Additional Packages

```nix
{
  programs.emacs.extraPackages = epkgs: with epkgs; [
    company
    flycheck
    lsp-mode
  ];
}
```

### Adding Custom Configuration

```nix
{
  programs.emacs.extraConfig = ''
    ;; Your custom Emacs Lisp here
    (setq custom-variable t)
  '';
}
```

## Notes

- **Evil mode is NOT included** by default (as requested)
- **Magit is included** and enabled by default
- The daemon starts automatically on login
- All modules use `lib.mkDefault` so they can be easily overridden
- The configuration follows the same pattern as the existing vim configuration

## Troubleshooting

### Keybindings Not Working (e.g., C-x g for Magit)

If `C-x g` doesn't open Magit, check:

1. **Did you rebuild your configuration?**
   ```bash
   # The configuration won't take effect until you rebuild
   darwin-rebuild switch --flake ~/.config/nix-darwin#default --impure

   # After rebuilding, restart emacs or kill existing processes
   pkill emacs
   # Or restart the daemon:
   launchctl stop org.nix-community.home.emacs
   launchctl start org.nix-community.home.emacs
   ```

2. **Check the generated default.el:**
   ```bash
   # Find the generated config
   find /nix/store -name "default.el" -path "*/emacs-packages-deps/*" 2>/dev/null | head -1 | xargs cat
   ```

   You should see:
   - `(autoload 'magit-status "magit" "Open Magit status buffer" t)`
   - `(global-set-key (kbd "C-x g") 'magit-status)`

3. **Check if magit is installed:**
   ```bash
   # Look for magit in the elpa directory
   find /nix/store -path "*/emacs-packages-deps/*/elpa/*magit*" -type d 2>/dev/null | head -5
   ```

4. **Test in Emacs:**
   ```elisp
   ;; In emacs, run: M-x magit-status
   ;; This should work even if the keybinding doesn't
   ```

5. **Check for conflicting configuration:**
   - Look for `~/.emacs`, `~/.emacs.d/init.el`, or `~/.config/emacs/init.el`
   - These files might override the Nix configuration

### Daemon Issues

If the daemon doesn't start:

```bash
# Check the service status
launchctl list | grep emacs

# View logs
log show --predicate 'process == "emacs"' --last 1h

# Manually start the daemon
launchctl start org.nix-community.home.emacs
```

If emacsclient can't connect:

```bash
# Check if daemon is running
ps aux | grep emacs

# Try starting emacs in daemon mode manually
emacs --daemon

# Then try connecting
emacsclient -c
```

