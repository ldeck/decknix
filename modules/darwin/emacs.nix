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

    # After activation, signal the running Emacs daemon to hot-reload its
    # config instead of waiting for a manual C-c D r.  If the daemon was
    # restarted by launchd (binary change), this is a harmless no-op since
    # the daemon already loaded the fresh config.  If the daemon is still
    # running (config-only change), this picks up the new default.el.
    #
    # We run this as the primary user via `launchctl asuser` to ensure
    # emacsclient finds the user's session-specific socket (usually under
    # /var/folders/.../T/emacs501/server).
    #
    # Two hard rules so activation can never hang:
    #
    #   1. The reload is scheduled via `run-with-idle-timer` so the eval
    #      returns instantly (it only enqueues the work).  Without the
    #      defer, `emacsclient -e` blocks until `deckmacs-reload` finishes
    #      — and if the reload triggers any interactive prompt on a visible
    #      frame (yes-or-no-p, debugger, etc.), `darwin-rebuild` hangs
    #      indefinitely waiting for the user to answer that prompt.  The
    #      deferred reload runs on the daemon's own timeline; any prompt
    #      it raises is the user's concern, not the activation script's.
    #
    #   2. Every `emacsclient` invocation is wrapped in `timeout 5`.  If
    #      the daemon's main thread is busy or wedged (so it can't even
    #      accept the schedule request), the activation script moves on
    #      after 5 s instead of blocking the entire switch.
    system.activationScripts.postActivation.text = lib.mkAfter ''
      USER_ID=$(id -u ${username})

      PROBE=$(${pkgs.coreutils}/bin/timeout 5 \
        launchctl asuser "$USER_ID" sudo -u ${username} \
          ${emacsPackage}/bin/emacsclient -e '(fboundp (quote deckmacs-reload))' \
          2>/dev/null || true)

      if echo "$PROBE" | grep -q t; then
        if ${pkgs.coreutils}/bin/timeout 5 \
             launchctl asuser "$USER_ID" sudo -u ${username} \
               ${emacsPackage}/bin/emacsclient -e '(run-with-idle-timer 0 nil (lambda () (condition-case err (deckmacs-reload) (error (message "deckmacs-reload (deferred): %s" (error-message-string err))))))' \
               >/dev/null 2>&1; then
          echo "emacs: scheduled deckmacs-reload on idle timer"
        else
          echo "emacs: skipped deckmacs-reload (daemon unresponsive within 5s)"
        fi
      fi
    '';
  };
}

