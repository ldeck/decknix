{ config, lib, pkgs, inputs, ... }:

with lib;

let
  cfg = config.decknix.apps.ungoogledChromium;
in {
  options.decknix.apps.ungoogledChromium = {
    enable = mkOption {
      type = types.bool;
      default = pkgs.stdenv.isDarwin && config.decknix.adoption.components.apps.enable;
      defaultText = literalExpression
        "pkgs.stdenv.isDarwin && config.decknix.adoption.components.apps.enable";
      description = ''
        Install Ungoogled Chromium, the macOS app from nix-casks.  On by
        default on macOS from tier 3 (the `apps` component); set false to
        skip it.
      '';
    };
  };

  # nix-casks only packages macOS apps, so the default is off elsewhere.
  config = mkIf (cfg.enable && pkgs.stdenv.isDarwin) {
    home.packages = [
      inputs.nix-casks.packages.${pkgs.stdenv.hostPlatform.system}.ungoogled-chromium
    ];
  };
}
