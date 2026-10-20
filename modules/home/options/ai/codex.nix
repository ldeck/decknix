# Configuration for the OpenAI Codex agent.
#
# The Emacs agent-shell launches Codex over ACP via the separate
# `codex-acp' bridge (upstream agent-shell-openai.el, registered as the
# `codex' provider in agent-shell.nix).  This module installs both the
# `codex' CLI (for standalone use and `codex login') and the bridge.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.ai.codex;
in {
  options.decknix.ai.codex = {
    enable = mkEnableOption "Codex agent configuration";
  };

  config = mkIf cfg.enable {
    # Both come from the nixpkgs-current pin via the `unstable' overlay in
    # flake.nix: the shared unstable pin predates codex-acp.  The bridge's
    # CODEX_PATH is baked to that same `codex', so the CLI on PATH and the
    # one agent-shell drives never drift apart, and Codex credentials from
    # `codex login' (~/.codex/auth.json) are shared by both.
    home.packages = [ pkgs.unstable.codex pkgs.unstable.codex-acp ];
  };
}
