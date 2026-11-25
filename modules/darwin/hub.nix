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
      wip_merged_retention_days = cfg.github.mergedRetentionDays;
      issues_interval_secs = cfg.github.issuesInterval;
      merge_ready_notify = cfg.github.mergeReadyNotify;
    };
    jira = {
      enabled = cfg.jira.enable;
      interval_secs = cfg.jira.interval;
      base_url = cfg.jira.baseUrl;
      email = cfg.jira.email;
      api_token_file = cfg.jira.apiTokenFile;
      api_token_secret = cfg.jira.apiTokenSecret;
      secrets_org = cfg.jira.secretsOrg;
      secrets_cli = "${pkgs.decknix-cli}/bin/decknix";
      project = cfg.jira.project;
      projects = cfg.jira.projects;
      pick_up = cfg.jira.pickUp;
      pick_up_projects = cfg.jira.pickUpProjects;
      statuses = cfg.jira.statuses;
      max_results = cfg.jira.maxResults;
    };
    chores = {
      enabled = cfg.chores.enable;
      interval_secs = cfg.chores.interval;
      filter = cfg.chores.filter;
      exclude_projects = cfg.chores.excludeProjects;
    };
    kargo = {
      enabled = cfg.kargo.enable;
      interval_secs = cfg.kargo.interval;
      no_deploy_after_hours = cfg.kargo.noDeployAfterHours;
      repos = map (r: {
        inherit (r) repo project warehouse stages region;
        stage_pattern = r.stagePattern;
        runtime_paths = r.runtimePaths;
      }) cfg.kargo.repos;
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
        description = ''
          Seconds between GitHub review-request polls.

          With GraphQL batching, all uncached PRs share a single
          reviewThreads request per repo, so 60s is safe even with
          large review queues (≈3–5 GraphQL calls/cycle regardless
          of queue depth).
        '';
      };

      wipInterval = mkOption {
        type = types.int;
        default = 60;
        description = ''
          Seconds between GitHub WIP PR polls.

          Tracks the user's open authored PRs; the Emacs sidebar mirrors
          this list and uses it as the authoritative source for "this PR
          is still open".  When a PR drops off the WIP list, the sidebar
          treats that as a strong signal that GitHub state changed and
          schedules a refresh, so this poll interval is the dominant
          component of "Open → Merged" latency for linked PRs.
        '';
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

      mergedRetentionDays = mkOption {
        type = types.int;
        default = 7;
        description = ''
          How many days a merged PR is kept in the WIP feed after merge.

          The sidebar keeps a merged PR under its session until its last
          deploy stage is verified, then shows it dimmed as shipped for the
          sidebar's shipped-retention toggle, then drops it.  This window
          only caps a merge that never deploys; it must exceed a typical
          merge-to-production time.  The merged query keeps the 50 most
          recent merges, so a much longer window adds nothing.
        '';
      };

      issuesInterval = mkOption {
        type = types.int;
        default = 300;
        description = ''
          Seconds between polls of open GitHub issues assigned to me
          (github-issues.json, the sidebar Tasks section).  0 disables.
        '';
      };

      mergeReadyNotify = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Tell the agent session that raised a PR when the PR is ready to
          merge, for workflows that pre-authorise agents to merge their
          own approved PRs.

          After each WIP poll the hub classifies every open PR you authored.
          One that is approved on its current head, not a draft, CI green
          and mergeable is `clean` with nothing left to answer, or
          `comments` with unresolved threads or a human reply since your
          last activity.  The owning session (found through its linked and
          created PRs) gets one `decknix session send --when idle` message
          per head commit and verdict.  The hub never merges: the session
          does, under its own repo and ship rules.

          A ready PR no live session claims shows in the sidebar ship
          queue as "approved · ready to merge" instead.  Dedupe state is
          kept in `merge-ready-state.json` in the hub directory.  Off by
          default because it prompts live sessions.
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
          Typically set by an org config overlay, which wires this from
          its own user.email option so each team member's identity flows through).
        '';
      };

      apiTokenFile = mkOption {
        type = types.str;
        default = "${homeDir}/.config/decknix/local/jira-token";
        defaultText = literalExpression ''"''${homeDir}/.config/decknix/local/jira-token"'';
        description = ''
          Deprecated fallback: a file holding the Jira API token (one line,
          trimmed), read only when `apiTokenSecret` is not in `decknix secrets`.
          Never point this inside ~/.config/decknix: that directory is copied
          into the world-readable /nix/store on every switch.
        '';
      };

      apiTokenSecret = mkOption {
        type = types.str;
        default = "jira-token";
        description = ''
          Name of the Jira API token in `decknix secrets` (the OS keychain),
          looked up at poll time with `decknix secrets get <name> --org <secretsOrg>`.
          Empty disables the lookup and uses `apiTokenFile` only.
        '';
      };

      secretsOrg = mkOption {
        type = types.str;
        default = "local";
        example = "my-org";
        description = "Org whose `decknix secrets` store holds `apiTokenSecret`.";
      };

      project = mkOption {
        type = types.str;
        default = "";
        description = "Legacy single Jira project key, used only when `projects` is empty.";
      };

      projects = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "ABC" "XYZ" ];
        description = ''
          Jira project keys the sidebar Tasks section lists: issues assigned to
          me in progress (and, unless `pickUpProjects` says otherwise,
          unassigned To Do issues in an open sprint).
          `[hub.jira] projects` in ~/.config/decknix/settings.toml overrides
          this at runtime (set it with `decknix hub jira-projects KEY...`); the
          hub re-reads it on every poll, so no rebuild is needed.
        '';
      };

      pickUp = mkOption {
        type = types.bool;
        default = true;
        description = "Also list unassigned To Do issues in open sprints of `pickUpProjects`.";
      };

      pickUpProjects = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "ABC" ];
        description = ''
          Jira project keys whose unassigned To Do issues in an open sprint
          the Tasks section offers to pick up.  Empty means `projects`.
          `[hub.jira] pick_up_projects` in ~/.config/decknix/settings.toml
          overrides it at runtime (`decknix hub jira-projects --pick-up
          KEY...`).
        '';
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

    chores = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable the chores adapter: pending Taskwarrior tasks matching
          `filter`, written to task-chores.json for the sidebar Tasks section.
          Read-only (`task rc.gc=off rc.hooks=off ... export`).
        '';
      };

      interval = mkOption {
        type = types.int;
        default = 120;
        description = "Seconds between chores polls (minimum 30).";
      };

      filter = mkOption {
        type = types.str;
        default = "+chore status:pending";
        description = "Taskwarrior filter selecting chores.";
      };

      excludeProjects = mkOption {
        type = types.listOf types.str;
        default = [ "decknix.perf" ];
        description = ''
          Projects (and their sub-projects) left out, such as the perf-hitch
          auto-filer's findings.
        '';
      };
    };

    kargo = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable the Kargo adapter: which deploy stages hold each of my merged
          PRs, written to kargo-stages.json for the sidebar.  Needs a logged-in
          `kargo` CLI on the daemon's PATH; without one the file carries an
          error and those PRs show as pending.
        '';
      };

      interval = mkOption {
        type = types.int;
        default = 300;
        description = "Seconds between Kargo polls (minimum 30).";
      };

      noDeployAfterHours = mkOption {
        type = types.int;
        default = 6;
        description = ''
          Hours after a merge that no stage holds before the hub checks
          whether anything that would change the deployed build has merged
          since the revision dev runs: when every file changed between that
          revision and the merge is outside the repo's runtime paths, the
          PR is marked "no deploy needed".  0 disables this later check;
          a PR whose own files touch no runtime path is marked at once
          either way.
        '';
      };

      repos = mkOption {
        type = types.listOf (types.submodule {
          options = {
            repo = mkOption {
              type = types.str;
              description = "GitHub repository, `owner/name`.";
            };
            project = mkOption {
              type = types.str;
              description = "Kargo project.";
            };
            warehouse = mkOption {
              type = types.str;
              description = "Kargo warehouse the repo's freight comes from.";
            };
            stages = mkOption {
              type = types.listOf types.str;
              example = [ "us-dev" "us-stg" "us-prd" ];
              description = "Stage display names in promotion order; the last is production.";
            };
            stagePattern = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "{warehouse}-{stage}-deploy";
              description = ''
                Kargo stage name for a display name, with `{warehouse}` and
                `{stage}` substituted.  Null means `{warehouse}-{stage}-deploy`.
              '';
            };
            region = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "US";
              description = ''
                Label for this deploy path when the repo ships more than one
                way.  A repo may be listed once per region; each entry becomes
                its own shipper in the sidebar, done only when all are.  Pair
                it with a `gitops` shipper of the same region in the Emacs
                option `decknix-ship-repo-shippers` to combine Kargo with
                TeamCity.
              '';
            };
            runtimePaths = mkOption {
              type = types.nullOr (types.listOf types.str);
              default = null;
              example = [ "cmd/**" "go.*" "Dockerfile" "helm/**" ];
              description = ''
                Globs (`*`, `**`, `?`) of the files that change what this
                repo deploys: its image build context, Dockerfile and chart,
                typically the path filter of the workflow that builds its
                freight.  A merged PR touching none of them is shown as "no
                deploy needed" instead of waiting forever for freight that
                will never be built.  Null uses the default: every file is
                runtime except documentation (`docs/`, `specs/`, `.specify/`,
                `*.md`) and repository metadata (`LICENSE*`, `.gitignore`,
                `CODEOWNERS`, issue and PR templates).
              '';
            };
          };
        });
        default = [];
        description = "Repositories that ship through Kargo, with their stages.";
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
