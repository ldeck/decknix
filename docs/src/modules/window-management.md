# Window Management

Decknix includes tiling window manager support for macOS.

## AeroSpace

[AeroSpace](https://github.com/nikitabobko/AeroSpace) is a tiling window manager inspired by i3. Decknix provides both home-manager and darwin modules.

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
| `decknix.wm.aerospace.enableModeIndicator` | — | Show current mode in status bar |

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

**Default workspaces:** 1–5 (main, web, term, mail, chat) + D, E, N, M, S (decknix, emacs, notes, music, system).

### System-Level Settings

The darwin module optimises macOS for tiling:

| Option | Default | Effect |
|--------|---------|--------|
| `decknix.services.aerospace.disableStageManager` | `true` | Prevents conflicts |
| `decknix.services.aerospace.disableSeparateSpaces` | `true` | Multi-monitor support |
| `decknix.services.aerospace.disableMissionControlShortcuts` | `true` | Frees Ctrl+arrow keys |
| `decknix.services.aerospace.autohideDock` | `true` | Maximises screen space |

## Hammerspoon

[Hammerspoon](https://www.hammerspoon.org/) provides Lua-based macOS automation.

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

Multi-monitor workspace management with named space groups:

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

