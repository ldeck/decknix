# Configuration for the Qwen Code agent.
#
# The Emacs agent-shell launches Qwen over ACP via
# `qwen --experimental-acp' (upstream agent-shell-qwen.el, registered as
# the `qwen-code' provider in agent-shell.nix).  This module installs
# the CLI (package `qwen-code', binary `qwen').

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.ai.qwen;
in {
  options.decknix.ai.qwen = {
    enable = mkEnableOption "Qwen Code agent configuration";

    settings = mkOption {
      type = types.attrs;
      default = {};
      description = "Declarative settings for ~/.qwen/settings.json";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ pkgs.qwen-code ];

    decknix.cli.agentSync.enable = true;
    decknix.cli.agentSync.files = mkIf (cfg.settings != {}) {
      "~/.qwen/settings.json" = {
        source = pkgs.writeText "qwen-settings.json" (builtins.toJSON cfg.settings);
        repo = "decknix";
        repoPath = "modules/home/options/ai/qwen.nix";
      };
    };
  };
}
