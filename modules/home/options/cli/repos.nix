{ config, lib, ... }:

with lib;

let
  cfg = config.decknix.cli.repos;
in
{
  options.decknix.cli.repos.workspaces = mkOption {
    type = types.listOf types.str;
    default = [ ];
    example = [ "my-org=~/Code/my-org" "~/tools" ];
    description = ''
      Workspace roots `decknix repos` scans for primary clones, one per
      GitHub org, as `org=~/path` (or a bare path, labelled by its directory
      name). Written to `~/.config/decknix/repos.json`. `[repos].workspaces`
      in `settings.toml` and `--workspace` flags take precedence; with none of
      them set, the CLI scans `~/Code`.
    '';
  };

  config = mkIf (cfg.workspaces != [ ]) {
    home.file.".config/decknix/repos.json".text =
      builtins.toJSON { inherit (cfg) workspaces; };
  };
}
