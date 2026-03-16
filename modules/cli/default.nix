{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.decknix-cli;

  # Type definition for subtasks
  subtaskType = types.submodule {
    options = {
      description = mkOption { type = types.str; };
      command = mkOption { type = types.str; };
      pinned = mkOption { type = types.bool; default = false; };
    };
  };
in {
  options.programs.decknix-cli = {
    enable = mkEnableOption "Decknix CLI";

    subtasks = mkOption {
      type = types.attrsOf subtaskType;
      default = {};
      description = ''
        System-level subtasks to extend the decknix CLI.
        For home-manager level extensions, use decknix.cli.extensions instead.
      '';
      example = {
        cleanup = {
          description = "Garbage collect nix store";
          command = "nix-collect-garbage -d";
          pinned = true;
        };
      };
    };
  };

  config = mkIf cfg.enable {
    # 1. Install the Rust Binary
    environment.systemPackages = [
      pkgs.decknix-cli
    ] ++
    # 2. Handle Pinned Commands (Create standalone binaries)
    (mapAttrsToList (name: task:
      if task.pinned then
        (pkgs.writeShellScriptBin name ''
           exec ${pkgs.decknix-cli}/bin/decknix ${name} "$@"
        '')
      else null
    ) cfg.subtasks);

    # 3. Generate the Runtime Config for the Rust Binary (system-level)
    environment.etc."decknix/extensions.json".text = builtins.toJSON (
      mapAttrs (n: v: { inherit (v) description command; }) cfg.subtasks
    );
  };
}
