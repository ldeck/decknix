{ config, lib, pkgs, ... }:

with lib;

let
  # Use decknix namespace to avoid conflict with upstream home-manager aerospace module
  cfg = config.decknix.wm.aerospace;

  # Default project workspaces - can be overridden
  # Letters are used for project workspaces (memorable), numbers for utility
  defaultWorkspaces = {
    # Core workspaces (numbers for quick access)
    "1" = { name = "main"; };
    "2" = { name = "web"; };
    "3" = { name = "term"; };
    "4" = { name = "mail"; };
    "5" = { name = "chat"; };
    # Project workspaces (letters for memorable access)
    "D" = { name = "decknix"; };
    "E" = { name = "emacs"; };
    "N" = { name = "notes"; };
    # Utility
    "M" = { name = "music"; };
    "S" = { name = "system"; };
  };

in {
  options.decknix.wm.aerospace = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable AeroSpace tiling window manager (decknix configuration).

        AeroSpace is a tiling WM alternative. Enable it alongside or
        instead of Amethyst. AeroSpace manages its own virtual workspaces
        (separate from macOS Spaces).

        To enable: decknix.wm.aerospace.enable = true;
      '';
    };

    startAtLogin = mkOption {
      type = types.bool;
      default = true;
      description = "Start AeroSpace at login.";
    };

    workspaces = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          name = mkOption {
            type = types.str;
            description = "Human-readable name for the workspace (for display/fuzzy search).";
          };
          monitor = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Monitor pattern to assign this workspace to.
              Patterns: 'main', 'secondary', monitor number (1,2,3), or regex.
            '';
          };
        };
      });
      default = defaultWorkspaces;
      description = "Workspace definitions with names and optional monitor assignments.";
    };

    appAssignments = mkOption {
      type = types.listOf (types.submodule {
        options = {
          appId = mkOption {
            type = types.str;
            description = "Application bundle ID (e.g., 'com.apple.Safari').";
          };
          workspace = mkOption {
            type = types.str;
            description = "Workspace key to assign this app to.";
          };
        };
      });
      default = [];
      example = [
        { appId = "com.apple.Safari"; workspace = "2"; }
        { appId = "org.gnu.Emacs"; workspace = "E"; }
      ];
      description = "Rules to automatically assign apps to workspaces.";
    };

    # Key binding configuration
    prefixKey = mkOption {
      type = types.str;
      default = "ctrl-semicolon";
      description = ''
        Prefix key to enter AeroSpace command mode (like tmux prefix or Emacs C-x).
        After pressing this, use single keys for commands:
          1-5, d, e, m, n, s = switch workspace
          shift-<key> = move window to workspace
          arrows = navigate windows
          shift-arrows = move windows
          space = fuzzy picker
          ; = layout mode
          esc = cancel

        Default: ctrl-; (doesn't conflict with Emacs or macOS)
      '';
    };

    keyStyle = mkOption {
      type = types.enum [ "emacs" "vim" ];
      default = "emacs";
      description = ''
        Navigation key style (used in aerospace mode).
        - "emacs": arrow keys (avoids conflicts with workspace letters)
        - "vim": h/j/k/l (left/down/up/right)
      '';
    };

    gaps = {
      inner = mkOption {
        type = types.int;
        default = 8;
        description = "Gap between windows.";
      };
      outer = mkOption {
        type = types.int;
        default = 8;
        description = "Gap between windows and screen edges.";
      };
    };

    fuzzyPicker = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Enable fuzzy workspace picker (bound to 'space' in aerospace mode).
          Uses choose-gui (Spotlight-like native fuzzy finder).
        '';
      };
    };

    showModeHints = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Show macOS notifications when entering aerospace/layout modes.
        Disabled by default as notifications can be noisy.
        Recommended: Learn the keybindings, then disable.
      '';
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Extra TOML configuration to append.";
    };
  };

  # Config implementation in separate file
  imports = [ ./config.nix ];
}

