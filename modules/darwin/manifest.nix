# Install manifest: everything the active generation owns outside the Nix
# store, so uninstall and `decknix doctor` read facts instead of guessing.
#
# It is always buildable as `system.build.decknixManifest`, which does not
# touch the system closure. It is linked into /etc only when adoption state
# exists (decknix.adoption.writeManifest), because installs made before
# adoption state must keep a byte-identical system until they adopt.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.adoption;
  primaryUser = config.system.primaryUser;
  homeDir = config.users.users.${primaryUser}.home or "/Users/${primaryUser}";

  labelOf = name: agent: agent.serviceConfig.Label or "org.nixos.${name}";

  homeUsers = config.home-manager.users or { };

  homeAgents = mapAttrs (_: hm:
    mapAttrsToList (name: agent: agent.config.Label or "org.nix-community.home.${name}")
      (filterAttrs (_: agent: agent.enable or true) (hm.launchd.agents or { })))
    homeUsers;

  agentSyncTargets = mapAttrs (_: hm: attrNames (hm.decknix.cli.agentSync.files or { })) homeUsers;

  # Paths an uninstall must clean up that no switch removes declaratively.
  leftovers =
    [ "${homeDir}/.config/decknix/result" ]
    ++ optionals config.decknix.linuxBuilder.enable [ "/var/lib/linux-builder" ];

  manifest = {
    version = 1;
    adoption = {
      inherit (cfg) tier fromFile;
      components = mapAttrs (_: c: c.enable) cfg.components;
      org = mapAttrs (_: c: c.enable) cfg.org;
    };
    launchd = {
      userAgents = mapAttrsToList labelOf config.launchd.user.agents;
      agents = mapAttrsToList labelOf config.launchd.agents;
      daemons = mapAttrsToList labelOf config.launchd.daemons;
      home = homeAgents;
    };
    etc = attrNames (filterAttrs (_: f: f.enable) config.environment.etc);
    agentSync = agentSyncTargets;
    inherit leftovers;
  };

  # `data` carries the same content as an attrset so evaluation tests can
  # inspect it without building (and so without a darwin builder in CI).
  manifestFile = pkgs.writeText "decknix-manifest.json" (builtins.toJSON manifest)
    // { data = manifest; };
in
{
  options.decknix.adoption.writeManifest = mkOption {
    type = types.bool;
    default = cfg.fromFile;
    defaultText = literalExpression "config.decknix.adoption.fromFile";
    description = ''
      Link the install manifest into /etc/decknix/manifest.json. On by
      default once an adoption.toml exists, so installs made before adoption
      state keep an unchanged system until they adopt. The manifest is always
      buildable as `system.build.decknixManifest`.
    '';
  };

  config = {
    system.build.decknixManifest = manifestFile;
    environment.etc."decknix/manifest.json" = mkIf cfg.writeManifest {
      source = manifestFile;
    };
  };
}
