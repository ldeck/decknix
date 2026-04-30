# Inline timestamp on the Starship prompt line.  Renders as
# `... · 2026-04-30T14:32:15 · took 45s` (or just `... · ts` when no
# command duration is reported), grouping wall-clock time with the
# command-duration as twin temporal signals.
#
# Configurable via `programs.starship.decknix.timestamp.*` — disable,
# pick a strftime format, change the separator/style.  Format strings
# follow Chrono's syntax — see
# https://docs.rs/chrono/latest/chrono/format/strftime/.
{ config, lib, ... }:

with lib;

let
  cfg = config.programs.starship.decknix.timestamp;
in
{
  options.programs.starship.decknix.timestamp = {
    enable = mkEnableOption "inline timestamp on the Starship prompt line" // {
      default = true;
    };

    format = mkOption {
      type = types.str;
      default = "%Y-%m-%dT%H:%M:%S";
      example = "%H:%M";
      description = ''
        Strftime format for the timestamp (Chrono syntax).  Common choices:

        | Format             | Renders as              |
        |--------------------|-------------------------|
        | `%Y-%m-%dT%H:%M:%S`| `2026-04-30T14:32:15` (ISO 8601, default) |
        | `%T`               | `14:32:15` (== `%H:%M:%S`) |
        | `%H:%M`            | `14:32`                 |
        | `%a %H:%M`         | `Tue 14:32`             |
        | `%b %d %T`         | `Apr 30 14:32:15`       |
        | `%I:%M %p`         | `02:32 PM`              |

        Full reference:
        https://docs.rs/chrono/latest/chrono/format/strftime/.
      '';
    };

    separator = mkOption {
      type = types.str;
      default = " · ";
      example = " | ";
      description = ''
        Separator placed before the timestamp and before `took ...` so
        both temporal signals share the same visual leader.
      '';
    };

    style = mkOption {
      type = types.str;
      default = "dimmed";
      example = "bold cyan";
      description = ''
        Starship style string applied to the timestamp segment (and the
        leading separator on `took ...`).  See
        https://starship.rs/config/#style-strings for syntax.
      '';
    };
  };

  config = mkIf (cfg.enable && config.programs.starship.enable) {
    programs.starship.settings = {
      # Reposition $time so it sits inline immediately before
      # $cmd_duration on the same line as the path / git status.  $all
      # picks up every module not explicitly listed below in upstream's
      # default order, so future additions to the default starship
      # format continue to render where they would by default.
      format = mkDefault (concatStrings [
        "$all"
        "$time"
        "$cmd_duration"
        "$line_break"
        "$jobs"
        "$battery"
        "$status"
        "$os"
        "$container"
        "$shell"
        "$character"
      ]);

      time = {
        disabled = mkDefault false;
        time_format = mkDefault cfg.format;
        # Whole segment styled with cfg.style so the leader and
        # timestamp read as one unit.
        format = mkDefault "[${cfg.separator}$time]($style)";
        style = mkDefault cfg.style;
      };

      # Mirror the timestamp's separator on cmd_duration so the two
      # read as a pair (` · 14:32:15 · took 45s`).  The leader uses
      # cfg.style (dim by default) so it doesn't compete with the
      # `took 45s` value, which keeps the upstream cmd_duration style.
      cmd_duration = {
        format = mkDefault
          "[${cfg.separator}](${cfg.style})took [$duration]($style) ";
      };
    };
  };
}
