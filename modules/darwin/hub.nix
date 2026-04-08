{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.services.hub;

  # Build the config JSON from Nix options
  hubConfig = {
    github = {
      enabled = cfg.github.enable;
      reviews_interval_secs = cfg.github.reviewsInterval;
      wip_interval_secs = cfg.github.wipInterval;
      review_repos = cfg.github.reviewRepos;
    };
  };

  configFile = pkgs.writeTextFile {
    name = "hub-config.json";
    text = builtins.toJSON hubConfig;
  };
in
{
  options.decknix.services.hub = {
    enable = mkEnableOption "decknix-hub background work-item aggregator";

    github = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable GitHub adapter (PR reviews, WIP PRs, CI status).";
      };

      reviewsInterval = mkOption {
        type = types.int;
        default = 60;
        description = "Seconds between GitHub review-request polls.";
      };

      wipInterval = mkOption {
        type = types.int;
        default = 120;
        description = "Seconds between GitHub WIP PR polls.";
      };

      reviewRepos = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          GitHub repos to check for review requests.
          Empty means all repos (uses gh search).
          Format: "owner/repo".
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    # Add the package to system packages so the user can run it manually too
    environment.systemPackages = [ pkgs.decknix-hub ];

    # Launchd user agent — runs as a background daemon
    launchd.user.agents.decknix-hub = {
      command = "${pkgs.decknix-hub}/bin/decknix-hub --config ${configFile}";

      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Background";

        # Log to ~/Library/Logs/ for easy inspection
        StandardOutPath = "/tmp/decknix-hub.log";
        StandardErrorPath = "/tmp/decknix-hub.log";
      };

      # Inherit PATH so gh CLI is found
      path = [
        "${pkgs.gh}/bin"
        "/usr/bin"
        "/bin"
      ];
    };
  };
}
