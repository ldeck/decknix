# Auggie CLI wrapper + declarative settings & MCP server configuration.
#
# settings.json is generated from Nix options and *copied* (not symlinked)
# to ~/.augment/settings.json on `decknix switch`. This means:
#   - auggie can write to it at runtime (e.g., `auggie mcp add ...`)
#   - runtime changes are temporary — next switch overwrites with Nix state
#
# To persist a change, add it to the Nix options and switch.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types optionalAttrs;

  cfg = config.decknix.cli.auggie;

  auggieScript = pkgs.writeShellScriptBin "auggie" ''
    exec ${pkgs.nodejs}/bin/npx -y @augmentcode/auggie@latest "$@"
  '';

  # Build the settings.json content from Nix options
  settingsJson = builtins.toJSON (
    (optionalAttrs (cfg.settings.model != null) {
      model = cfg.settings.model;
    })
    // (optionalAttrs (cfg.settings.indexingAllowDirs != []) {
      indexingAllowDirs = cfg.settings.indexingAllowDirs;
    })
    // (optionalAttrs (cfg.mcpServers != {}) {
      mcpServers = cfg.mcpServers;
    })
    // cfg.settings.extraConfig
  );

  # Write the JSON to a file in the Nix store (used by activation script)
  settingsFile = pkgs.writeText "auggie-settings.json" settingsJson;

in {
  options.decknix.cli.auggie = {
    enable = mkEnableOption "auggie CLI (Augment Code agent)";

    settings = {
      model = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "opus4.6";
        description = "Default model for auggie sessions.";
      };

      indexingAllowDirs = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "/Users/me/Code/my-project" "/Users/ldeck/tools/decknix" ];
        description = "Directories auggie is allowed to index without prompting.";
      };

      extraConfig = mkOption {
        type = types.attrs;
        default = {};
        description = ''
          Additional top-level settings to merge into settings.json.
          These are merged last and can override any other setting.
        '';
      };
    };

    mcpServers = mkOption {
      type = types.attrsOf types.attrs;
      default = {};
      example = {
        context7 = {
          type = "stdio";
          command = "npx";
          args = [ "-y" "@upstash/context7-mcp@latest" ];
          env = {};
        };
      };
      description = ''
        MCP (Model Context Protocol) server configurations for auggie.
        Each key is the server name, value is the server config object.
        Generates the "mcpServers" section of ~/.augment/settings.json.
      '';
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ auggieScript ];

    # Copy (not symlink) settings.json on activation so auggie can modify it
    # at runtime. Next `decknix switch` will overwrite with the Nix-managed version.
    home.activation.auggie-settings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      AUGMENT_DIR="$HOME/.augment"
      SETTINGS_FILE="$AUGMENT_DIR/settings.json"

      mkdir -p "$AUGMENT_DIR"
      cp -f "${settingsFile}" "$SETTINGS_FILE"
      chmod 644 "$SETTINGS_FILE"
      echo "  [auggie] Wrote $SETTINGS_FILE ($(wc -c < "$SETTINGS_FILE" | tr -d ' ') bytes)"
    '';
  };
}

