{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.wm.spaces;
  hasWorkspaces = cfg.workspaces != { };
  choosePkg = pkgs.choose-gui;

  # Get workspaces sorted by startSpace for consistent ordering
  workspaceList = lib.sort (a: b: a.startSpace < b.startSpace)
    (lib.mapAttrsToList (id: ws: {
      inherit id;
      inherit (ws) name startSpace spaces;
      key = ws.key or null;
    }) cfg.workspaces);

  # Build the space list string used by picker scripts
  spaceListStr = concatStringsSep "\\n" (concatLists (mapAttrsToList (id: ws:
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
  ) cfg.workspaces));

  # Build per-workspace space lists for --workspace filtering
  workspaceNamesStr = concatStringsSep "\\n" (map (ws: ws.name) workspaceList);

  perWorkspaceSpaceLists = concatStringsSep "\n" (map (ws:
    let
      wsInitial = lib.toLower (lib.substring 0 1 ws.name);
      spacesStr = concatStringsSep "\\n" (imap1 (i: spaceName:
        let
          spaceInitial = lib.toLower (lib.substring 0 1 spaceName);
          shortcode = "${wsInitial}${spaceInitial}";
        in
        "${shortcode}  ${ws.name}/${spaceName}:${toString (ws.startSpace + i - 1)}"
      ) ws.spaces);
    in
    "    \"${ws.name}\") SPACES=\"${spacesStr}\" ;;"
  ) workspaceList);

  switchToSpace = ''
    switch_to_space() {
      local SELECTED
      SELECTED=$(echo -e "$1" | ${choosePkg}/bin/choose -z -a -n 30 | grep -oE ':[0-9]+$' | cut -d: -f2)
      if [ -n "$SELECTED" ]; then
        KEY_CODES=(0 18 19 20 21 23 22 26 28 25 29)
        osascript -e "tell application \"System Events\" to key code ''${KEY_CODES[$SELECTED]} using control down"
      fi
    }
  '';

  pickerBody = ''
    ${switchToSpace}

    if [[ "''${1:-}" == "--workspace" || "''${1:-}" == "-w" ]]; then
      # Workspace-first mode: pick workspace, then pick space within it
      WS_NAMES="${workspaceNamesStr}"
      WS=$(echo -e "$WS_NAMES" | ${choosePkg}/bin/choose -z -a -n 30)
      if [ -n "$WS" ]; then
        case "$WS" in
    ${perWorkspaceSpaceLists}
          *) echo "Unknown workspace: $WS"; exit 1 ;;
        esac
        switch_to_space "$SPACES"
      fi
    else
      # Default: show all spaces flat
      SPACES="${spaceListStr}"
      switch_to_space "$SPACES"
    fi
  '';

  noWorkspacesHelp = ''
    echo "No workspaces defined."
    echo "Add to your local/home.nix:"
    echo "  decknix.wm.spaces.workspaces = { ... };"
    echo "Then run: decknix switch"
  '';

  spaceScript = pkgs.writeShellScriptBin "decknix-space"
    (if hasWorkspaces then pickerBody else noWorkspacesHelp);

  mod = cfg.modifier;
  cheatsheetScript = pkgs.writeShellScriptBin "decknix-cheatsheet" ''
    CHEATSHEET="decknix WM Cheatsheet (Modifier: ${mod})
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SPACE NAVIGATION (Hammerspoon)
  ${mod}+1-9,0        Switch to space 1-10
  ${mod}+-/=          Switch to space 11/12
  ${mod}+[/]          Switch to space 13/14
  ${mod}+;/'          Switch to space 15/16
  ${mod}+Left/Right   Previous/Next space
  ${mod}+Up           Mission Control

WORKSPACE SWITCHING
  ${mod}+W            Workspace picker (GUI, pick workspace then space)
  ${mod}+G            Space picker (GUI, all spaces flat)
  ${mod}+Shift+<key>  Switch to workspace (key from config)
  ${mod}+Shift+?      Show this cheatsheet (GUI)

CLI TOOLS
  decknix-space              All spaces flat (choose-gui)
  decknix-space --workspace  Pick workspace first, then space
  decknix-cheatsheet         Show this help
  decknix space              Alias for decknix-space
  decknix cheatsheet         Alias for decknix-cheatsheet
"
    if [[ "$1" == "--gui" ]]; then
      echo "$CHEATSHEET" | ${choosePkg}/bin/choose -n 50
    else
      echo "$CHEATSHEET"
    fi
  '';

in {
  options.decknix.wm.spaces = {
    modifier = mkOption {
      type = types.str;
      default = "Meta + Ctrl";
      description = ''
        Modifier key prefix for WM keybindings (used by Hammerspoon and scripts).
        Format: "Meta + Ctrl" (Meta = Command on macOS).
      '';
    };

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
            description = "Single letter key for quick switching via Hammerspoon.";
          };
          spaces = mkOption {
            type = types.listOf types.str;
            default = [ "primary" ];
            description = "Logical space names within this workspace, mapped to consecutive macOS Spaces.";
          };
          startSpace = mkOption {
            type = types.int;
            default = 1;
            description = "Starting macOS Space number for this workspace.";
          };
        };
      });
      default = { };
      example = {
        work = {
          name = "Work";
          key = "w";
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
        WM-agnostic workspace definitions. A workspace is a logical grouping of
        macOS Spaces. Consumed by Hammerspoon and CLI tools (decknix-space, etc).
      '';
    };
  };

  config = mkIf hasWorkspaces {
    home.packages = [
      spaceScript
      cheatsheetScript
      choosePkg
    ];

    # Register as decknix subcommands: decknix space, decknix cheatsheet
    decknix.cli.extensions = {
      space = {
        description = "Space picker (GUI)";
        command = "${spaceScript}/bin/decknix-space";
      };
      cheatsheet = {
        description = "Show WM keybinding cheatsheet";
        command = "${cheatsheetScript}/bin/decknix-cheatsheet";
      };
    };
  };
}

