{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.aerospace;

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
  options.programs.aerospace = {
    enable = mkEnableOption "AeroSpace tiling window manager";

    package = mkOption {
      type = types.package;
      default = pkgs.aerospace or (throw "aerospace package not found - install via homebrew");
      description = "The AeroSpace package to use.";
    };

    # System configuration is handled by the darwin module (services.aerospace)
    # This option just documents the relationship
    systemConfigNote = mkOption {
      type = types.str;
      default = ''
        When aerospace is enabled, you should also enable the darwin module:
        services.aerospace.enable = true;

        This configures:
        - Stage Manager disabled (conflicts with tiling)
        - "Displays have separate Spaces" disabled (multi-monitor fix)
        - Dock auto-hide for more screen space
      '';
      description = "Note about darwin system configuration for AeroSpace.";
      visible = false;
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
          Enable fuzzy workspace picker (requires fzf).
          Bound to alt-space by default.
        '';
      };
      key = mkOption {
        type = types.str;
        default = "alt-space";
        description = "Keybinding for fuzzy workspace picker.";
      };
    };

    layoutMode = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Enable layout mode for rapid layout adjustments.
          Enter with alt-shift-semicolon, exit with esc.
        '';
      };
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

