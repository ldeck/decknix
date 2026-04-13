{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.services.iap-proxy;
  homeDir = config.users.users.${config.system.primaryUser}.home;

  # Build the package from the provided source
  iap-proxy-pkg = pkgs.callPackage ../../pkgs/iap-proxy/default.nix {
    iap-proxy-src = cfg.src;
  };

  tokenStorePath = cfg.tokenStorePath;
in
{
  options.decknix.services.iap-proxy = {
    enable = mkEnableOption "IAP proxy — local HTTP proxy with Google IAP authentication";

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

    port = mkOption {
      type = types.port;
      default = 8080;
      description = "Port the proxy listens on.";
    };

    targetUrl = mkOption {
      type = types.str;
      default = "https://upside-ci.com.au";
      description = "Base URL of the IAP-protected service to proxy.";
    };

    logLevel = mkOption {
      type = types.enum [ "DEBUG" "INFO" "WARNING" "ERROR" "CRITICAL" ];
      default = "INFO";
      description = "Log level for the proxy.";
    };

    tokenStorePath = mkOption {
      type = types.str;
      description = ''
        Path to persist OAuth refresh tokens on disk.
        Example: /Users/you/.config/iap-proxy/tokens.json
      '';
    };

    autoOpenBrowser = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Open the system browser automatically when no valid tokens
        are available on startup (first run or after token expiry).
      '';
    };

    oauthClientId = mkOption {
      type = types.str;
      description = "Google OAuth 2.0 client ID.";
    };

    oauthClientSecret = mkOption {
      type = types.str;
      description = "Google OAuth 2.0 client secret.";
    };

    oauthRedirectUri = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        OAuth redirect URI. Defaults to http://localhost:{port}/oauth2callback.
      '';
    };

    iapClientId = mkOption {
      type = types.str;
      description = "IAP's OAuth 2.0 client ID (the audience for IAP tokens).";
    };

    teamcityToken = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "TeamCity personal access token (optional).";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ iap-proxy-pkg ];

    launchd.user.agents.iap-proxy = {
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
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Background";
        # WorkingDirectory must be writable — the proxy creates
        # iap_proxy.log via a relative FileHandler.  Without this,
        # launchd defaults to / which is read-only on macOS.
        WorkingDirectory = "/tmp";
        StandardOutPath = "/tmp/iap-proxy.log";
        StandardErrorPath = "/tmp/iap-proxy.log";

        EnvironmentVariables = {
          TARGET_URL = cfg.targetUrl;
          PORT = toString cfg.port;
          LOG_LEVEL = cfg.logLevel;
          OAUTH_CLIENT_ID = cfg.oauthClientId;
          OAUTH_CLIENT_SECRET = cfg.oauthClientSecret;
          IAP_CLIENT_ID = cfg.iapClientId;
          TOKEN_STORE_PATH = tokenStorePath;
          AUTO_OPEN_BROWSER = if cfg.autoOpenBrowser then "true" else "false";
        } // optionalAttrs (cfg.oauthRedirectUri != null) {
          OAUTH_REDIRECT_URI = cfg.oauthRedirectUri;
        } // optionalAttrs (cfg.teamcityToken != null) {
          TEAMCITY_TOKEN = cfg.teamcityToken;
        };
      };
    };
  };
}
