# Evaluation tests for adoption tiers (lib/adoption.nix).
#
# Each fixture under tests/fixtures is a config directory handed to mkSystem
# as `configDir`, so these evaluate purely. Failing expectations abort the
# evaluation with a message naming the fixture and the option; every system
# is also forced down to its toplevel drvPath so a tier that does not evaluate
# fails here rather than on someone's machine.
#
#   nix build .#checks.<system>.adoption-tiers
{ pkgs, self, inputs }:

let
  lib = pkgs.lib;
  user = "test";

  systemFor = fixture: (self.lib.mkSystem {
    inputs = inputs // { decknix = self; };
    settings = { username = user; hostname = "test"; system = "aarch64-darwin"; };
    configDir = ./fixtures + "/${fixture}";
  }).darwinConfigurations.default;

  observe = fixture:
    let
      sys = systemFor fixture;
      c = sys.config;
      hm = c.home-manager.users.${user};
      manifest = c.system.build.decknixManifest.data;
    in {
      inherit sys manifest;
      tier = c.decknix.adoption.tier;
      fromFile = c.decknix.adoption.fromFile;
      etcManifest = c.environment.etc ? "decknix/manifest.json";
      org = lib.mapAttrs (_: o: o.enable) c.decknix.adoption.org;
      on = {
        gortex = hm.decknix.ai.gortex.enable;
        apps = hm.decknix.apps.ungoogledChromium.enable;
        fonts = c.fonts.packages != [ ];
        linux-builder = c.decknix.linuxBuilder.enable;
        repo-sync = c.services.decknix.repoSync.enable;
        session-gc = c.services.decknix.sessionGc.enable;
        emacs-home = hm.programs.emacs.decknix.enable;
        emacs-daemon = c.services.emacs.decknix.enable;
        # Home and system layers must agree on the adopted state.
        home-tier-matches = hm.decknix.adoption.tier == c.decknix.adoption.tier;
      };
    };

  allOn = {
    gortex = true; apps = true; fonts = true; linux-builder = true;
    repo-sync = true; session-gc = true; emacs-home = true; emacs-daemon = true;
    home-tier-matches = true;
  };
  upTo = tier: lib.mapAttrs (name: _:
    name == "home-tier-matches"
    || (lib.elem name [ "gortex" ] && tier >= 2)
    || (lib.elem name [ "apps" "fonts" "linux-builder" "repo-sync" "session-gc" ] && tier >= 3)
    || (lib.elem name [ "emacs-home" "emacs-daemon" ] && tier >= 4)) allOn;

  expect = fixture: o: name: actual: wanted:
    lib.assertMsg (actual == wanted)
      "adoption fixture ${fixture}: ${name} is ${builtins.toJSON actual}, expected ${builtins.toJSON wanted}";

  expectSystem = fixture: spec:
    let
      o = observe fixture;
      check = expect fixture o;
      labels = o.manifest.launchd.userAgents ++ o.manifest.launchd.daemons;
    in
    lib.all (x: x) (
      [
        (check "tier" o.tier spec.tier)
        (check "fromFile" o.fromFile spec.fromFile)
        (check "/etc/decknix/manifest.json linked" o.etcManifest spec.fromFile)
        (check "manifest tier" o.manifest.adoption.tier spec.tier)
        (check "org toggles" o.org (spec.org or { }))
      ]
      ++ lib.mapAttrsToList (name: wanted: check name o.on.${name} wanted) spec.on
      ++ lib.mapAttrsToList (label: wanted:
          check "manifest lists ${label}" (lib.elem label labels) wanted) spec.labels
    )
    && builtins.isString o.sys.system.drvPath;

  labelsFor = on: {
    "org.nixos.decknix-repo-sync" = on.repo-sync;
    "org.nixos.decknix-session-gc" = on.session-gc;
    "org.nixos.emacs-server" = on.emacs-daemon;
    "org.nixos.linux-builder" = on.linux-builder;
  };

  cases = {
    # No adoption.toml: the pre-tier install, which must keep everything.
    config-empty = { tier = 4; fromFile = false; on = allOn; labels = labelsFor allOn; };
    adoption-tier1 = { tier = 1; fromFile = true; on = upTo 1; labels = labelsFor (upTo 1); };
    adoption-tier2 = { tier = 2; fromFile = true; on = upTo 2; labels = labelsFor (upTo 2); };
    adoption-tier3 = { tier = 3; fromFile = true; on = upTo 3; labels = labelsFor (upTo 3); };
    adoption-tier4 = { tier = 4; fromFile = true; on = upTo 4; labels = labelsFor (upTo 4); };
    adoption-tier3-no-builder =
      let on = upTo 3 // { linux-builder = false; }; in
      { tier = 3; fromFile = true; inherit on; labels = labelsFor on;
        org = { core = true; services = false; }; };
  };

  # Invalid files must fail evaluation rather than silently fall back.
  rejected = [ "adoption-tier0" "adoption-unknown-component" ];
  rejects = fixture:
    lib.assertMsg (!(builtins.tryEval (systemFor fixture).config.decknix.adoption.tier).success)
      "adoption fixture ${fixture} should be rejected but evaluated";

  passed =
    lib.all (x: x) (lib.mapAttrsToList expectSystem cases)
    && lib.all rejects rejected;
in
pkgs.runCommand "decknix-adoption-tiers" { } ''
  ${lib.optionalString passed ''
    echo "adoption tiers: ${toString (lib.length (lib.attrNames cases))} fixtures as expected, ${toString (lib.length rejected)} rejected" | tee $out
  ''}
''
