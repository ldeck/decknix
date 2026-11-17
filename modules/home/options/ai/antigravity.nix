# Configuration for the Antigravity agent (Google's Antigravity CLI, `agy').
#
# Antigravity CLI replaced the Gemini CLI for unpaid, Google AI Pro and Ultra
# users (nixpkgs marks gemini-cli for removal with that message).  The Emacs
# agent-shell launches it over ACP via `agy acp', registered as the
# `antigravity' provider in agent-shell.nix.  The CLI is its own ACP server,
# so no separate bridge is installed.
#
# The binary is unfree, so enabling the module also allows it.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.ai.antigravity;
in {
  options.decknix.ai.antigravity = {
    enable = mkEnableOption "Antigravity agent configuration (Antigravity CLI, `agy`)";

    package = mkOption {
      type = types.package;
      default = pkgs.unstable.antigravity-cli;
      defaultText = literalExpression "pkgs.unstable.antigravity-cli";
      description = ''
        The Antigravity CLI package.  It must provide `agy` with the `acp`
        subcommand (1.5 or later) for the agent-shell provider to work.
      '';
    };

    settings = mkOption {
      type = types.attrs;
      default = {};
      example = literalExpression ''{ agentMode = "accept-edits"; notifications = true; }'';
      description = ''
        Declarative settings for ~/.gemini/antigravity-cli/settings.json.
        Antigravity persists only non-default values there, so an empty set
        leaves the file unmanaged.
      '';
    };
  };

  config = mkIf cfg.enable {
    decknix.allowedUnfree = [ "antigravity-cli" ];

    home.packages = [ cfg.package ];

    decknix.cli.agentSync.enable = true;
    decknix.cli.agentSync.files = mkIf (cfg.settings != {}) {
      "~/.gemini/antigravity-cli/settings.json" = {
        source = pkgs.writeText "antigravity-settings.json" (builtins.toJSON cfg.settings);
        repo = "decknix";
        repoPath = "modules/home/options/ai/antigravity.nix";
      };
    };
  };
}
