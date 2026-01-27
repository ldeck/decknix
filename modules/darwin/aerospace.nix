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
      default = true;  # Enabled by default for tiling WM experience
      description = ''
        Enable AeroSpace tiling window manager system configuration.
        This configures macOS system settings for optimal AeroSpace usage:
        - Disables Stage Manager (conflicts with tiling)
        - Disables "Displays have separate Spaces" (better multi-monitor)
        - Disables Mission Control shortcuts (Ctrl+Left/Right/1/2/3)
        - Auto-hides Dock (maximize screen real estate)
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

    disableMissionControlShortcuts = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Disable Mission Control keyboard shortcuts that conflict with AeroSpace.
        This includes:
        - Move left/right a space (Ctrl+Left/Right Arrow)
        - Switch to Desktop 1/2/3 (Ctrl+1/2/3)
        AeroSpace provides its own workspace navigation, making these unnecessary.
      '';
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

        ${optionalString cfg.disableMissionControlShortcuts ''
          # Disable Mission Control keyboard shortcuts that conflict with AeroSpace
          # These are stored in com.apple.symbolichotkeys AppleSymbolicHotKeys
          # Key IDs:
          #   79, 80 = Move left a space (Ctrl+Left Arrow)
          #   81, 82 = Move right a space (Ctrl+Right Arrow)
          #   118 = Switch to Desktop 1 (Ctrl+1)
          #   119 = Switch to Desktop 2 (Ctrl+2)
          #   120 = Switch to Desktop 3 (Ctrl+3)

          # Move left a space (Ctrl+Left Arrow) - disable
          defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 79 "
            <dict>
              <key>enabled</key><false/>
              <key>value</key><dict>
                <key>type</key><string>standard</string>
                <key>parameters</key>
                <array>
                  <integer>65535</integer>
                  <integer>123</integer>
                  <integer>8650752</integer>
                </array>
              </dict>
            </dict>
          "
          defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 80 "
            <dict>
              <key>enabled</key><false/>
              <key>value</key><dict>
                <key>type</key><string>standard</string>
                <key>parameters</key>
                <array>
                  <integer>65535</integer>
                  <integer>123</integer>
                  <integer>8781824</integer>
                </array>
              </dict>
            </dict>
          "

          # Move right a space (Ctrl+Right Arrow) - disable
          defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 81 "
            <dict>
              <key>enabled</key><false/>
              <key>value</key><dict>
                <key>type</key><string>standard</string>
                <key>parameters</key>
                <array>
                  <integer>65535</integer>
                  <integer>124</integer>
                  <integer>8650752</integer>
                </array>
              </dict>
            </dict>
          "
          defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 82 "
            <dict>
              <key>enabled</key><false/>
              <key>value</key><dict>
                <key>type</key><string>standard</string>
                <key>parameters</key>
                <array>
                  <integer>65535</integer>
                  <integer>124</integer>
                  <integer>8781824</integer>
                </array>
              </dict>
            </dict>
          "

          # Switch to Desktop 1/2/3 (Ctrl+1/2/3) - disable
          defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 118 "
            <dict>
              <key>enabled</key><false/>
              <key>value</key><dict>
                <key>type</key><string>standard</string>
                <key>parameters</key>
                <array>
                  <integer>65535</integer>
                  <integer>18</integer>
                  <integer>262144</integer>
                </array>
              </dict>
            </dict>
          "
          defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 119 "
            <dict>
              <key>enabled</key><false/>
              <key>value</key><dict>
                <key>type</key><string>standard</string>
                <key>parameters</key>
                <array>
                  <integer>65535</integer>
                  <integer>19</integer>
                  <integer>262144</integer>
                </array>
              </dict>
            </dict>
          "
          defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 120 "
            <dict>
              <key>enabled</key><false/>
              <key>value</key><dict>
                <key>type</key><string>standard</string>
                <key>parameters</key>
                <array>
                  <integer>65535</integer>
                  <integer>20</integer>
                  <integer>262144</integer>
                </array>
              </dict>
            </dict>
          "

          echo "  ✓ Mission Control shortcuts disabled (Ctrl+Left/Right/1/2/3)"
          echo "    Note: You may need to log out and back in for these to take effect"
        ''}

        # Ensure window animations are enabled (AeroSpace works with macOS animations)
        defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool true

        echo "AeroSpace system configuration complete."
      '';
    };
  };
}

