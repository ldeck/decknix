{ config, lib, pkgs, inputs, ... }:

with lib;

let
  cfg = config.decknix.wm.glide;

  # Convert a Nix value to TOML format
  # TOML inline tables use { key = "value" } syntax, NOT JSON {"key":"value"}
  toTomlValue = value:
    if isString value then
      ''"${value}"''
    else if isInt value then
      toString value
    else if isBool value then
      boolToString value
    else if isAttrs value then
      # TOML inline table format: { key = "value", key2 = 123 }
      "{ ${concatStringsSep ", " (mapAttrsToList (k: v: "${k} = ${toTomlValue v}") value)} }"
    else if isList value then
      "[ ${concatStringsSep ", " (map toTomlValue value)} ]"
    else
      throw "Unsupported TOML value type: ${typeOf value}";

  # Convert keybindings attrset to TOML-compatible format
  keybindingsToToml = bindings:
    concatStringsSep "\n" (mapAttrsToList (key: value:
      ''"${key}" = ${toTomlValue value}''
    ) bindings);

  # Generate the TOML config content
  generateConfig = ''
    # GlideWM configuration - managed by decknix
    # Override in ~/.local/decknix/<org>/home.nix

    [settings]
    animate = ${boolToString cfg.animate}
    default_disable = ${boolToString cfg.defaultDisable}
    default_keys = ${boolToString cfg.defaultKeys}
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

  # Helper to generate keybindings with configurable modifier
  mkDefaultKeybindings = mod: resizePct: {
    # Exit/control
    "${mod} + Shift + E" = "save_and_exit";
    "${mod} + Z" = "toggle_space_activated";

    # Navigation (vim-style)
    "${mod} + H" = { move_focus = "left"; };
    "${mod} + J" = { move_focus = "down"; };
    "${mod} + K" = { move_focus = "up"; };
    "${mod} + L" = { move_focus = "right"; };

    # Move windows
    "${mod} + Shift + H" = { move_node = "left"; };
    "${mod} + Shift + J" = { move_node = "down"; };
    "${mod} + Shift + K" = { move_node = "up"; };
    "${mod} + Shift + L" = { move_node = "right"; };

    # Resize - grow in direction (requires GlideWM v0.2.7+)
    "${mod} + Alt + H" = { resize = { direction = "left"; percent = resizePct; }; };
    "${mod} + Alt + J" = { resize = { direction = "down"; percent = resizePct; }; };
    "${mod} + Alt + K" = { resize = { direction = "up"; percent = resizePct; }; };
    "${mod} + Alt + L" = { resize = { direction = "right"; percent = resizePct; }; };

    # Resize - shrink in direction (resize opposite edge inward)
    "${mod} + Shift + Alt + H" = { resize = { direction = "right"; percent = resizePct; }; };
    "${mod} + Shift + Alt + J" = { resize = { direction = "up"; percent = resizePct; }; };
    "${mod} + Shift + Alt + K" = { resize = { direction = "down"; percent = resizePct; }; };
    "${mod} + Shift + Alt + L" = { resize = { direction = "left"; percent = resizePct; }; };

    # Tree navigation
    "${mod} + A" = "ascend";
    "${mod} + D" = "descend";

    # Layouts
    "${mod} + N" = "next_layout";
    "${mod} + P" = "prev_layout";

    # Splitting
    "${mod} + Backslash" = { split = "horizontal"; };
    "${mod} + Equal" = { split = "vertical"; };

    # Grouping (tabs/stacks)
    "${mod} + T" = { group = "horizontal"; };
    "${mod} + S" = { group = "vertical"; };
    "${mod} + E" = "ungroup";

    # Floating
    "${mod} + Shift + Space" = "toggle_window_floating";
    "${mod} + Space" = "toggle_focus_floating";

    # Fullscreen
    "${mod} + F" = "toggle_fullscreen";

    # Debug
    "${mod} + Shift + D" = "debug";
  };

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
        - <modifier>+Z toggles tiling management for current space
        - <modifier>+Shift+E saves and exits (for restore on restart)
        - hjkl navigation between windows
        - Works per-space, integrates with Mission Control

        The modifier key defaults to "Cmd + Ctrl" to avoid conflicts with:
        - Alt/Option: Used for extended characters and Emacs M- commands
        - Cmd alone: Used by most macOS applications

        The glide package is installed automatically when this module is enabled.
      '';
    };

    # Modifier key configuration
    modifier = mkOption {
      type = types.str;
      default = "Meta + Ctrl";
      example = "Alt";
      description = ''
        Modifier key prefix for all GlideWM keybindings.

        Common options:
        - "Meta + Ctrl" (default) - Avoids conflicts with Emacs and extended characters
          (Meta = Command key on macOS)
        - "Alt" - GlideWM default, but conflicts with Emacs M- and extended chars
        - "Ctrl + Alt" - Alternative that avoids some conflicts

        Valid modifier names (must be capitalized):
        - Meta (Command/⌘ on macOS)
        - Ctrl (Control)
        - Alt (Option on macOS)
        - Shift
      '';
    };

    # Basic settings
    animate = mkOption {
      type = types.bool;
      default = false;
      description = "Enable window animations.";
    };

    defaultDisable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Disable tiling on each space by default.
        Use <modifier>+Z to enable tiling on a space.
      '';
    };

    defaultKeys = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the default keys of glide.
        When true custom keys are appended to the defaults; key combos can be individually disabled.
        When false, custom key combos are the only set, providing full control.
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

    resizePercent = mkOption {
      type = types.int;
      default = 10;
      description = "Percentage to resize windows by with each keypress.";
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
      # Default is set in config section using mkDefault so modifier option is resolved
      default = {};
      description = ''
        Keybindings for GlideWM. Keys are formatted as "Modifier + Key".
        Values can be strings (command names) or attribute sets (complex commands).

        The default keybindings use the configured `modifier` option.
        Override specific bindings or set to {} and provide your own.

        Example:
        {
          "Cmd + Ctrl + H" = { move_focus = "left"; };
          "Cmd + Ctrl + Shift + E" = "save_and_exit";
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
          key = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "n";
            description = ''
              Single letter key for quick switching via Hammerspoon.
              When set, ${cfg.modifier}+Shift+<key> switches to this workspace.
              Example: key = "n" for Work, key = "p" for Personal.
            '';
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
        work = {
          name = "Work";
          key = "n";
          spaces = [ "primary" "editor" "monitoring" "pipeline" "docs" "messages" "planning" ];
          startSpace = 1;
        };
        personal = {
          name = "Personal";
          key = "p";
          spaces = [ "main" "browser" "notes" ];
          startSpace = 8;
        };
      };
      description = ''
        Workspace definitions. A workspace is a logical grouping of macOS Spaces.
        This enables organizing your 16 macOS spaces into project-based workspaces.

        Each workspace maps its logical space names to consecutive macOS Spaces
        starting from startSpace.

        Set 'key' to a single letter for quick switching via Hammerspoon
        (e.g., key = "n" allows ${cfg.modifier}+Shift+N to switch to that workspace).
      '';
    };
  };

  # Config implementation
  config = mkIf cfg.enable {
    # Set default keybindings using the configured modifier and resize percent
    decknix.wm.glide.keybindings = mkDefault (mkDefaultKeybindings cfg.modifier cfg.resizePercent);

    # Write the glide configuration file
    home.file.".glide.toml".text = generateConfig;

    # Install glide package and helper scripts
    home.packages =
      let
        # Glide package from nix-casks
        glidePackage = inputs.nix-casks.packages.${pkgs.stdenv.hostPlatform.system}.glide;

        # choose-gui package for GUI pickers
        choosePkg = pkgs.choose-gui;

        # Whether workspaces are defined
        hasWorkspaces = cfg.workspaces != { };

        # Workspace navigation scripts (always available, show help if no workspaces defined)
        workspaceScripts = [
          (pkgs.writeShellScriptBin "glide-workspace" (if hasWorkspaces then ''
            #!/usr/bin/env bash
            # Navigate to a workspace/space using shortcode matching
            # Usage: glide-workspace [--gui]
            #   --gui is accepted but ignored (always uses GUI picker)
            #
            # Format: "shortcode  Workspace/Space:spaceNum"
            # Shortcode is first letter of workspace + first letter of space (lowercase)
            # e.g., "ne  Work/editor:2" - type "ne" to match quickly

            # Build list of all spaces across all workspaces with shortcodes
            SPACES="${concatStringsSep "\n" (concatLists (mapAttrsToList (id: ws:
              let
                wsInitial = lib.toLower (lib.substring 0 1 ws.name);
              in
              imap1 (i: spaceName:
                let
                  spaceInitial = lib.toLower (lib.substring 0 1 spaceName);
                  shortcode = "${wsInitial}${spaceInitial}";
                in
                "${shortcode}  ${ws.name}/${spaceName}:${toString (ws.startSpace + i - 1)}"
              ) ws.spaces
            ) cfg.workspaces))}"

            # Use -z to match from beginning, -a to rank early matches higher
            SELECTED=$(echo "$SPACES" | ${choosePkg}/bin/choose -z -a -n 30 | grep -oE ':[0-9]+$' | cut -d: -f2)
            if [ -n "$SELECTED" ]; then
              # macOS virtual key codes for number keys are non-sequential:
              # Key: 1=18, 2=19, 3=20, 4=21, 5=23, 6=22, 7=26, 8=28, 9=25, 0=29
              KEY_CODES=(0 18 19 20 21 23 22 26 28 25 29)
              osascript -e "tell application \"System Events\" to key code ''${KEY_CODES[$SELECTED]} using control down"
            fi
          '' else ''
            #!/usr/bin/env bash
            # No workspaces defined - show help

            HELP_TEXT='No workspaces defined.

To define workspaces, add to your ~/.local/decknix/<org>/home.nix:

  decknix.wm.glide.workspaces = {
    work = {
      name = "Work";
      key = "n";  # Meta+Ctrl+Shift+N to switch here
      spaces = [ "primary" "editor" "monitoring" "pipeline" "docs" "messages" "planning" ];
      startSpace = 1;
    };
    personal = {
      name = "Personal";
      key = "p";  # Meta+Ctrl+Shift+P to switch here
      spaces = [ "main" "browser" "notes" ];
      startSpace = 8;
    };
  };

Then run: decknix switch'

            if [[ "$1" == "--gui" ]]; then
              # Copy to clipboard and show dialog
              echo "$HELP_TEXT" | pbcopy
              # Use osascript with escaped quotes
              ESCAPED_TEXT=$(echo "$HELP_TEXT" | sed 's/"/\\"/g' | sed 's/$/\\n/' | tr -d '\n' | sed 's/\\n$//')
              osascript <<EOF
display dialog "$ESCAPED_TEXT

(Copied to clipboard)" with title "GlideWM: No Workspaces" buttons {"OK"} default button "OK"
EOF
            else
              echo "$HELP_TEXT"
            fi
          ''))

          (pkgs.writeShellScriptBin "glide-space" (if hasWorkspaces then ''
            #!/usr/bin/env bash
            # Navigate to a specific space within current or specified workspace
            # Usage: glide-space [--gui]
            #   --gui is accepted but ignored (always uses GUI picker)
            #
            # Format: "shortcode  Workspace/Space:spaceNum"
            # Shortcode is first letter of workspace + first letter of space (lowercase)
            # e.g., "ne  Work/editor:2" - type "ne" to match quickly

            # Build list of all spaces across all workspaces with shortcodes
            SPACES="${concatStringsSep "\n" (concatLists (mapAttrsToList (id: ws:
              let
                wsInitial = lib.toLower (lib.substring 0 1 ws.name);
              in
              imap1 (i: spaceName:
                let
                  spaceInitial = lib.toLower (lib.substring 0 1 spaceName);
                  shortcode = "${wsInitial}${spaceInitial}";
                in
                "${shortcode}  ${ws.name}/${spaceName}:${toString (ws.startSpace + i - 1)}"
              ) ws.spaces
            ) cfg.workspaces))}"

            # Use -z to match from beginning, -a to rank early matches higher
            SELECTED=$(echo "$SPACES" | ${choosePkg}/bin/choose -z -a -n 30 | grep -oE ':[0-9]+$' | cut -d: -f2)
            if [ -n "$SELECTED" ]; then
              # macOS virtual key codes for number keys are non-sequential:
              # Key: 1=18, 2=19, 3=20, 4=21, 5=23, 6=22, 7=26, 8=28, 9=25, 0=29
              KEY_CODES=(0 18 19 20 21 23 22 26 28 25 29)
              osascript -e "tell application \"System Events\" to key code ''${KEY_CODES[$SELECTED]} using control down"
            fi
          '' else ''
            #!/usr/bin/env bash
            # No workspaces defined - show help

            HELP_TEXT='No workspaces/spaces defined.

To define workspaces with spaces, add to your ~/.local/decknix/<org>/home.nix:

  decknix.wm.glide.workspaces = {
    work = {
      name = "Work";
      key = "n";
      spaces = [ "primary" "editor" "monitoring" "pipeline" "docs" "messages" "planning" ];
      startSpace = 1;
    };
    personal = {
      name = "Personal";
      key = "p";
      spaces = [ "main" "browser" "notes" ];
      startSpace = 8;
    };
  };

Then run: decknix switch'

            if [[ "$1" == "--gui" ]]; then
              # Copy to clipboard and show dialog
              echo "$HELP_TEXT" | pbcopy
              # Use osascript with escaped quotes
              ESCAPED_TEXT=$(echo "$HELP_TEXT" | sed 's/"/\\"/g' | sed 's/$/\\n/' | tr -d '\n' | sed 's/\\n$//')
              osascript <<EOF
display dialog "$ESCAPED_TEXT

(Copied to clipboard)" with title "GlideWM: No Spaces" buttons {"OK"} default button "OK"
EOF
            else
              echo "$HELP_TEXT"
            fi
          ''))
        ];

        # Cheatsheet script with dynamic modifier
        mod = cfg.modifier;
        cheatsheetScript = pkgs.writeShellScriptBin "glide-cheatsheet" ''
          #!/usr/bin/env bash
          # Show GlideWM cheatsheet
          # Usage: glide-cheatsheet [--gui]
          #   --gui  Show in choose picker (scrollable GUI)
          #   (default) Print to terminal

          CHEATSHEET="GlideWM Cheatsheet (Modifier: ${mod})
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

BASICS
  ${mod}+Z           Toggle tiling for current space
  ${mod}+Shift+E     Save layout and exit

NAVIGATION (Vim-style)
  ${mod}+H/J/K/L     Focus left/down/up/right
  ${mod}+A           Ascend (select parent)
  ${mod}+D           Descend (select child)

MOVE WINDOWS
  ${mod}+Shift+H/J/K/L   Move window left/down/up/right

RESIZE
  ${mod}+Alt+H/J/K/L     Resize in direction (5%)

SPLITTING
  ${mod}+\\          Split horizontal
  ${mod}+=           Split vertical

GROUPING (Tabs/Stacks)
  ${mod}+T           Tab group (horizontal)
  ${mod}+S           Stack group (vertical)
  ${mod}+E           Ungroup

FLOATING
  ${mod}+Shift+Space Toggle window floating
  ${mod}+Space       Toggle focus floating windows

FULLSCREEN
  ${mod}+F           Toggle fullscreen

LAYOUTS
  ${mod}+N/P         Next/Previous saved layout

WORKSPACES (decknix CLI)
  glide-workspace   Switch workspace (choose-gui)
  glide-space       Switch to space (choose-gui)
  glide-cheatsheet  Show this help (--gui for picker)

HAMMERSPOON KEYBINDINGS (if enabled)
  Workspaces:
    ${mod}+W          Workspace picker (choose-gui)
    ${mod}+Shift+<key> Switch to workspace (key defined in config)

  Spaces:
    ${mod}+G          Space picker (choose-gui)
    ${mod}+1-9        Switch to space 1-9
    ${mod}+0          Switch to space 10
    ${mod}+-/=        Switch to space 11/12
    ${mod}+[/]        Switch to space 13/14
    ${mod}+;/'        Switch to space 15/16

  Navigation:
    ${mod}+Left/Right Previous/Next space
    ${mod}+Up         Mission Control
    ${mod}+Shift+?    Show this cheatsheet (GUI)

macOS SPACES (System Settings → Keyboard → Shortcuts → Mission Control)
  Ctrl+1-9          Switch to space 1-9
  Ctrl+0            Switch to space 10
  Ctrl+- / Ctrl+=   Switch to space 11/12
  Ctrl+[ / Ctrl+]   Switch to space 13/14
  Ctrl+; / Ctrl+'   Switch to space 15/16
  Ctrl+Left/Right   Previous/Next space
  Ctrl+Up           Mission Control
  F11               Show Desktop
"

          if [[ "$1" == "--gui" ]]; then
            echo "$CHEATSHEET" | ${choosePkg}/bin/choose -n 50
          else
            echo "$CHEATSHEET"
          fi
        '';

      in [ glidePackage cheatsheetScript ] ++ workspaceScripts;
  };
}
