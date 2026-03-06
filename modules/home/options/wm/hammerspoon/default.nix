{ config, lib, pkgs, inputs, ... }:

with lib;

let
  cfg = config.decknix.wm.hammerspoon;
  glideCfg = config.decknix.wm.glide;

  # Parse the glide modifier to Hammerspoon format
  # GlideWM uses: "Meta + Ctrl" (Meta = Cmd)
  # Hammerspoon uses: {"cmd", "ctrl"}
  parseModifiers = modStr:
    let
      parts = map (s: lib.toLower (lib.strings.trim s)) (lib.splitString "+" modStr);
      toHs = m:
        if m == "meta" then "cmd"
        else if m == "ctrl" then "ctrl"
        else if m == "alt" then "alt"
        else if m == "shift" then "shift"
        else m;
    in map toHs parts;

  modifierList = parseModifiers cfg.modifier;
  modifiersLua = ''{"${concatStringsSep ''", "'' modifierList}"}'';
  # Modifiers + Shift for workspace switching
  modifiersShiftLua = ''{"${concatStringsSep ''", "'' modifierList}", "shift"}'';
  # Modifiers + Alt for resize grow
  modifiersAltLua = ''{"${concatStringsSep ''", "'' modifierList}", "alt"}'';
  # Modifiers + Alt + Shift for resize shrink
  modifiersAltShiftLua = ''{"${concatStringsSep ''", "'' modifierList}", "alt", "shift"}'';

  # Key codes for spaces 1-16
  # These are used with Ctrl+key in macOS, we'll use cfg.modifier+key
  spaceKeys = [
    "1" "2" "3" "4" "5" "6" "7" "8" "9" "0"
    "-" "=" "[" "]" ";" "'"
  ];

  # Generate space switching keybindings
  spaceBindings = concatStringsSep "\n" (imap1 (i: key: ''
    hs.hotkey.bind(${modifiersLua}, "${key}", function()
      switchToSpace(${toString i})
    end)
  '') spaceKeys);

  # Get workspaces from GlideWM config (sorted by startSpace for consistent ordering)
  workspaceList = lib.sort (a: b: a.startSpace < b.startSpace)
    (lib.mapAttrsToList (id: ws: {
      inherit id;
      inherit (ws) name startSpace spaces;
      key = ws.key or null;
    }) glideCfg.workspaces);

  # Filter workspaces that have a key defined
  workspacesWithKeys = lib.filter (ws: ws.key != null) workspaceList;

  # Generate workspace switching keybindings (Modifier + Shift + <key>)
  workspaceBindings = concatStringsSep "\n" (map (ws: ''
    hs.hotkey.bind(${modifiersShiftLua}, "${ws.key}", function()
      switchToSpace(${toString ws.startSpace})
      hs.notify.new({title="Workspace", informativeText="${ws.name}"}):send()
    end)
  '') workspacesWithKeys);

  # Generate init.lua content
  initLua = ''
    -- Hammerspoon configuration - managed by decknix
    -- Modifier: ${cfg.modifier}

    -- ============================================
    -- Space Switching (under GlideWM prefix)
    -- ============================================

    -- Switch to a specific space using Ctrl+number (simulating macOS shortcut)
    function switchToSpace(spaceNum)
      -- Map space numbers to their Ctrl+key equivalents
      local keyMap = {
        [1] = "1", [2] = "2", [3] = "3", [4] = "4", [5] = "5",
        [6] = "6", [7] = "7", [8] = "8", [9] = "9", [10] = "0",
        [11] = "-", [12] = "=", [13] = "[", [14] = "]", [15] = ";", [16] = "'"
      }

      local key = keyMap[spaceNum]
      if key then
        hs.eventtap.keyStroke({"ctrl"}, key, 0)
      end
    end

    -- Bind ${cfg.modifier} + 1-9, 0, -, =, [, ], ;, ' to switch spaces
    ${spaceBindings}

    -- ============================================
    -- Workspace Switching (${cfg.modifier} + Shift + <key>)
    -- ============================================
    ${if workspacesWithKeys != [] then ''
    -- Workspaces with keybindings:
    ${concatStringsSep "\n    " (map (ws: "-- ${lib.toUpper ws.key}: ${ws.name} (starts at space ${toString ws.startSpace})") workspacesWithKeys)}

    ${workspaceBindings}
    '' else if workspaceList != [] then ''
    -- Workspaces defined but no keys assigned:
    ${concatStringsSep "\n    " (map (ws: "-- ${ws.name} (starts at space ${toString ws.startSpace}) - add 'key = \"x\";' to enable shortcut") workspaceList)}
    -- Use ${cfg.modifier}+W to open workspace picker
    '' else "-- No workspaces defined in decknix.wm.glide.workspaces"}

    -- ============================================
    -- Navigation helpers
    -- ============================================

    -- Previous space
    hs.hotkey.bind(${modifiersLua}, "left", function()
      hs.eventtap.keyStroke({"ctrl"}, "left", 0)
    end)

    -- Next space
    hs.hotkey.bind(${modifiersLua}, "right", function()
      hs.eventtap.keyStroke({"ctrl"}, "right", 0)
    end)

    -- Mission Control
    hs.hotkey.bind(${modifiersLua}, "up", function()
      hs.eventtap.keyStroke({"ctrl"}, "up", 0)
    end)

    -- ============================================
    -- Shrink window (give space to neighbor)
    -- GlideWM doesn't have a shrink command, so we:
    -- 1. Focus the neighbor in the specified direction
    -- 2. Grow that neighbor (which shrinks the original)
    -- 3. Focus back to the original window
    -- ============================================

    -- Helper: Execute glide shrink sequence
    -- focusKey: vim key to focus neighbor (h/j/k/l)
    -- growKey: vim key direction to grow the neighbor
    local function shrinkWindow(focusKey, growKey)
      -- Focus neighbor
      hs.eventtap.keyStroke(${modifiersLua}, focusKey, 0)
      -- Small delay to let focus change
      hs.timer.usleep(50000)  -- 50ms
      -- Grow neighbor (shrinks original)
      hs.eventtap.keyStroke(${modifiersAltLua}, growKey, 0)
      -- Small delay
      hs.timer.usleep(50000)
      -- Focus back (opposite direction)
      local oppositeKey = ({h="l", l="h", j="k", k="j"})[focusKey]
      hs.eventtap.keyStroke(${modifiersLua}, oppositeKey, 0)
    end

    -- Shrink from left (give space to left neighbor)
    hs.hotkey.bind(${modifiersAltShiftLua}, "h", function()
      shrinkWindow("h", "l")  -- focus left, grow right, focus back right
    end)

    -- Shrink from below (give space to bottom neighbor)
    hs.hotkey.bind(${modifiersAltShiftLua}, "j", function()
      shrinkWindow("j", "k")  -- focus down, grow up, focus back up
    end)

    -- Shrink from above (give space to top neighbor)
    hs.hotkey.bind(${modifiersAltShiftLua}, "k", function()
      shrinkWindow("k", "j")  -- focus up, grow down, focus back down
    end)

    -- Shrink from right (give space to right neighbor)
    hs.hotkey.bind(${modifiersAltShiftLua}, "l", function()
      shrinkWindow("l", "h")  -- focus right, grow left, focus back left
    end)

    -- ============================================
    -- GUI Pickers (choose-gui)
    -- ============================================

    -- Helper: resolve Nix profile PATH for script execution
    -- Hammerspoon doesn't inherit the user's shell PATH, so we
    -- prepend the Nix profile bin directories explicitly.
    local function nixExec(cmd)
      local home = os.getenv("HOME")
      local path = home .. "/.nix-profile/bin:"
                .. "/run/current-system/sw/bin:"
                .. "/nix/var/nix/profiles/default/bin:"
                .. "/usr/local/bin:/usr/bin:/bin"
      return hs.execute("export PATH=" .. path .. "; " .. cmd, true)
    end

    -- Workspace picker (W = Workspace)
    hs.hotkey.bind(${modifiersLua}, "w", function()
      nixExec("glide-workspace --gui")
    end)

    -- Space picker (G = Go to space)
    hs.hotkey.bind(${modifiersLua}, "g", function()
      nixExec("glide-space --gui")
    end)

    -- Cheatsheet (? = Help, using / key since ? requires shift)
    hs.hotkey.bind(${modifiersShiftLua}, "/", function()
      nixExec("glide-cheatsheet --gui")
    end)

    ${cfg.extraConfig}

    -- Reload config notification
    hs.notify.new({title="Hammerspoon", informativeText="Config loaded"}):send()
  '';

in {
  options.decknix.wm.hammerspoon = {
    enable = mkEnableOption "Hammerspoon hotkey daemon";

    modifier = mkOption {
      type = types.str;
      default = glideCfg.modifier;
      description = ''
        Modifier key prefix for Hammerspoon keybindings.
        Defaults to the GlideWM modifier for consistency.
        Format: "Meta + Ctrl" (use +, spaces optional)
      '';
    };

    spaceCount = mkOption {
      type = types.int;
      default = 16;
      description = "Number of spaces to create keybindings for (max 16)";
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Additional Lua configuration to include in init.lua";
    };
  };

  config = mkIf cfg.enable {
    # Hammerspoon from nix-casks (macOS app, not in nixpkgs)
    home.packages = [
      inputs.nix-casks.packages.${pkgs.stdenv.hostPlatform.system}.hammerspoon
    ];

    home.file.".hammerspoon/init.lua".text = initLua;
  };
}

