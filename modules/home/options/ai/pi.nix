# Configuration for Pi agent (managed via agent-sync).
#
# This module ensures ~/.pi/ is managed via the 3-way reconciliation
# sync, allowing for local edits to skills/commands.  Pi's canonical
# global config lives at ~/.pi/agent/settings.json (verified against
# pi-coding-agent 0.83.0 — it does not read ~/.pi.json at all), so any
# declarative `settings' seed must target that file to have effect.

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
      description = ''
        Declarative seed for Pi's global settings
        (~/.pi/agent/settings.json).  Reconciled 3-way, so Pi's own
        edits (e.g. changing the default model in `pi config') coexist.
        Example: { defaultProvider = "anthropic"; defaultModel = "claude-opus-5"; }.
      '';
    };
  };

  config = mkIf cfg.enable {
    # The `pi' coding agent itself (binary `pi'; the pi-acp bridge shells
    # out to it) plus the ACP bridge that lets agent-shell (Emacs) launch
    # Pi over the Agent Client Protocol.  Managed by Nix; no manual npm
    # install needed.  `pi-coding-agent' is currently only in
    # nixpkgs-unstable, so it comes through the `unstable' overlay. That
    # attribute is sourced from the newer nixpkgs-current pin in flake.nix;
    # the shared unstable pin still carries 0.83.0.
    home.packages = [ pkgs.unstable.pi-coding-agent pkgs.pi-acp ];

    # If we have settings, generate the file and sync it
    decknix.cli.agentSync.enable = true;
    decknix.cli.agentSync.files = mkIf (cfg.settings != {}) {
      "~/.pi/agent/settings.json" = {
        source = pkgs.writeText "pi-settings.json" (builtins.toJSON cfg.settings);
        repo = "decknix";
        repoPath = "modules/home/options/ai/pi.nix";
      };
    };
  };
}
