{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.services.iap-proxy;
  homeDir = config.users.users.${config.system.primaryUser}.home;

  # Build the package from the provided source
  iap-proxy-pkg = pkgs.callPackage ../../pkgs/iap-proxy/default.nix {
    iap-proxy-src = cfg.src;
  };

  # Per-instance submodule — one IAP proxy per target cloud service.
  # Each becomes its own launchd agent (iap-proxy-<name>) on its own port.
  instanceOpts = { name, ... }: {
    options = {
      port = mkOption {
        type = types.port;
        description = "Port this proxy instance listens on.";
      };

      targetUrl = mkOption {
        type = types.str;
        description = "Base URL of the IAP-protected service this instance proxies.";
      };

      iapClientId = mkOption {
        type = types.str;
        description = "IAP's OAuth 2.0 client ID (the audience for IAP tokens) for this target.";
      };

      autoStart = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether this proxy runs continuously (RunAtLoad + KeepAlive) or is
          activated on demand.

          true  — always-on: started at login and kept alive (e.g. TeamCity CI
                  that you hit throughout the day).
          false — on-demand: the launchd agent is still installed, but stays
                  dormant until you start it explicitly and is not restarted
                  when it exits. Start/stop it with:
                    launchctl kickstart -k gui/$(id -u)/iap-proxy-<name>
                    launchctl kill TERM   gui/$(id -u)/iap-proxy-<name>
                  Use for targets you only reach occasionally (e.g. a production
                  monolith you proxy for a one-off support/migration task).
        '';
      };

      oauthClientId = mkOption {
        type = types.str;
        default = cfg.oauthClientId;
        description = "Google OAuth 2.0 client ID. Defaults to the shared oauthClientId.";
      };

      oauthClientSecret = mkOption {
        type = types.str;
        default = cfg.oauthClientSecret;
        description = "Google OAuth 2.0 client secret. Defaults to the shared oauthClientSecret.";
      };

      tokenStorePath = mkOption {
        type = types.str;
        default = "${homeDir}/.config/iap-proxy/${name}-tokens.json";
        description = "Path to persist this instance's OAuth refresh token.";
      };

      logLevel = mkOption {
        type = types.enum [ "DEBUG" "INFO" "WARNING" "ERROR" "CRITICAL" ];
        default = "INFO";
        description = "Log level for this instance.";
      };

      autoOpenBrowser = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Open the system browser automatically when no valid tokens are
          available on startup (first run or after token expiry).
        '';
      };

      oauthRedirectUri = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "OAuth redirect URI. Defaults to http://localhost:{port}/oauth2callback.";
      };

      teamcityToken = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "TeamCity personal access token (only relevant for a TeamCity target).";
      };
    };
  };
in
{
  options.decknix.services.iap-proxy = {
    enable = mkEnableOption "IAP proxy — local HTTP proxies with Google IAP authentication";

    src = mkOption {
      type = types.path;
      description = ''
        Source tree for the iap-proxy Python package.
        Typically provided as a flake input:
          inputs.iap-proxy-src = {
            url = "github:UpsideRealty/experiment-iap-proxy/feature/token-persistence";
            flake = false;
          };
        Then passed as: decknix.services.iap-proxy.src = inputs.iap-proxy-src;
      '';
    };

    oauthClientId = mkOption {
      type = types.str;
      description = "Shared Google OAuth 2.0 client ID (the desktop app used for the user consent flow). Per-instance overridable.";
    };

    oauthClientSecret = mkOption {
      type = types.str;
      description = "Shared Google OAuth 2.0 client secret. Per-instance overridable.";
    };

    instances = mkOption {
      type = types.attrsOf (types.submodule instanceOpts);
      default = { };
      example = literalExpression ''
        {
          teamcity = {
            port = 58080;
            targetUrl = "https://upside-ci.com.au";
            iapClientId = "90320025603-xxxx.apps.googleusercontent.com";
          };
          raywhite-production = {
            port = 59090;
            targetUrl = "https://monolith.raywhite-production.nurturecloud.io";
            iapClientId = "111064767675-xxxx.apps.googleusercontent.com";
          };
        }
      '';
      description = ''
        Named IAP proxy instances — one per target cloud service. Each runs as
        its own launchd agent (iap-proxy-<name>) on its own port with its own
        persisted token store. Extend by adding another named instance.
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ iap-proxy-pkg ];

    launchd.user.agents = mapAttrs' (name: inst:
      nameValuePair "iap-proxy-${name}" {
        # Mirror the standard Nix-first PATH order so Nix-managed tools
        # are always preferred over system equivalents.
        # macOS open(1) is needed for AUTO_OPEN_BROWSER on first auth.
        path = [
          "${homeDir}/.nix-profile/bin"
          "/run/current-system/sw/bin"
          "/nix/var/nix/profiles/default/bin"
          "/usr/local/bin"
          "/usr/bin"
          "/bin"
          "/usr/sbin"
          "/sbin"
        ];

        serviceConfig = {
          ProgramArguments = [ "${iap-proxy-pkg}/bin/iap-proxy" ];
          # Always-on instances start at login and are kept alive. On-demand
          # instances (autoStart = false) are installed but dormant until
          # started with `launchctl kickstart`, and are not auto-restarted.
          RunAtLoad = inst.autoStart;
          KeepAlive = inst.autoStart;
          ProcessType = "Background";
          # WorkingDirectory must be writable — the proxy creates
          # iap_proxy.log via a relative FileHandler.  Without this,
          # launchd defaults to / which is read-only on macOS.
          WorkingDirectory = "/tmp";
          StandardOutPath = "/tmp/iap-proxy-${name}.log";
          StandardErrorPath = "/tmp/iap-proxy-${name}.log";

          EnvironmentVariables = {
            TARGET_URL = inst.targetUrl;
            PORT = toString inst.port;
            LOG_LEVEL = inst.logLevel;
            OAUTH_CLIENT_ID = inst.oauthClientId;
            OAUTH_CLIENT_SECRET = inst.oauthClientSecret;
            IAP_CLIENT_ID = inst.iapClientId;
            TOKEN_STORE_PATH = inst.tokenStorePath;
            AUTO_OPEN_BROWSER = if inst.autoOpenBrowser then "true" else "false";
          } // optionalAttrs (inst.oauthRedirectUri != null) {
            OAUTH_REDIRECT_URI = inst.oauthRedirectUri;
          } // optionalAttrs (inst.teamcityToken != null) {
            TEAMCITY_TOKEN = inst.teamcityToken;
          };
        };
      }
    ) cfg.instances;
  };
}
