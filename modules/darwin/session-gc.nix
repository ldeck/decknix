{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.decknix.sessionGc;

  # Runs `decknix session gc`: archives sessions inactive longer than
  # [session].archive_after (compress + index, remove original) and moves
  # archives inactive longer than [session].trash_after to ~/.Trash. Keeps the
  # agent session dirs (which Emacs jq-scans) from growing unbounded — an
  # oversized ~/.augment/sessions was a real cause of memory thrash + freezes.
  #
  # No external tools needed at runtime (zstd is linked into the CLI), so a bare
  # exec is enough even under launchd's minimal PATH.
  gcScript = pkgs.writeShellScript "decknix-session-gc" ''
    exec ${pkgs.decknix-cli}/bin/decknix session gc
  '';
in
{
  options.services.decknix.sessionGc = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Weekly launchd job that archives stale agent sessions and trashes very old archives.";
    };

    weekday = mkOption {
      type = types.int;
      default = 0; # Sunday
      description = "Day of week to run (launchd Weekday: 0/7 = Sunday).";
    };

    hour = mkOption {
      type = types.int;
      default = 3;
      description = "Hour of day to run.";
    };

    minute = mkOption {
      type = types.int;
      default = 30;
      description = "Minute of the hour to run.";
    };
  };

  config = mkIf cfg.enable {
    launchd.user.agents.decknix-session-gc = {
      command = "${gcScript}";
      serviceConfig = {
        # Missed runs (laptop asleep at the scheduled time) fire once on wake.
        StartCalendarInterval = [
          { Weekday = cfg.weekday; Hour = cfg.hour; Minute = cfg.minute; }
        ];
        RunAtLoad = false;
        ProcessType = "Background";
        StandardOutPath = "/tmp/decknix-session-gc.out";
        StandardErrorPath = "/tmp/decknix-session-gc.err";
      };
    };
  };
}
