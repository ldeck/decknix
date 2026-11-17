# Configuration for the Gemini agent (Google gemini-cli).  DEPRECATED.
#
# Google replaced the Gemini CLI with the Antigravity CLI for unpaid, Google
# AI Pro and Ultra users; nixpkgs marks gemini-cli for removal saying so.
# Use `decknix.ai.antigravity' instead.  This module stays, off by default,
# for paid API-key and enterprise users that the change did not cut off.
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
    enable = mkEnableOption "Gemini agent configuration (deprecated: use `decknix.ai.antigravity`)";

    settings = mkOption {
      type = types.attrs;
      default = {};
      description = "Declarative settings for ~/.gemini/settings.json";
    };
  };

  config = mkIf cfg.enable {
    warnings = [
      ''
        decknix.ai.gemini is deprecated: Google replaced the Gemini CLI with
        the Antigravity CLI for unpaid, Google AI Pro and Ultra users.  Set
        `decknix.ai.antigravity.enable = true;` and drop
        `decknix.ai.gemini.enable` (keep it only for a paid Gemini API key or
        an enterprise licence).
      ''
    ];

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
