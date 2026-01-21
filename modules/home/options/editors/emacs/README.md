# Emacs Configuration

This directory contains the decknix Emacs configuration modules.

## Features

### Default Configuration (`default.nix`)

Provides a sensible default Emacs configuration with:
- Line numbers enabled globally
- Column number mode
- Current line highlighting
- Matching parentheses highlighting
- Recent files tracking
- Better scrolling behavior
- Spaces instead of tabs (2-space default)
- Auto-refresh buffers when files change
- Less intrusive backup files
- Winner mode for window configuration undo/redo

### Magit (`magit.nix`)

Provides Git integration through Magit:
- Magit package installed
- Default keybinding: `C-x g` for `magit-status`
- Word-granularity diff refinement enabled

## Usage

Both modules are enabled by default. To disable them in your local configuration:

```nix
{
  programs.emacs.decknix.enable = false;  # Disable all emacs config
  programs.emacs.decknix.magit.enable = false;  # Disable just magit
}
```

## Emacs Daemon

The Emacs daemon is configured in `modules/darwin/emacs.nix` and is enabled by default on macOS.

To connect to the daemon, use:
```bash
ec filename  # Opens file in emacsclient
```

Or use the full emacsclient command:
```bash
emacsclient -c  # Create new frame
```

## Customization

You can override the Emacs package in your local configuration:

```nix
{
  programs.emacs.decknix.package = pkgs.emacs29;
  services.emacs.decknix.package = pkgs.emacs29;  # For daemon
}
```

## Note on Evil Mode

Evil mode (Vim emulation) is **not** included in this configuration. If you want to add it, you can do so in your local configuration:

```nix
{
  programs.emacs.extraPackages = epkgs: with epkgs; [
    evil
  ];
  
  programs.emacs.extraConfig = ''
    (require 'evil)
    (evil-mode 0)  # Disabled by default, use (evil-mode 1) to enable
  '';
}
```

