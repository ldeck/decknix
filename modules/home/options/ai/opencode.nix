# Configuration for the OpenCode agent.
#
# The Emacs agent-shell launches OpenCode over ACP via `opencode acp'
# (upstream agent-shell-opencode.el, registered as the `opencode'
# provider in agent-shell.nix).  This module installs the CLI.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.ai.opencode;
in {
  options.decknix.ai.opencode = {
    enable = mkEnableOption "OpenCode agent configuration";

    settings = mkOption {
      type = types.attrs;
      default = {};
      description = "Declarative settings for ~/.config/opencode/opencode.json";
    };
  };

  config = mkIf cfg.enable {
    # opencode speaks ACP directly via its `acp' subcommand; no adapter.
    home.packages = [ pkgs.opencode ];

    decknix.cli.agentSync.enable = true;
    decknix.cli.agentSync.files = mkIf (cfg.settings != {}) {
      "~/.config/opencode/opencode.json" = {
        source = pkgs.writeText "opencode-settings.json" (builtins.toJSON cfg.settings);
        repo = "decknix";
        repoPath = "modules/home/options/ai/opencode.nix";
      };
    };
  };
}
