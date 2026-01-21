{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.emacs.decknix;

  # Get the emacs package from home-manager if available, otherwise use the configured package
  # This ensures the daemon uses the same emacs-with-packages that home-manager builds
  emacsPackage =
    if config.home-manager.users ? ${config.users.primaryUser or "ldeck"}
    then config.home-manager.users.${config.users.primaryUser or "ldeck"}.programs.emacs.finalPackage or cfg.package
    else cfg.package;
in
{
  options.services.emacs.decknix = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Emacs daemon service via nix-darwin.";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.emacs;
      description = "The Emacs package to use for the daemon (fallback if home-manager is not used).";
    };

    additionalPath = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Additional paths to add to the Emacs daemon's PATH.";
      example = [ "/usr/local/bin" ];
    };
  };

  config = mkIf cfg.enable {
    services.emacs = {
      enable = true;
      package = emacsPackage;
      additionalPath = cfg.additionalPath;
    };

    # Add emacsclient to system packages for easy access
    environment.systemPackages = with pkgs; [
      # Create a wrapper script for emacsclient that uses the same package as the daemon
      # Uses -t for terminal mode by default (use -c flag to override for GUI)
      (writeShellScriptBin "ec" ''
        exec ${emacsPackage}/bin/emacsclient -t "$@"
      '')
    ];
  };
}

