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
  inherit (lib) mkEnableOption mkIf mkOption types optionalAttrs mapAttrs'
    nameValuePair;

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
        example = "opus4.7";
        description = ''
          Default model for new auggie sessions. Written to the
          `model` key of `~/.augment/settings.json`; auggie uses
          this when no `--model` flag is supplied on the command
          line. Run `auggie model list` to see available ids
          (e.g. `opus4.7`, `sonnet4.6`).

          Per-session overrides (set via `C-c C-v` inside an
          agent-shell buffer) are persisted separately in
          `~/.config/decknix/agent-sessions.json` and take
          precedence on session resume.
        '';
      };

      indexingAllowDirs = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "/Users/me/Code/my-project" "/Users/me/tools/decknix" ];
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

        Note: Slack MCP workspaces declared via `slack.workspaces` are
        automatically merged into this option as "slack-<name>" entries.
      '';
    };

    slack.workspaces = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          clientId = mkOption {
            type = types.str;
            description = ''
              Slack app CLIENT_ID for OAuth authentication to this workspace.
              Each MCP client needs a registered Slack app; the CLIENT_ID
              comes from the app's OAuth configuration.
            '';
          };
          description = mkOption {
            type = types.str;
            default = "";
            description = "Human-readable description of this Slack workspace.";
          };
        };
      });
      default = {};
      example = {
        personal = { clientId = "3660753192626.123456"; };
        acme-corp = {
          clientId = "3660753192626.789012";
          description = "ACME Corp team workspace";
        };
      };
      description = ''
        Slack workspaces to connect via the Slack MCP server.
        Each entry generates a "slack-<name>" MCP server pointing at
        https://mcp.slack.com/mcp with the workspace's CLIENT_ID.

        Downstream configs (org or personal) simply add entries:
          decknix.cli.auggie.slack.workspaces.my-team.clientId = "...";
      '';
    };
  };

  config = mkIf cfg.enable {
    # Generate mcpServers entries from declared Slack workspaces
    decknix.cli.auggie.mcpServers = mapAttrs'
      (name: ws: nameValuePair "slack-${name}" {
        url = "https://mcp.slack.com/mcp";
        auth = { CLIENT_ID = ws.clientId; };
      })
      cfg.slack.workspaces;

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

