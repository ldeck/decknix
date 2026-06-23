# Configuration for Pi agent (managed via agent-sync).
#
# This module ensures ~/.pi.json and ~/.pi/ are managed via the
# 3-way reconciliation sync, allowing for local edits to skills/commands.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.ai.pi;
in {
  options.decknix.ai.pi = {
    enable = mkEnableOption "Pi agent configuration";

    settings = mkOption {
      type = types.attrs;
      default = {};
      description = "Declarative settings for ~/.pi.json";
    };
  };

  config = mkIf cfg.enable {
    # If we have settings, generate the file and sync it
    decknix.cli.agentSync.enable = true;
    decknix.cli.agentSync.files = mkIf (cfg.settings != {}) {
      "~/.pi.json" = {
        source = pkgs.writeText "pi-settings.json" (builtins.toJSON cfg.settings);
        repo = "decknix";
        repoPath = "modules/home/options/ai/pi.nix";
      };
    };
  };
}
