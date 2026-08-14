{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.decknix.repoSync;

  # Runs `decknix repos sync`: for every primary clone under the configured
  # workspace roots ([repos].workspaces in settings.toml, one per GitHub org),
  # fetch origin and fast-forward the default branch — WITHOUT ever touching a
  # dirty tree or the checked-out feature branch. Keeping origin/main + local
  # main fresh across all of an org's repos materially helps AI agents (grep,
  # rebase targets, up-to-date context).
  #
  # git + ssh must be on PATH; the CLI itself forces GIT_TERMINAL_PROMPT=0 and a
  # batch-mode GIT_SSH_COMMAND per invocation, so the job never blocks on a
  # password and fails fast on an unreachable host. Private SSH remotes are
  # served by the macOS keychain ssh-agent, which user launchd agents can reach.
  syncScript = pkgs.writeShellScript "decknix-repo-sync" ''
    export PATH=${lib.makeBinPath [ pkgs.git pkgs.openssh ]}:$PATH
    exec ${pkgs.decknix-cli}/bin/decknix repos sync ${optionalString (cfg.jobs != null) "--jobs ${toString cfg.jobs}"}
  '';
in
{
  options.services.decknix.repoSync = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Periodic launchd job that fetches + fast-forwards every configured clone's default branch to keep local code fresh.";
    };

    intervalHours = mkOption {
      type = types.int;
      default = 3;
      description = "How often to run, in hours (launchd StartInterval).";
    };

    runAtLoad = mkOption {
      type = types.bool;
      default = true;
      description = "Also run shortly after login / a `decknix switch` so clones freshen promptly.";
    };

    jobs = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "Max concurrent repos to sync. Null lets the CLI pick min(8, CPUs).";
    };
  };

  config = mkIf cfg.enable {
    launchd.user.agents.decknix-repo-sync = {
      command = "${syncScript}";
      serviceConfig = {
        # A plain interval (seconds) rather than a calendar time: freshness wants
        # "every few hours while I work", not a fixed clock slot. A missed run
        # (laptop asleep) simply fires on the next interval.
        StartInterval = cfg.intervalHours * 3600;
        RunAtLoad = cfg.runAtLoad;
        # Low priority + throttled I/O: this is background hygiene, never urgent.
        ProcessType = "Background";
        LowPriorityIO = true;
        Nice = 5;
        StandardOutPath = "/tmp/decknix-repo-sync.out";
        StandardErrorPath = "/tmp/decknix-repo-sync.err";
      };
    };
  };
}
