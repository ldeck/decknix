{ config, lib, pkgs, ... }:

with lib;

let
  # Use decknix namespace to avoid conflict with upstream nix-darwin aerospace module
  cfg = config.decknix.services.aerospace;
in
{
  options.decknix.services.aerospace = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable AeroSpace tiling window manager system configuration.
        This configures macOS system settings for optimal AeroSpace usage.
      '';
    };

    disableStageManager = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Disable Stage Manager. AeroSpace and Stage Manager do not work well together.
        Stage Manager interferes with window management and can cause unexpected behavior.
      '';
    };

    disableSeparateSpaces = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Disable "Displays have separate Spaces" for multi-monitor setups.
        When enabled, moving windows between monitors can cause issues with
        AeroSpace's virtual workspace system. Requires logout to take effect.
      '';
    };

    autoHideDock = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Auto-hide the Dock to maximize screen real estate for tiling.
      '';
    };

    dockSize = mkOption {
      type = types.int;
      default = 48;
      description = "Dock icon size in pixels (relevant when dock is shown).";
    };
  };

  config = mkIf cfg.enable {
    # System defaults for optimal tiling window management
    # All values use mkDefault so they can be easily overridden in user config
    system.defaults = {
      # Dock settings for tiling-friendly layout
      dock = {
        autohide = mkDefault cfg.autoHideDock;
        tilesize = mkDefault cfg.dockSize;
        # Minimize distractions
        show-recents = mkDefault false;
        # Faster animations
        autohide-delay = mkDefault 0.0;
        autohide-time-modifier = mkDefault 0.2;
      };

      # Window manager settings
      WindowManager = mkIf cfg.disableStageManager {
        # Disable Stage Manager (GloballyEnabled controls the feature)
        GloballyEnabled = mkDefault false;
        # Disable "click wallpaper to reveal desktop"
        EnableStandardClickToShowDesktop = mkDefault false;
      };

      # Mission Control / Spaces settings
      spaces = mkIf cfg.disableSeparateSpaces {
        # Disable "Displays have separate Spaces"
        # This makes multi-monitor work better with AeroSpace
        spans-displays = mkDefault true;
      };
    };

    # Activation script for settings that can't be set via system.defaults
    system.activationScripts.aerospace = {
      text = ''
        echo "Configuring macOS for AeroSpace tiling window manager..."

        ${optionalString cfg.disableStageManager ''
          # Disable Stage Manager via defaults (belt and suspenders)
          defaults write com.apple.WindowManager GloballyEnabled -bool false
          defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool false
          echo "  ✓ Stage Manager disabled"
        ''}

        ${optionalString cfg.disableSeparateSpaces ''
          # Disable "Displays have separate Spaces"
          # Note: Requires logout to take effect
          defaults write com.apple.spaces spans-displays -bool true
          echo "  ✓ Displays separate Spaces disabled (logout required for effect)"
        ''}

        # Ensure window animations are enabled (AeroSpace works with macOS animations)
        defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool true

        echo "AeroSpace system configuration complete."
      '';
    };
  };
}

