{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.emacs.decknix;
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
      description = "The Emacs package to use for the daemon.";
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
      package = cfg.package;
      additionalPath = cfg.additionalPath;
    };

    # Add emacsclient to system packages for easy access
    environment.systemPackages = with pkgs; [
      cfg.package
      # Create a wrapper script for emacsclient
      (writeShellScriptBin "ec" ''
        exec ${cfg.package}/bin/emacsclient -c "$@"
      '')
    ];
  };
}

