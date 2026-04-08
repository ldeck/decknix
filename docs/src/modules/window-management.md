# Window Management

Decknix supports several window management approaches for macOS, from
full tiling to simple snapping. Pick the style that suits your workflow —
they can be used individually or combined.

| Tool | Style | Source | Decknix module |
|------|-------|--------|----------------|
| [Amethyst](https://ianyh.com/amethyst/) | Automatic tiling (xmonad-style) | nix-casks | — (package only) |
| [AeroSpace](https://github.com/nikitabobko/AeroSpace) | Manual tiling (i3-style) | nixpkgs | `decknix.wm.aerospace` |
| [Rectangle](https://rectangleapp.com/) | Window snapping (keyboard shortcuts) | nix-casks | — (package only) |
| [SpaceId](https://github.com/dshnkao/SpaceId) | Menu-bar space indicator | nix-casks | — (package only) |
| Native macOS | Stage Manager, Split View, Spaces | built-in | — |

## Amethyst

[Amethyst](https://ianyh.com/amethyst/) is an automatic tiling window
manager for macOS in the style of xmonad. Windows are arranged
automatically into layouts (tall, wide, fullscreen, column, BSP, etc.)
and reflow when windows are added or removed.

Amethyst is the recommended starting point — it works with native macOS
Spaces, requires no SIP disabling, and is fully configurable via its
preferences pane or `defaults write`.

### Installation

Amethyst is not in nixpkgs; install it via nix-casks:

```nix
# home.nix (personal overrides)
{ pkgs, inputs, ... }: {
  home.packages =
    with inputs.nix-casks.packages.${pkgs.stdenv.hostPlatform.system}; [
      amethyst
    ];
}
```

### Configuration

Amethyst stores its configuration in macOS user defaults
(`com.amethyst.Amethyst`). Key settings:

| Default key | Description |
|-------------|-------------|
| `layouts` | Active layout cycle (e.g., `tall`, `wide`, `fullscreen`, `column`) |
| `mod1` | Primary modifier (default: `option + shift`) |
| `mod2` | Secondary modifier (default: `ctrl + option + shift`) |
| `enables-layout-hud` | Show layout name on switch |
| `window-margins` | Enable gaps between windows |
| `floating` | List of app bundle IDs to float |

> **Note — Glide:** [Glide](https://glidewm.org/) is a newer tiling WM
> by the same author as Amethyst. It is not yet recommended for regular
> use and is not included in the default configuration. If you want to
> experiment with it, install via nix-casks and use it in place of
> Amethyst.

## AeroSpace

[AeroSpace](https://github.com/nikitabobko/AeroSpace) is a manual
tiling window manager inspired by i3. Unlike Amethyst's automatic
layouts, AeroSpace gives you direct control over window placement using
keyboard commands. It manages its own virtual workspaces (separate from
macOS Spaces).

Decknix provides both home-manager and darwin modules for AeroSpace.

### Enabling

```nix
# home.nix
{ ... }: {
  decknix.wm.aerospace.enable = true;
}
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `decknix.wm.aerospace.enable` | `false` | Enable AeroSpace |
| `decknix.wm.aerospace.prefixKey` | `"cmd+alt"` | Prefix key for commands |
| `decknix.wm.aerospace.keyStyle` | `"emacs"` | `"emacs"` (arrows) or `"vim"` (hjkl) |
| `decknix.wm.aerospace.showModeHints` | `false` | Show mode notifications |
| `decknix.wm.aerospace.fuzzyPicker.enable` | `true` | Spotlight-like workspace/window picker |

### Workspaces

Define named workspaces with optional monitor assignment:

```nix
{ ... }: {
  decknix.wm.aerospace.workspaces = {
    "1" = { name = "Terminal"; };
    "2" = { name = "Browser"; };
    "3" = { name = "Code"; };
    "4" = { name = "Chat"; monitor = "secondary"; };
  };
}
```

**Default workspaces:** 1–5 (main, web, term, mail, chat) + D, E, N, M,
S (decknix, emacs, notes, music, system).

### System-Level Settings

The darwin module optimises macOS for tiling:

| Option | Default | Effect |
|--------|---------|--------|
| `decknix.services.aerospace.disableStageManager` | `true` | Prevents conflicts |
| `decknix.services.aerospace.disableSeparateSpaces` | `true` | Multi-monitor support |
| `decknix.services.aerospace.disableMissionControlShortcuts` | `true` | Frees Ctrl+arrow keys |
| `decknix.services.aerospace.autohideDock` | `true` | Maximises screen space |

## Rectangle

[Rectangle](https://rectangleapp.com/) is a lightweight window snapping
tool. It provides keyboard shortcuts for half-screen, quarter-screen,
thirds, and other arrangements — similar to Windows snap or
[Spectacle](https://www.spectacleapp.com/) (which Rectangle succeeds).

Rectangle is a good choice if you prefer manual control without full
tiling. It pairs well with Amethyst (use Amethyst for your main
workspace and Rectangle shortcuts for quick one-off snaps).

### Installation

```nix
# home.nix
{ pkgs, inputs, ... }: {
  home.packages =
    with inputs.nix-casks.packages.${pkgs.stdenv.hostPlatform.system}; [
      rectangle
    ];
}
```

Rectangle is configured via its preferences pane. No Decknix module is
needed.

## SpaceId

[SpaceId](https://github.com/dshnkao/SpaceId) shows the current macOS
Space number in the menu bar. Useful alongside any window manager to
keep track of which Space you're on.

### Installation

```nix
# home.nix
{ pkgs, inputs, ... }: {
  home.packages =
    with inputs.nix-casks.packages.${pkgs.stdenv.hostPlatform.system}; [
      spaceid
    ];
}
```

## Hammerspoon

[Hammerspoon](https://www.hammerspoon.org/) provides Lua-based macOS
automation. Decknix uses it for space navigation bindings.

```nix
{ ... }: {
  decknix.wm.hammerspoon = {
    enable = true;
    modifier = "Meta + Ctrl";
  };
}
```

Generates Lua configuration with space navigation bindings.

## Spaces

WM-agnostic multi-monitor workspace management with named space groups
and picker scripts:

```nix
{ ... }: {
  decknix.wm.spaces.workspaces = {
    dev = {
      name = "Development";
      startSpace = 1;
      spaces = [ "terminal" "editor" "browser" ];
      key = "d";
    };
  };
}
```

Generates space picker scripts with shortcodes for quick switching.
Works with any WM or standalone.

