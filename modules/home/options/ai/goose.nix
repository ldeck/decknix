# Configuration for the Goose agent (Block's goose-cli).
#
# The Emacs agent-shell launches Goose over ACP via `goose acp'
# (upstream agent-shell-goose.el, registered as the `goose' provider in
# agent-shell.nix).  This module installs the CLI (binary: `goose').
#
# Goose is also the recommended host for local Ollama models: configure
# a goose provider pointed at http://localhost:11434 (Ollama's server).

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.ai.goose;
in {
  options.decknix.ai.goose = {
    enable = mkEnableOption "Goose agent configuration";

    settings = mkOption {
      type = types.attrs;
      default = {};
      description = "Declarative settings for ~/.config/goose/config.yaml (as JSON).";
    };
  };

  config = mkIf cfg.enable {
    # goose-cli provides the `goose' binary and speaks ACP via `goose acp'.
    home.packages = [ pkgs.goose-cli ];

    decknix.cli.agentSync.enable = true;
    decknix.cli.agentSync.files = mkIf (cfg.settings != {}) {
      "~/.config/goose/config.yaml" = {
        source = pkgs.writeText "goose-config.json" (builtins.toJSON cfg.settings);
        repo = "decknix";
        repoPath = "modules/home/options/ai/goose.nix";
      };
    };
  };
}
