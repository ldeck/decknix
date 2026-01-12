{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.decknix;

  # Type definition for subtasks
  subtaskType = types.submodule {
    options = {
      description = mkOption { type = types.str; };
      command = mkOption { type = types.str; };
      pinned = mkOption { type = types.bool; default = false; };
    };
  };
in {
  options.programs.decknix = {
    enable = mkEnableOption "Decknix CLI";

    subtasks = mkOption {
      type = types.attrsOf subtaskType;
      default = {};
      description = "Custom subtasks to extend the decknix CLI";
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
      pkgs.decknix-cli # Assuming this is in your overlay
    ] ++
    # 2. Handle Pinned Commands (Create standalone binaries)
    (mapAttrsToList (name: task:
      if task.pinned then
        (pkgs.writeShellScriptBin name ''
           exec ${pkgs.decknix-cli}/bin/decknix ${name} "$@"
        '')
      else null
    ) cfg.subtasks);

    # 3. Generate the Runtime Config for the Rust Binary
    # We write this to /etc (system) or home-manager config path
    environment.etc."decknix/extensions.json".text = builtins.toJSON (
      mapAttrs (n: v: { inherit (v) description command; }) cfg.subtasks
    );

    # NOTE: The Rust binary needs to know where to look.
    # You might patch the binary to look in /etc/decknix/extensions.json
  };
}
