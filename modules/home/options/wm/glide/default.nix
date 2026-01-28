{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.wm.glide;

  # Convert keybindings attrset to TOML-compatible format
  keybindingsToToml = bindings:
    concatStringsSep "\n" (mapAttrsToList (key: value:
      if isString value then
        ''"${key}" = "${value}"''
      else
        ''"${key}" = ${builtins.toJSON value}''
    ) bindings);

  # Generate the TOML config content
  generateConfig = ''
    # GlideWM configuration - managed by decknix
    # Override in ~/.local/decknix/<org>/home.nix

    [settings]
    animate = ${boolToString cfg.animate}
    default_disable = ${boolToString cfg.defaultDisable}
    focus_follows_mouse = ${boolToString cfg.focusFollowsMouse}
    mouse_follows_focus = ${boolToString cfg.mouseFollowsFocus}
    mouse_hides_on_focus = ${boolToString cfg.mouseHidesOnFocus}
    outer_gap = ${toString cfg.gaps.outer}
    inner_gap = ${toString cfg.gaps.inner}

    group_bars.enable = ${boolToString cfg.groupBars.enable}
    group_bars.thickness = ${toString cfg.groupBars.thickness}
    group_bars.horizontal_placement = "${cfg.groupBars.horizontalPlacement}"
    group_bars.vertical_placement = "${cfg.groupBars.verticalPlacement}"

    status_icon.enable = ${boolToString cfg.statusIcon.enable}

    [settings.experimental]
    status_icon.space_index = ${boolToString cfg.statusIcon.showSpaceIndex}
    status_icon.color = ${boolToString cfg.statusIcon.color}

    [keys]
    ${keybindingsToToml cfg.keybindings}

    ${cfg.extraConfig}
  '';

in {
  options.decknix.wm.glide = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable GlideWM tiling window manager for macOS.

        GlideWM integrates with macOS Spaces, allowing you to use Mission Control
        and standard macOS space navigation while having tiling window management
        on each space.

        Key features:
        - Alt+Z toggles tiling management for current space
        - Alt+Shift+E saves and exits (for restore on restart)
        - hjkl navigation between windows
        - Works per-space, integrates with Mission Control

        NOTE: The glide package must be installed separately (e.g., via nix-casks
        in your local home.nix). This module only provides configuration.
      '';
    };

    # Basic settings
    animate = mkOption {
      type = types.bool;
      default = true;
      description = "Enable window animations.";
    };

    defaultDisable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Disable tiling on each space by default.
        Use Alt+Z to enable tiling on a space.
      '';
    };

    focusFollowsMouse = mkOption {
      type = types.bool;
      default = true;
      description = "Focus window under mouse as it moves.";
    };

    mouseFollowsFocus = mkOption {
      type = types.bool;
      default = true;
      description = "Move mouse to center of window on focus change.";
    };

    mouseHidesOnFocus = mkOption {
      type = types.bool;
      default = true;
      description = "Hide mouse when a new window is focused.";
    };

    # Gaps
    gaps = {
      outer = mkOption {
        type = types.int;
        default = 0;
        description = "Gap between windows and screen edges (pixels).";
      };
      inner = mkOption {
        type = types.int;
        default = 0;
        description = "Gap between adjacent windows (pixels).";
      };
    };

    # Group bars (for tabbed/stacked containers)
    groupBars = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Show visual bars for tabbed/stacked containers.";
      };
      thickness = mkOption {
        type = types.int;
        default = 6;
        description = "Thickness of group bars in pixels.";
      };
      horizontalPlacement = mkOption {
        type = types.enum [ "top" "bottom" ];
        default = "top";
        description = "Placement of horizontal group bars.";
      };
      verticalPlacement = mkOption {
        type = types.enum [ "left" "right" ];
        default = "right";
        description = "Placement of vertical group bars.";
      };
    };

    # Status icon
    statusIcon = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Show Glide status icon in menu bar.";
      };
      showSpaceIndex = mkOption {
        type = types.bool;
        default = true;
        description = "(Experimental) Show current space index on status icon.";
      };
      color = mkOption {
        type = types.bool;
        default = false;
        description = "(Experimental) Use color in status icon.";
      };
    };

    # Keybindings
    keybindings = mkOption {
      type = types.attrsOf types.anything;
      default = {
        # Exit/control
        "Alt + Shift + E" = "save_and_exit";
        "Alt + Z" = "toggle_space_activated";

        # Navigation (vim-style)
        "Alt + H" = { move_focus = "left"; };
        "Alt + J" = { move_focus = "down"; };
        "Alt + K" = { move_focus = "up"; };
        "Alt + L" = { move_focus = "right"; };

        # Move windows
        "Alt + Shift + H" = { move_node = "left"; };
        "Alt + Shift + J" = { move_node = "down"; };
        "Alt + Shift + K" = { move_node = "up"; };
        "Alt + Shift + L" = { move_node = "right"; };

        # Resize
        "Alt + Ctrl + H" = { resize = { direction = "left"; percent = 5; }; };
        "Alt + Ctrl + J" = { resize = { direction = "down"; percent = 5; }; };
        "Alt + Ctrl + K" = { resize = { direction = "up"; percent = 5; }; };
        "Alt + Ctrl + L" = { resize = { direction = "right"; percent = 5; }; };

        # Tree navigation
        "Alt + A" = "ascend";
        "Alt + D" = "descend";

        # Layouts
        "Alt + N" = "next_layout";
        "Alt + P" = "prev_layout";

        # Splitting
        "Alt + Backslash" = { split = "horizontal"; };
        "Alt + Equal" = { split = "vertical"; };

        # Grouping (tabs/stacks)
        "Alt + T" = { group = "horizontal"; };
        "Alt + S" = { group = "vertical"; };
        "Alt + E" = "ungroup";

        # Floating
        "Alt + Shift + Space" = "toggle_window_floating";
        "Alt + Space" = "toggle_focus_floating";

        # Fullscreen
        "Alt + F" = "toggle_fullscreen";

        # Debug
        "Alt + Shift + D" = "debug";
      };
      description = ''
        Keybindings for GlideWM. Keys are formatted as "Modifier + Key".
        Values can be strings (command names) or attribute sets (complex commands).

        Example:
        {
          "Alt + H" = { move_focus = "left"; };
          "Alt + Shift + E" = "save_and_exit";
        }
      '';
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Extra TOML configuration to append.";
    };

    # Workspace management (conceptual layer on top of macOS Spaces)
    workspaces = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          name = mkOption {
            type = types.str;
            description = "Human-readable name for the workspace.";
          };
          spaces = mkOption {
            type = types.listOf types.str;
            default = [ "primary" ];
            description = ''
              Logical space names within this workspace.
              These map to macOS Spaces (1-based indexing).
              Example: [ "primary" "editor" "monitoring" "docs" ]
            '';
          };
          startSpace = mkOption {
            type = types.int;
            default = 1;
            description = ''
              Starting macOS Space number for this workspace.
              Subsequent spaces use consecutive numbers.
            '';
          };
        };
      });
      default = { };
      example = {
        nurturecloud = {
          name = "NurtureCloud";
          spaces = [ "primary" "editor" "monitoring" "pipeline" "docs" "messages" "planning" ];
          startSpace = 1;
        };
        personal = {
          name = "Personal";
          spaces = [ "main" "browser" "notes" ];
          startSpace = 8;
        };
      };
      description = ''
        Workspace definitions. A workspace is a logical grouping of macOS Spaces.
        This enables organizing your 16 macOS spaces into project-based workspaces.

        Each workspace maps its logical space names to consecutive macOS Spaces
        starting from startSpace.
      '';
    };
  };

  # Config implementation
  config = mkIf cfg.enable {
    # Write the glide configuration file
    home.file.".glide.toml".text = generateConfig;

    # Add helper scripts for workspace navigation
    home.packages = mkIf (cfg.workspaces != { }) [
      (pkgs.writeShellScriptBin "glide-workspace" ''
        #!/usr/bin/env bash
        # Navigate to a workspace's primary space using choose-gui

        WORKSPACES="${concatStringsSep "\n" (mapAttrsToList (id: ws: "${ws.name}:${toString ws.startSpace}") cfg.workspaces)}"

        if command -v choose &>/dev/null; then
          SELECTED=$(echo "$WORKSPACES" | choose -n 20 | cut -d: -f2)
          if [ -n "$SELECTED" ]; then
            osascript -e "tell application \"System Events\" to key code $((17 + SELECTED)) using control down"
          fi
        else
          echo "choose-gui not found. Install it with: nix profile install nixpkgs#choose-gui"
          echo "Available workspaces:"
          echo "$WORKSPACES"
        fi
      '')

      (pkgs.writeShellScriptBin "glide-space" ''
        #!/usr/bin/env bash
        # Navigate to a specific space within current or specified workspace

        # Build list of all spaces across all workspaces
        SPACES="${concatStringsSep "\n" (concatLists (mapAttrsToList (id: ws:
          imap1 (i: spaceName: "${ws.name}/${spaceName}:${toString (ws.startSpace + i - 1)}") ws.spaces
        ) cfg.workspaces))}"

        if command -v choose &>/dev/null; then
          SELECTED=$(echo "$SPACES" | choose -n 30 | cut -d: -f2)
          if [ -n "$SELECTED" ]; then
            osascript -e "tell application \"System Events\" to key code $((17 + SELECTED)) using control down"
          fi
        else
          echo "choose-gui not found. Install it with: nix profile install nixpkgs#choose-gui"
          echo "Available spaces:"
          echo "$SPACES"
        fi
      '')

      (pkgs.writeShellScriptBin "glide-cheatsheet" ''
        #!/usr/bin/env bash
        # Show GlideWM cheatsheet

        CHEATSHEET="GlideWM Cheatsheet
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

BASICS
  Alt+Z           Toggle tiling for current space
  Alt+Shift+E     Save layout and exit

NAVIGATION (Vim-style)
  Alt+H/J/K/L     Focus left/down/up/right
  Alt+A           Ascend (select parent)
  Alt+D           Descend (select child)

MOVE WINDOWS
  Alt+Shift+H/J/K/L   Move window left/down/up/right

RESIZE
  Alt+Ctrl+H/J/K/L    Resize in direction (5%)

SPLITTING
  Alt+\\\\          Split horizontal
  Alt+=           Split vertical

GROUPING (Tabs/Stacks)
  Alt+T           Tab group (horizontal)
  Alt+S           Stack group (vertical)
  Alt+E           Ungroup

FLOATING
  Alt+Shift+Space Toggle window floating
  Alt+Space       Toggle focus floating windows

FULLSCREEN
  Alt+F           Toggle fullscreen

LAYOUTS
  Alt+N/P         Next/Previous saved layout

WORKSPACES (decknix)
  glide-workspace   Switch workspace (choose-gui)
  glide-space       Switch to space (choose-gui)
  glide-cheatsheet  Show this help

macOS SPACES
  Ctrl+1-9        Switch to space 1-9 (System)
  Ctrl+Left/Right Previous/Next space (System)
"

        if command -v choose &>/dev/null; then
          echo "$CHEATSHEET" | choose -n 50
        else
          echo "$CHEATSHEET"
        fi
      '')
    ];
  };
}

