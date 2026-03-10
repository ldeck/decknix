{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf;

  cfg = config.decknix.cli.auggie;

  auggieScript = pkgs.writeShellScriptBin "auggie" ''
    exec ${pkgs.nodejs}/bin/npx -y @augmentcode/auggie@latest "$@"
  '';

in {
  options.decknix.cli.auggie = {
    enable = mkEnableOption "auggie CLI (Augment Code agent)";
  };

  config = mkIf cfg.enable {
    home.packages = [ auggieScript ];
  };
}

