{ config, lib, pkgs, inputs, ... }:

with lib;

let
  cfg = config.decknix.wm.hammerspoon;
  spacesCfg = config.decknix.wm.spaces;

  # Parse modifier string to Hammerspoon format
  # "Meta + Ctrl" → {"cmd", "ctrl"}
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
  modifiersShiftLua = ''{"${concatStringsSep ''", "'' modifierList}", "shift"}'';

  # Key codes for spaces 1-16
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

  # Get workspaces from shared spaces config
  workspaceList = lib.sort (a: b: a.startSpace < b.startSpace)
    (lib.mapAttrsToList (id: ws: {
      inherit id;
      inherit (ws) name startSpace spaces;
      key = ws.key or null;
    }) spacesCfg.workspaces);

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
    -- Space Switching
    -- ============================================

    function switchToSpace(spaceNum)
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
    '' else "-- No workspaces defined in decknix.wm.spaces.workspaces"}

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
    -- GUI Pickers (choose-gui via decknix-* scripts)
    -- ============================================

    -- Helper: resolve Nix profile PATH for script execution
    local function nixExec(cmd)
      local home = os.getenv("HOME")
      local path = home .. "/.nix-profile/bin:"
                .. "/run/current-system/sw/bin:"
                .. "/nix/var/nix/profiles/default/bin:"
                .. "/usr/local/bin:/usr/bin:/bin"
      return hs.execute("export PATH=" .. path .. "; " .. cmd, true)
    end

    -- Workspace picker (W = pick workspace, then space within it)
    hs.hotkey.bind(${modifiersLua}, "w", function()
      nixExec("decknix-space --workspace")
    end)

    -- Space picker (G = Go to space, all spaces flat)
    hs.hotkey.bind(${modifiersLua}, "g", function()
      nixExec("decknix-space")
    end)

    -- Cheatsheet (? = Help, using / key since ? requires shift)
    hs.hotkey.bind(${modifiersShiftLua}, "/", function()
      nixExec("decknix-cheatsheet --gui")
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
      default = spacesCfg.modifier;
      description = ''
        Modifier key prefix for Hammerspoon keybindings.
        Defaults to decknix.wm.spaces.modifier for consistency.
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

