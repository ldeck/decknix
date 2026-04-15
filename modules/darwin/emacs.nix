{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.emacs.decknix;

  username = config.system.primaryUser;

  # Get the emacs package from home-manager if available, otherwise use the configured package
  emacsPackage =
    if config.home-manager.users ? ${username}
    then config.home-manager.users.${username}.programs.emacs.finalPackage or cfg.package
    else cfg.package;

  # The Emacs binary to run in daemon mode.
  # Uses bin/emacs (not Emacs.app/Contents/MacOS/Emacs) so macOS does not
  # register it as a GUI application. This prevents the "application quit
  # unexpectedly" dialog when the daemon is restarted during `decknix switch`.
  # Standard GNU Emacs has NS/Cocoa support compiled into the binary itself,
  # so emacsclient -c still creates GUI frames regardless of launch path.
  emacsBinary = "${emacsPackage}/bin/emacs";

  homeDir = config.users.users.${username}.home;

  # Stable launcher script that resolves the emacs binary from the Nix
  # profile at runtime.  Because the script content never references the
  # Nix store directly, it doesn't change when only Elisp config changes.
  # This keeps the launchd plist stable so launchd does NOT restart the
  # daemon on config-only `decknix switch`.  Instead, the post-activation
  # hook sends (deckmacs-reload) to the running daemon via emacsclient.
  #
  # The daemon only restarts when this script's content changes (never for
  # Elisp-only changes) or when the Emacs binary package itself changes.
  emacsLauncher = pkgs.writeShellScript "emacs-daemon-launcher" ''
    EMACS="${homeDir}/.nix-profile/bin/emacs"
    exec "$EMACS" --fg-daemon
  '';
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
    # Uses --fg-daemon (foreground daemon) instead of --daemon so that:
    # - launchd can track the actual process PID (--daemon double-forks,
    #   orphaning the real daemon so launchd loses track of it)
    # - `launchctl kickstart -k` can reliably kill and restart it
    # - `decknix switch` restart detection works correctly
    #
    # ProcessType = "Background" tells macOS this is a background service,
    # suppressing the "application quit unexpectedly" dialog on restart.
    #
    # The daemon runs as a hidden background process (no Dock icon, no Cmd+Tab).
    # GUI frames are created via emacsclient -c and appear in the Dock while open.
    # Closing all frames does not kill the daemon.
    launchd.user.agents.emacs-server = {
      # Use the stable launcher script instead of a direct store path.
      # This prevents launchd from restarting the daemon on config-only
      # changes — the launcher resolves emacs from ~/.nix-profile at runtime.
      command = "${emacsLauncher}";

      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = false;
        ProcessType = "Background";
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

    # After activation, signal the running Emacs daemon to hot-reload its
    # config instead of waiting for a manual C-c D r.  If the daemon was
    # restarted by launchd (binary change), this is a harmless no-op since
    # the daemon already loaded the fresh config.  If the daemon is still
    # running (config-only change), this picks up the new default.el.
    system.activationScripts.postActivation.text = lib.mkAfter ''
      if ${emacsPackage}/bin/emacsclient -e '(fboundp (quote deckmacs-reload))' 2>/dev/null | grep -q t; then
        ${emacsPackage}/bin/emacsclient -e '(deckmacs-reload)' 2>/dev/null && \
          echo "emacs: config hot-reloaded (deckmacs-reload)" || true
      fi
    '';
  };
}

