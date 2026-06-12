# Configuration for Claude agent (managed via agent-sync).
#
# This module ensures ~/.claude.json and ~/.claude/ are managed via the
# 3-way reconciliation sync, allowing for local edits to skills/commands.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.ai.claude;

  # Helper to register a file for sync if it exists in the source repo
  # Since we don't have these files in Nix yet, this is mostly a placeholder
  # for the user to override or for future framework defaults.
in {
  options.decknix.ai.claude = {
    enable = mkEnableOption "Claude agent configuration";

    settings = mkOption {
      type = types.attrs;
      default = {};
      description = "Declarative settings for ~/.claude.json";
    };
  };

  config = mkIf cfg.enable {
    # If we have settings, generate the file and sync it
    decknix.cli.agentSync.enable = true;
    decknix.cli.agentSync.files = mkIf (cfg.settings != {}) {
      "~/.claude.json" = {
        source = pkgs.writeText "claude-settings.json" (builtins.toJSON cfg.settings);
        repo = "decknix";
        repoPath = "modules/home/options/ai/claude.nix";
      };
    };
  };
}
