{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.services.hub;
  homeDir = config.users.users.${config.system.primaryUser}.home;

  # Build the config JSON from Nix options
  hubConfig = {
    github = {
      enabled = cfg.github.enable;
      reviews_interval_secs = cfg.github.reviewsInterval;
      wip_interval_secs = cfg.github.wipInterval;
      review_repos = cfg.github.reviewRepos;
    };
    jira = {
      enabled = cfg.jira.enable;
      interval_secs = cfg.jira.interval;
      base_url = cfg.jira.baseUrl;
      email = cfg.jira.email;
      api_token_file = cfg.jira.apiTokenFile;
      project = cfg.jira.project;
      statuses = cfg.jira.statuses;
      max_results = cfg.jira.maxResults;
    };
    teamcity = {
      enabled = cfg.teamcity.enable;
      interval_secs = cfg.teamcity.interval;
      proxy_url = cfg.teamcity.proxyUrl;
      repos = cfg.teamcity.repos;
      recent_finished_count = cfg.teamcity.recentFinishedCount;
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

    jira = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable Jira adapter (assigned tasks polling).";
      };

      interval = mkOption {
        type = types.int;
        default = 120;
        description = "Seconds between Jira polls.";
      };

      baseUrl = mkOption {
        type = types.str;
        default = "";
        description = "Jira base URL (e.g. https://myorg.atlassian.net).";
      };

      email = mkOption {
        type = types.str;
        default = "";
        description = ''
          Jira user email for API authentication.
          Typically set by org config (e.g. nc-config wires this from
          its own user.email option so each team member's identity flows through).
        '';
      };

      apiTokenFile = mkOption {
        type = types.str;
        default = "${homeDir}/.config/decknix/local/jira-token";
        defaultText = literalExpression ''"''${homeDir}/.config/decknix/local/jira-token"'';
        description = "Path to file containing Jira API token (one line, trimmed).";
      };

      project = mkOption {
        type = types.str;
        default = "";
        description = "Jira project key for filtering (e.g. NC). Empty = all projects.";
      };

      statuses = mkOption {
        type = types.listOf types.str;
        default = [ "Ready" "In Progress" "Blocked" "Code Review" ];
        description = "Jira statuses to include in task polling.";
      };

      maxResults = mkOption {
        type = types.int;
        default = 50;
        description = "Maximum number of Jira tasks to fetch per poll.";
      };
    };

    teamcity = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable TeamCity adapter (build status via IAP proxy).";
      };

      interval = mkOption {
        type = types.int;
        default = 60;
        description = "Seconds between TeamCity polls.";
      };

      proxyUrl = mkOption {
        type = types.str;
        default = "http://localhost:58080";
        description = "TeamCity IAP proxy URL.";
      };

      repos = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Repos to track builds for (owner/repo format). Empty = all.";
      };

      recentFinishedCount = mkOption {
        type = types.int;
        default = 1;
        description = "Number of recent finished builds to include per WIP branch.";
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

      # Mirror the standard Nix-first PATH order so Nix-managed tools
      # are always preferred over system equivalents.
      path = [
        "${pkgs.gh}/bin"
        "${homeDir}/.nix-profile/bin"
        "/run/current-system/sw/bin"
        "/nix/var/nix/profiles/default/bin"
        "/usr/local/bin"
        "/usr/bin"
        "/bin"
        "/usr/sbin"
        "/sbin"
      ];
    };
  };
}
