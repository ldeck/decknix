{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.wm.aerospace;
  prefix = cfg.prefixKey;

  # Navigation keys based on style
  navKeys = if cfg.keyStyle == "emacs" then {
    left = "left";    # arrow key
    right = "right";  # arrow key
    up = "up";        # arrow key
    down = "down";    # arrow key
    style = "arrows";
  } else {
    left = "h";
    right = "l";
    up = "k";
    down = "j";
    style = "h/j/k/l";
  };

  # Sort workspace keys for consistent ordering
  sortedWorkspaceKeys = sort lessThan (attrNames cfg.workspaces);

  # Build workspace bindings for aerospace mode (single key to switch)
  workspaceBindings = concatMapStringsSep "\n" (key:
    "    ${toLower key} = ['workspace ${key}', 'mode main']"
  ) sortedWorkspaceKeys;

  # Build move-to-workspace bindings (shift-<key> to move window)
  moveBindings = concatMapStringsSep "\n" (key:
    "    shift-${toLower key} = ['move-node-to-workspace ${key}', 'mode main']"
  ) sortedWorkspaceKeys;

  # Build persistent workspaces list for TOML
  persistentList = concatMapStringsSep ", " (k: "\"${k}\"") sortedWorkspaceKeys;

  # Build app assignment rules
  appRules = concatMapStringsSep "\n" (rule: ''
    [[on-window-detected]]
        if.app-id = '${rule.appId}'
        run = 'move-node-to-workspace ${rule.workspace}'
  '') cfg.appAssignments;

  # Build monitor assignments from workspaces with monitor set
  monitorAssignments = filterAttrs (k: v: v.monitor != null)
    (mapAttrs (k: v: { inherit (v) monitor; }) cfg.workspaces);

  monitorConfig = optionalString (monitorAssignments != {}) ''
    [workspace-to-monitor-force-assignment]
    ${concatStringsSep "\n" (mapAttrsToList (k: v: "    ${k} = '${v.monitor}'") monitorAssignments)}
  '';

  # Script to show notification when entering a mode
  # Takes mode name as argument: "aerospace" or "layout"
  layoutModeNotify = pkgs.writeShellScriptBin "aero-layout-notify" ''
    case "$1" in
      aerospace)
        osascript -e 'display notification "1-5/d/e/m/n/s=workspace  arrows=nav  space=picker  ;=layout  esc=cancel" with title "AeroSpace Mode (${prefix})"'
        ;;
      layout)
        osascript -e 'display notification "h=horiz v=vert t=tile a=accordion f=float space=full b=balance esc=exit" with title "Layout Mode"'
        ;;
    esac
  '';

  # Fuzzy layout picker script - for discoverability
  # Shows layout options in choose-gui with key hints
  layoutPickerScript = pkgs.writeShellScriptBin "aero-pick-layout" ''
    #!/usr/bin/env bash
    # Fuzzy layout picker for AeroSpace
    # Priority given to single-character keys for quick selection

    CHOOSE="${chooseBin}"

    layouts=(
      "h — Horizontal tiles"
      "v — Vertical tiles"
      "t — Tiles (auto)"
      "a — Accordion"
      "b — Balance sizes"
      "f — Float/Tile toggle"
      "space — Fullscreen"
      "← — Join left"
      "→ — Join right"
      "↑ — Join up"
      "↓ — Join down"
      "- — Shrink"
      "= — Grow"
    )

    if [ -x "$CHOOSE" ]; then
      selected=$(printf '%s\n' "''${layouts[@]}" | "$CHOOSE" -n 15 -c 00bfff -b 1a1a2e)
    else
      # Fallback to osascript
      options=$(printf '%s\n' "''${layouts[@]}" | tr '\n' ',' | sed 's/,$//')
      selected=$(osascript -e "
        set layoutList to {$options}
        set chosen to choose from list layoutList with title \"AeroSpace Layout\" with prompt \"Select layout:\" default items {item 1 of layoutList}
        if chosen is false then return \"\"
        return item 1 of chosen
      ")
    fi

    if [ -n "$selected" ]; then
      key=$(echo "$selected" | cut -d' ' -f1)
      case "$key" in
        h) aerospace layout tiles horizontal ;;
        v) aerospace layout tiles vertical ;;
        t) aerospace layout tiles horizontal vertical ;;
        a) aerospace layout accordion horizontal vertical ;;
        b) aerospace balance-sizes ;;
        f) aerospace layout floating tiling ;;
        space) aerospace fullscreen ;;
        "←") aerospace join-with left ;;
        "→") aerospace join-with right ;;
        "↑") aerospace join-with up ;;
        "↓") aerospace join-with down ;;
        "-") aerospace resize smart -50 ;;
        "=") aerospace resize smart +50 ;;
      esac
    fi
  '';

  # Layout mode bindings
  layoutModeConfig = ''
    # Layout mode for rapid layout adjustments
    [mode.layout.binding]
        esc = 'mode main'
        # Orientation
        h = ['layout tiles horizontal', 'mode main']
        v = ['layout tiles vertical', 'mode main']
        # Layout type
        t = ['layout tiles horizontal vertical', 'mode main']
        a = ['layout accordion horizontal vertical', 'mode main']
        # Floating/tiling toggle
        f = ['layout floating tiling', 'mode main']
        # Fullscreen
        space = ['fullscreen', 'mode main']
        # Join with neighbors (arrow keys)
        left = ['join-with left', 'mode main']
        down = ['join-with down', 'mode main']
        up = ['join-with up', 'mode main']
        right = ['join-with right', 'mode main']
        # Resize (stay in mode for continuous resize)
        minus = 'resize smart -50'
        equal = 'resize smart +50'
        # Balance
        b = ['balance-sizes', 'mode main']
  '';

  # Path to choose binary from choose-gui package
  chooseBin = "${pkgs.choose-gui}/bin/choose";

  # Fuzzy workspace picker script
  # Uses choose-gui (Spotlight-like) with fallback to osascript
  fuzzyPickerScript = pkgs.writeShellScriptBin "aero-pick" ''
    #!/usr/bin/env bash
    # Fuzzy workspace picker for AeroSpace

    CHOOSE="${chooseBin}"

    if [ -x "$CHOOSE" ]; then
      selected=$(printf '%s\n' ${concatMapStringsSep " " (key:
        let ws = cfg.workspaces.${key}; in
        ''"${key} - ${ws.name}"''
      ) sortedWorkspaceKeys} | "$CHOOSE" -n 15 -c 00bfff -b 1a1a2e)
    else
      selected=$(osascript <<'APPLESCRIPT'
set workspaceList to {${concatMapStringsSep ", " (key:
        let ws = cfg.workspaces.${key}; in
        ''"${key} - ${ws.name}"''
      ) sortedWorkspaceKeys}}
set chosen to choose from list workspaceList with title "AeroSpace" with prompt "Switch to workspace:" default items {item 1 of workspaceList}
if chosen is false then return ""
return item 1 of chosen
APPLESCRIPT
      )
    fi

    if [ -n "$selected" ]; then
      ws_key=$(echo "$selected" | cut -d' ' -f1 | tr -d ' ')
      aerospace workspace "$ws_key"
    fi
  '';

  # Fuzzy window picker script - search all windows by app name, title, workspace
  # Format: "window-id | workspace | app-name | window-title"
  windowPickerScript = pkgs.writeShellScriptBin "aero-pick-window" ''
    #!/usr/bin/env bash
    # Fuzzy window picker for AeroSpace
    # Lists all windows across all workspaces for fuzzy selection

    CHOOSE="${chooseBin}"

    # Get all windows with format: id | workspace | app | title
    windows=$(aerospace list-windows --all --format '%{window-id}|%{workspace}|%{app-name}|%{window-title}' 2>/dev/null)

    # Debug: check if we got any output
    if [ -z "$windows" ] || [ "$windows" = "" ]; then
      # Try alternative format
      windows=$(aerospace list-windows --all 2>/dev/null)
      if [ -z "$windows" ]; then
        osascript -e 'display notification "No windows found. Try opening some apps first." with title "AeroSpace"' &
        exit 0
      fi
      # Parse the default format (tab-separated: id app-name window-title)
      display_list=$(echo "$windows" | while read -r line; do
        id=$(echo "$line" | awk '{print $1}')
        app=$(echo "$line" | awk '{print $2}')
        title=$(echo "$line" | cut -f3-)
        if [ -n "$id" ]; then
          echo "$id|$app: $title"
        fi
      done)
    else
      # Format for display: "[workspace] app: title"
      display_list=$(echo "$windows" | while IFS='|' read -r id ws app title; do
        # Truncate long titles
        if [ ''${#title} -gt 60 ]; then
          title="''${title:0:57}..."
        fi
        echo "$id|[$ws] $app: $title"
      done)
    fi

    if [ -z "$display_list" ]; then
      osascript -e 'display notification "No windows to display" with title "AeroSpace"' &
      exit 0
    fi

    if [ -x "$CHOOSE" ]; then
      # Use choose-gui with just the display part (hide the ID)
      selected=$(echo "$display_list" | cut -d'|' -f2 | "$CHOOSE" -n 20 -c 00bfff -b 1a1a2e)
      if [ -n "$selected" ]; then
        # Find the window ID for the selected line
        window_id=$(echo "$display_list" | grep -F "|$selected" | head -1 | cut -d'|' -f1)
      fi
    else
      # Fallback to osascript
      options=$(echo "$display_list" | cut -d'|' -f2 | tr '\n' ',' | sed 's/,$//')
      selected=$(osascript -e "
        set windowList to {$options}
        set chosen to choose from list windowList with title \"AeroSpace\" with prompt \"Switch to window:\"
        if chosen is false then return \"\"
        return item 1 of chosen
      " 2>/dev/null)
      if [ -n "$selected" ]; then
        window_id=$(echo "$display_list" | grep -F "|$selected" | head -1 | cut -d'|' -f1)
      fi
    fi

    # Focus the selected window
    if [ -n "$window_id" ]; then
      aerospace focus --window-id "$window_id"
    fi
  '';

  # App launcher script - open new window for selected app
  # Scans /Applications and ~/Applications for all installed apps
  appLauncherScript = pkgs.writeShellScriptBin "aero-new-window" ''
    #!/usr/bin/env bash
    # App launcher for AeroSpace - open new window for selected app
    # Shows running apps first (marked with •), then all installed apps

    CHOOSE="${chooseBin}"

    # Get running apps from aerospace
    running_apps=$(aerospace list-apps 2>/dev/null | sort -u)

    # Get all installed apps from /Applications and ~/Applications
    installed_apps=$(
      find /Applications ~/Applications /System/Applications \
        -maxdepth 2 -name "*.app" -type d 2>/dev/null | \
      xargs -I{} basename {} .app | \
      sort -u
    )

    # Mark running apps with • prefix, then add non-running apps
    marked_apps=""
    for app in $running_apps; do
      marked_apps="$marked_apps
• $app"
    done

    # Add non-running apps (without marker)
    for app in $installed_apps; do
      if ! echo "$running_apps" | grep -qx "$app"; then
        marked_apps="$marked_apps
$app"
      fi
    done

    # Clean up and sort (running apps first due to • prefix)
    all_apps=$(echo "$marked_apps" | grep -v '^$' | sort)

    if [ -x "$CHOOSE" ]; then
      selected=$(echo "$all_apps" | "$CHOOSE" -n 20 -c 00bfff -b 1a1a2e)
    else
      # Fallback to osascript
      options=$(echo "$all_apps" | tr '\n' ',' | sed 's/,$//')
      selected=$(osascript -e "
        set appList to {$options}
        set chosen to choose from list appList with title \"New Window\" with prompt \"Open new window in:\"
        if chosen is false then return \"\"
        return item 1 of chosen
      " 2>/dev/null)
    fi

    if [ -n "$selected" ]; then
      # Strip the • marker if present
      selected=$(echo "$selected" | sed 's/^• //')

      # Open NEW window in the selected app (not just activate)
      # Each app needs specific handling to create a new window
      case "$selected" in
        Terminal)
          osascript -e 'tell application "Terminal" to do script ""' 2>/dev/null
          ;;
        Finder)
          osascript -e 'tell application "Finder" to make new Finder window' 2>/dev/null
          osascript -e 'tell application "Finder" to activate' 2>/dev/null
          ;;
        Safari)
          osascript -e 'tell application "Safari" to make new document' 2>/dev/null
          osascript -e 'tell application "Safari" to activate' 2>/dev/null
          ;;
        "Google Chrome")
          osascript -e 'tell application "Google Chrome" to make new window' 2>/dev/null
          osascript -e 'tell application "Google Chrome" to activate' 2>/dev/null
          ;;
        Firefox)
          open -na "Firefox" --args -new-window 2>/dev/null
          ;;
        Notes)
          # Notes doesn't support new window via AppleScript well, use Cmd+N simulation
          osascript -e 'tell application "Notes" to activate' 2>/dev/null
          osascript -e 'tell application "System Events" to keystroke "n" using command down' 2>/dev/null
          ;;
        TextEdit)
          osascript -e 'tell application "TextEdit" to make new document' 2>/dev/null
          osascript -e 'tell application "TextEdit" to activate' 2>/dev/null
          ;;
        Preview)
          # Preview needs a file, just activate it
          osascript -e 'tell application "Preview" to activate' 2>/dev/null
          ;;
        Mail)
          osascript -e 'tell application "Mail" to activate' 2>/dev/null
          osascript -e 'tell application "System Events" to keystroke "n" using command down' 2>/dev/null
          ;;
        Messages)
          osascript -e 'tell application "Messages" to activate' 2>/dev/null
          osascript -e 'tell application "System Events" to keystroke "n" using command down' 2>/dev/null
          ;;
        "IntelliJ IDEA"*|"PyCharm"*|"WebStorm"*|"GoLand"*|"CLion"*|"Rider"*|"RubyMine"*|"PhpStorm"*|"DataGrip"*)
          # JetBrains IDEs: activate and use Cmd+Shift+N for new project or just activate
          osascript -e "tell application \"$selected\" to activate" 2>/dev/null
          ;;
        "Visual Studio Code"*|"Code"*)
          # VS Code: open new window
          open -na "Visual Studio Code" --args -n 2>/dev/null || open -na "Code" --args -n 2>/dev/null
          ;;
        Slack|Discord|Spotify|"System Preferences"|"System Settings")
          # Single-window apps: just activate
          osascript -e "tell application \"$selected\" to activate" 2>/dev/null
          ;;
        *)
          # Generic: activate and try Cmd+N for new window/document
          osascript -e "tell application \"$selected\" to activate" 2>/dev/null
          sleep 0.3
          osascript -e 'tell application "System Events" to keystroke "n" using command down' 2>/dev/null
          ;;
      esac
    fi
  '';

  # Cheatsheet script - show all keybindings
  # Uses choose-gui which supports Esc to dismiss
  cheatsheetScript = pkgs.writeShellScriptBin "aero-cheatsheet" ''
    #!/usr/bin/env bash
    # AeroSpace keybinding cheatsheet
    # Shows all available commands in a fuzzy picker
    # Press Esc to dismiss (choose-gui supports this natively)

    CHOOSE="${chooseBin}"

    cheatsheet="=== WORKSPACES ===
1-5         Switch to workspace 1-5
d/e/m/n/s   Switch to decknix/emacs/music/notes/system
shift-<key> Move window to workspace
space       Fuzzy workspace picker
tab         Previous workspace

=== WINDOWS ===
←/→/↑/↓     Navigate windows (stays in mode)
shift-arrows Move window in direction
enter       Toggle fullscreen
f           Toggle float/tile
shift-space Fuzzy window picker (all windows)

=== MONITORS ===
j           Focus previous monitor (cycles)
k           Focus built-in display (laptop)
l           Focus next monitor (cycles)
shift-j/k/l Move window to monitor
ctrl-j/k/l  Move workspace to monitor

=== LAYOUTS ===
;           Layout mode submenu
shift-;     Fuzzy layout picker
/           Toggle tiles layout
,           Toggle accordion layout
h           Horizontal tiles
v           Vertical tiles
b           Balance window sizes

=== APPS ===
o           Open new window (app picker)
?           This cheatsheet

=== EXIT ===
esc         Return to normal mode"

    if [ -x "$CHOOSE" ]; then
      # choose-gui: Esc dismisses the picker natively
      echo "$cheatsheet" | "$CHOOSE" -n 30 -c 00bfff -b 1a1a2e
    else
      osascript -e "display dialog \"$cheatsheet\" with title \"AeroSpace Cheatsheet\" buttons {\"OK\"}" 2>/dev/null
    fi
  '';

  # Main configuration file
  configFile = ''
    # AeroSpace Configuration - Generated by decknix
    # See: https://nikitabobko.github.io/AeroSpace/guide
    #
    # PREFIX KEY: ${prefix}
    #
    # After pressing ${prefix}, you enter AeroSpace mode. Then use:
    #   1-5, d, e, m, n, s   Switch to workspace
    #   shift-<key>          Move window to workspace
    #   ${navKeys.style}              Navigate windows (stays in mode)
    #   shift-${navKeys.style}        Move windows (stays in mode)
    #   space                Fuzzy workspace picker
    #   shift-space          Fuzzy window picker (all windows)
    #   tab                  Previous workspace
    #   enter                Toggle fullscreen
    #   /                    Toggle tiles layout
    #   ,                    Toggle accordion layout
    #   ;                    Layout mode (h/v/t/a/b/f/space)
    #   shift-;              Fuzzy layout picker
    #   o                    Open new window (app picker)
    #   ?                    Show cheatsheet (all keybindings)
    #   j/l                  Focus prev/next monitor (cycles)
    #   k                    Focus built-in display (laptop)
    #   shift-j/k/l          Move window to prev/built-in/next monitor
    #   ctrl-j/k/l           Move workspace to prev/built-in/next monitor
    #   esc                  Cancel (return to main mode)

    # Note: config-version and persistent-workspaces require AeroSpace v0.20+
    # nixpkgs currently has v0.19.x, so we omit these for compatibility
    start-at-login = ${boolToString cfg.startAtLogin}

    # Normalizations for predictable tiling
    enable-normalization-flatten-containers = true
    enable-normalization-opposite-orientation-for-nested-containers = true

    # Layout settings
    accordion-padding = 30
    default-root-container-layout = 'tiles'
    default-root-container-orientation = 'auto'

    # Mouse follows focused monitor (i3 default behavior)
    on-focused-monitor-changed = ['move-mouse monitor-lazy-center']

    [key-mapping]
        preset = 'qwerty'

    # Gaps between windows
    [gaps]
        inner.horizontal = ${toString cfg.gaps.inner}
        inner.vertical = ${toString cfg.gaps.inner}
        outer.left = ${toString cfg.gaps.outer}
        outer.bottom = ${toString cfg.gaps.outer}
        outer.top = ${toString cfg.gaps.outer}
        outer.right = ${toString cfg.gaps.outer}

    ${monitorConfig}

    # App-to-workspace assignments
    ${appRules}

    # Main binding mode - only the prefix key is bound here
    [mode.main.binding]
        ${prefix} = ${if cfg.showModeHints
          then "['exec-and-forget ${layoutModeNotify}/bin/aero-layout-notify aerospace', 'mode aerospace']"
          else "'mode aerospace'"}

    # AeroSpace command mode - entered via prefix key (${prefix})
    # Navigation/resize keys stay in mode for repeated use; other keys exit to main
    [mode.aerospace.binding]
        esc = 'mode main'

    # === Navigation (${navKeys.style}) - stays in mode for repeated navigation ===
        ${navKeys.left} = 'focus left'
        ${navKeys.down} = 'focus down'
        ${navKeys.up} = 'focus up'
        ${navKeys.right} = 'focus right'

    # === Move windows (shift + nav) - stays in mode ===
        shift-${navKeys.left} = 'move left'
        shift-${navKeys.down} = 'move down'
        shift-${navKeys.up} = 'move up'
        shift-${navKeys.right} = 'move right'

    # === Layout quick toggles ===
        slash = ['layout tiles horizontal vertical', 'mode main']
        comma = ['layout accordion horizontal vertical', 'mode main']
        enter = ['fullscreen', 'mode main']
        shift-enter = ['layout floating tiling', 'mode main']

    # === Resize - stays in mode for continuous resize ===
        minus = 'resize smart -50'
        equal = 'resize smart +50'

    # === Workspace switching ===
    ${workspaceBindings}

    # === Move window to workspace ===
    ${moveBindings}

    # === Workspace back-and-forth ===
        tab = ['workspace-back-and-forth', 'mode main']

    # === Fuzzy pickers ===
        space = ['exec-and-forget ${fuzzyPickerScript}/bin/aero-pick', 'mode main']
        shift-space = ['exec-and-forget ${windowPickerScript}/bin/aero-pick-window', 'mode main']
        o = ['exec-and-forget ${appLauncherScript}/bin/aero-new-window', 'mode main']

    # === Help/Cheatsheet ===
        shift-slash = ['exec-and-forget ${cheatsheetScript}/bin/aero-cheatsheet', 'mode main']

    # === Enter layout mode for more options ===
    # semicolon (;) = standard layout mode (for users who know the keys)
    # shift-semicolon = fuzzy layout picker (for discoverability)
        semicolon = ${if cfg.showModeHints
          then "['exec-and-forget ${layoutModeNotify}/bin/aero-layout-notify layout', 'mode layout']"
          else "'mode layout'"}
        shift-semicolon = ['exec-and-forget ${layoutPickerScript}/bin/aero-pick-layout', 'mode main']

    # === Monitor navigation using j/k/l (home row) ===
    # j = previous monitor (cycles), l = next monitor (cycles)
    # k = built-in display (laptop screen) - always available
    # Uses next/prev --wrap-around for reliable cycling regardless of connection order
        j = ['focus-monitor --wrap-around prev', 'mode main']
        k = ['focus-monitor built-in', 'mode main']
        l = ['focus-monitor --wrap-around next', 'mode main']
    # === Move window to monitor ===
        shift-j = ['move-node-to-monitor --wrap-around prev', 'mode main']
        shift-k = ['move-node-to-monitor built-in', 'mode main']
        shift-l = ['move-node-to-monitor --wrap-around next', 'mode main']
    # === Move workspace to monitor ===
        ctrl-j = ['move-workspace-to-monitor --wrap-around prev', 'mode main']
        ctrl-k = ['move-workspace-to-monitor built-in', 'mode main']
        ctrl-l = ['move-workspace-to-monitor --wrap-around next', 'mode main']


    ${layoutModeConfig}

    # Service mode for destructive operations
    [mode.service.binding]
        esc = 'mode main'
        r = ['flatten-workspace-tree', 'mode main']
        backspace = ['close-all-windows-but-current', 'mode main']

    ${cfg.extraConfig}
  '';

in {
  config = mkIf cfg.enable {
    # Write the aerospace config file
    xdg.configFile."aerospace/aerospace.toml".text = configFile;

    # Install AeroSpace and tools
    home.packages = [
      pkgs.aerospace  # The tiling window manager itself
    ] ++ optionals cfg.fuzzyPicker.enable [
      fuzzyPickerScript
      windowPickerScript  # Window picker for cross-workspace window selection
      layoutPickerScript  # Layout picker for discoverability
      appLauncherScript   # App launcher for opening new windows
      cheatsheetScript    # Keybinding cheatsheet (ctrl-; ?)
      pkgs.choose-gui     # Native macOS fuzzy finder (Spotlight-like)
    ];

    # Add helpful shell aliases
    programs.zsh.shellAliases = mkIf config.programs.zsh.enable {
      aero = "aerospace";
      aerols = "aerospace list-workspaces --all";
      aerowin = "aerospace list-windows --all";
      aeropick = mkIf cfg.fuzzyPicker.enable "aero-pick";
      aeropickwin = mkIf cfg.fuzzyPicker.enable "aero-pick-window";
      aeronew = mkIf cfg.fuzzyPicker.enable "aero-new-window";
    };
  };
}

