{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.emacs.decknix;

  # Get the emacs package from home-manager if available, otherwise use the configured package
  emacsPackage =
    if config.home-manager.users ? ${config.users.primaryUser or "ldeck"}
    then config.home-manager.users.${config.users.primaryUser or "ldeck"}.programs.emacs.finalPackage or cfg.package
    else cfg.package;

  # Get the Emacs.app path from the package (for GUI frames)
  emacsApp = "${emacsPackage}/Applications/Emacs.app";

  # The Emacs binary to run in daemon mode
  emacsBinary = "${emacsApp}/Contents/MacOS/Emacs";
in
{
  options.services.emacs.decknix = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Emacs integration (server + ec wrapper).";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.emacs;
      description = "The Emacs package to use (fallback if home-manager is not used).";
    };

    additionalPath = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Additional paths to add to the Emacs environment.";
      example = [ "/usr/local/bin" ];
    };
  };

  config = mkIf cfg.enable {
    # Create a launchd agent that starts Emacs in daemon mode at login.
    #
    # Standard GNU Emacs daemon mode:
    # - Runs as a hidden background process (no Dock icon, no Cmd+Tab)
    # - Creates GUI frames via emacsclient -c (frames appear in Dock while open)
    # - Frames can be closed without killing the daemon
    # - Daemon persists invisibly until explicitly killed
    launchd.user.agents.emacs-server = {
      command = "${emacsBinary} --daemon";

      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = false;
      };
    };

    # Add emacsclient wrapper to system packages
    environment.systemPackages = with pkgs; [
      # Simple wrapper for emacsclient that auto-starts daemon if not running.
      # All arguments are passed through to emacsclient.
      #
      # Usage: ec [emacsclient args...]
      #   ec -c -n           - Create new GUI frame
      #   ec -c -n file.txt  - Open file in new GUI frame
      #   ec -t file.txt     - Open in terminal
      #   ec file.txt        - Open file in existing frame
      #
      # The -a "" flag auto-starts the daemon if not running.
      (writeShellScriptBin "ec" ''
        exec ${emacsPackage}/bin/emacsclient -a "" "$@"
      '')
    ];
  };
}

