# Configuration for the Gemini agent (Google gemini-cli).
#
# The Emacs agent-shell launches Gemini over ACP via `gemini --acp'
# (upstream agent-shell-google.el, registered as the `gemini' provider in
# agent-shell.nix).  This module installs the
# `gemini' binary and, optionally, syncs a settings file.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.ai.gemini;
in {
  options.decknix.ai.gemini = {
    enable = mkEnableOption "Gemini agent configuration";

    settings = mkOption {
      type = types.attrs;
      default = {};
      description = "Declarative settings for ~/.gemini/settings.json";
    };
  };

  config = mkIf cfg.enable {
    # The Gemini CLI itself speaks ACP via `--acp'; no separate adapter
    # package is needed (unlike pi-acp / claude-agent-acp).  The unstable
    # attribute is the upstream release bundle on the nixpkgs-current pin
    # (pkgs/gemini-cli), because nixpkgs' source build is stuck at 0.47.0.
    home.packages = [ pkgs.unstable.gemini-cli ];

    # If we have settings, generate the file and sync it.
    decknix.cli.agentSync.enable = true;
    decknix.cli.agentSync.files = mkIf (cfg.settings != {}) {
      "~/.gemini/settings.json" = {
        source = pkgs.writeText "gemini-settings.json" (builtins.toJSON cfg.settings);
        repo = "decknix";
        repoPath = "modules/home/options/ai/gemini.nix";
      };
    };
  };
}
