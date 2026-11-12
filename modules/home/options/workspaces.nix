{ config, lib, ... }:

with lib;

let
  cfg = config.decknix.workspaces;

  workspaceType = types.submodule {
    options = {
      path = mkOption {
        type = types.str;
        example = "~/Code/acme";
        description = "The workspace directory; repositories are cloned directly under it.";
      };
      githubOrgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "acme" "acme-infra" ];
        description = ''
          GitHub owners (orgs or users) whose repositories belong in this
          workspace. Matched case-insensitively.
        '';
      };
      cloneArgs = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        example = [ "--depth=50" ];
        description = ''
          Extra `git clone` arguments for an on-demand clone into this
          workspace. null uses the Emacs default (`--filter=blob:none`, a
          blobless partial clone with full history).
        '';
      };
    };
  };
in
{
  options.decknix.workspaces = mkOption {
    type = types.attrsOf workspaceType;
    default = { };
    example = literalExpression ''
      {
        acme = { path = "~/Code/acme"; githubOrgs = [ "acme" "acme-infra" ]; };
        personal = { path = "~/Code/me"; githubOrgs = [ "my-user" ]; };
      }
    '';
    description = ''
      Local workspaces and the GitHub orgs whose repositories live in each.

      When a PR arrives for a repository with no local checkout, the review
      board clones it into its org's workspace and starts the review there
      (the session's cwd is the workspace root, so its commands and skills
      load). An existing checkout anywhere always wins over the mapping.

      Fed to Emacs as `decknix-workspaces` and written to
      `~/.config/decknix/workspaces.json` for other tools.
    '';
  };

  config = mkIf (cfg != { }) {
    home.file.".config/decknix/workspaces.json".text = builtins.toJSON {
      workspaces = mapAttrs (_: w: {
        inherit (w) path githubOrgs;
      } // optionalAttrs (w.cloneArgs != null) { inherit (w) cloneArgs; }) cfg;
    };
  };
}
