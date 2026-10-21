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

  # Scoped to Pi rather than set in the session: GOOGLE_CLOUD_PROJECT is the
  # default project for every Google SDK and Terraform provider, so exporting
  # it globally to reach Vertex from Pi would silently retarget them too.
  # --set-default keeps a value already in the environment winning.
  piPackage =
    if cfg.env == {} then pkgs.unstable.pi-coding-agent
    else pkgs.symlinkJoin {
      name = "pi-coding-agent-${pkgs.unstable.pi-coding-agent.version}-env";
      paths = [ pkgs.unstable.pi-coding-agent ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/pi ${concatStringsSep " "
          (mapAttrsToList (n: v: "--set-default ${n} ${escapeShellArg v}") cfg.env)}
      '';
    };
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

    env = mkOption {
      type = types.attrsOf types.str;
      default = {};
      example = { GOOGLE_CLOUD_PROJECT = "my-project"; GOOGLE_CLOUD_LOCATION = "global"; };
      description = ''
        Environment defaults for the `pi' binary only, e.g. the Vertex AI
        project and location its google-vertex provider requires alongside
        ADC credentials.  pi-acp launches `pi' from PATH, so agent-shell
        sessions get them too.  A value already set in the environment wins.
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
    home.packages = [ piPackage pkgs.pi-acp ];

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
