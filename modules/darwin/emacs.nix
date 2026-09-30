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
  # daemon on config-only `decknix switch`. Post-activation reports when a
  # manual restart is needed rather than hot-reloading a live daemon.
  #
  # The daemon only restarts when this script's content changes (never for
  # Elisp-only changes) or when the Emacs binary package itself changes.
  #
  # We use --fg-daemon='server' (explicit name) instead of bare --fg-daemon
  # because GNU Emacs 30+ only calls server-start automatically when a
  # server name is provided. Without it, the socket is never created.
  emacsLauncher = pkgs.writeShellScript "emacs-daemon-launcher" ''
    EMACS="${homeDir}/.nix-profile/bin/emacs"
    exec "$EMACS" --fg-daemon='server'
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
        # Keep exactly one daemon alive: if it crashes or is killed,
        # launchd restarts it (throttled ~10s).  This is what makes the
        # `ec' wrapper safe to run without `-a ""' (which would otherwise
        # fork an orphaned second daemon outside launchd's control).
        # `decknix switch' restarts are still driven by launchctl
        # kickstart -k / plist reload, which take precedence over KeepAlive.
        KeepAlive = true;
        ProcessType = "Background";
      };
    };

    # Add emacsclient wrapper to system packages
    environment.systemPackages = with pkgs; [
      # Wrapper for emacsclient that connects to the ONE launchd-managed
      # Emacs daemon.  All arguments are passed through to emacsclient.
      #
      # Usage: ec [emacsclient args...]
      #   ec -c -n           - Create new GUI frame
      #   ec -c -n file.txt  - Open file in new GUI frame
      #   ec -t file.txt     - Open in terminal
      #   ec file.txt        - Open file in existing frame
      #
      # Deliberately NOT `emacsclient -a ""': that flag forks a fresh
      # `emacs --daemon' (double-forked, outside launchd) whenever no server
      # is found, producing an orphaned SECOND daemon.  Instead launchd owns
      # the single daemon (label org.nixos.emacs-server, KeepAlive=true) and
      # restarts it if it dies.  If the socket is briefly unavailable (e.g. a
      # restart window), we ask launchd to (re)start ITS daemon and retry --
      # we never spawn our own.
      (writeShellScriptBin "ec" ''
        emacsclient="${emacsPackage}/bin/emacsclient"
        # Side-effect-free reachability probe (never spawns a daemon).
        if ! "$emacsclient" -e t >/dev/null 2>&1; then
          # Daemon not reachable: ask launchd to (re)start ITS daemon, then
          # wait (up to ~5s for the KeepAlive throttle) for the socket.
          /bin/launchctl kickstart "gui/$(${pkgs.coreutils}/bin/id -u)/org.nixos.emacs-server" 2>/dev/null || true
          n=0
          while [ "$n" -lt 20 ] && ! "$emacsclient" -e t >/dev/null 2>&1; do
            n=$((n + 1))
            ${pkgs.coreutils}/bin/sleep 0.25
          done
        fi
        # Run the user's actual command exactly once.
        exec "$emacsclient" "$@"
      '')
    ];

    # Automatic hot reload is unsafe for native-compiled Elisp in a live
    # daemon. Shortly after the 2026-09-30 switch, a timer entered an .eln
    # image and the process aborted; the subsequent launchd restart aborted
    # again in a worktree-cache timer. We cannot prove which part of the
    # switch caused the abort, so do not unload/reload features behind live
    # timers without an explicit user decision.
    # Report the state instead, without destroying active agent sessions.
    # This diagnostic is bounded to five seconds and runs in the user's GUI
    # session so emacsclient finds the correct socket. A CLI status check after
    # activation separately distinguishes binary changes from config changes.
    system.activationScripts.postActivation.text = lib.mkAfter ''
      USER_ID=$(id -u ${username})
      PROBE=$(${pkgs.coreutils}/bin/timeout 5 \
        launchctl asuser "$USER_ID" sudo -u ${username} \
          ${emacsPackage}/bin/emacsclient -e \
            '(if (and (boundp (quote deckmacs--loaded-store-path)) (fboundp (quote deckmacs--resolve-current-default-el))) (if (equal deckmacs--loaded-store-path (deckmacs--store-path-for (deckmacs--resolve-current-default-el))) "current" "changed") "unknown")' \
          2>/dev/null || true)
      case "$PROBE" in
        '"current"') echo "emacs: configuration already loaded; no restart needed" ;;
        '"changed"')
          printf '\033[1;33m⚠️  EMACS CHANGE NOT LOADED: restart the server to apply it.\033[0m\n'
          echo '   launchctl kickstart -k gui/$(id -u)/org.nixos.emacs-server'
          ;;
        *) printf '\033[1;33m⚠️  EMACS STATUS UNKNOWN: daemon did not answer within 5s; check before restarting.\033[0m\n' ;;
      esac
    '';
  };
}

