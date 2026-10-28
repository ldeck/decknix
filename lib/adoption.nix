# Adoption state: which tier of decknix a machine has adopted, and which
# optional components are switched on.
#
# The state lives in ~/.config/decknix/adoption.toml, written by the installer
# and `decknix adopt` and editable by hand:
#
#   version = 1
#   tier = 3
#
#   [components]
#   linux-builder = false
#
#   [org]
#   core = true
#
# A machine with no adoption.toml is an install that predates adoption state.
# It must keep exactly what it has today, so the absence of the file means
# tier 4 with every component at its tier default, which is the full set the
# framework enabled before tiers existed.
{ lib }:

rec {
  formatVersion = 1;

  # Tier 0 is Nix alone; there is no decknix system to evaluate for it.
  minSystemTier = 1;
  maxTier = 4;

  # Framework components whose default depends on the tier. Only things that
  # were on by default before tiers are listed: anything already opt-in stays
  # opt-in at every tier, so tier 4 reproduces the pre-tier defaults exactly.
  components = {
    gortex = {
      tier = 2;
      description = "Gortex code-intelligence graph served to agents over MCP (decknix.ai.gortex).";
    };
    apps = {
      tier = 3;
      description = "GUI apps installed by default (Ungoogled Chromium).";
    };
    fonts = {
      tier = 3;
      description = "Nerd Fonts installed system-wide.";
    };
    linux-builder = {
      tier = 3;
      description = "On-demand Linux builder VM for building Linux derivations and images.";
    };
    repo-sync = {
      tier = 3;
      description = "launchd agent that fast-forwards workspace clones every few hours.";
    };
    session-gc = {
      tier = 3;
      description = "Weekly launchd agent that archives stale agent sessions.";
    };
    emacs = {
      tier = 4;
      description = "The full decknix Emacs configuration and its launchd daemon.";
    };
  };

  fileName = "adoption.toml";

  # Parse and validate an adoption.toml. Returns null when the file is absent.
  read = configDir:
    let
      path = "${toString configDir}/${fileName}";
    in
    if !(lib.pathIsRegularFile path) then null
    else validate path (builtins.fromTOML (builtins.readFile path));

  validate = path: raw:
    let
      fail = msg: throw "decknix: ${path}: ${msg}";
      known = [ "version" "tier" "components" "org" ];
      unknownKeys = lib.subtractLists known (builtins.attrNames raw);
      version = raw.version or formatVersion;
      tier = raw.tier or (fail "missing `tier` (0 to ${toString maxTier})");
      componentToggles = raw.components or { };
      unknownComponents =
        lib.subtractLists (builtins.attrNames components) (builtins.attrNames componentToggles);
      orgToggles = raw.org or { };
      nonBool = set: lib.attrNames (lib.filterAttrs (_: v: !builtins.isBool v) set);
    in
    if unknownKeys != [ ] then fail "unknown keys: ${toString unknownKeys}"
    else if version != formatVersion then
      fail "format version ${toString version} is not supported (expected ${toString formatVersion})"
    else if !(builtins.isInt tier) || tier < 0 || tier > maxTier then
      fail "`tier` must be an integer from 0 to ${toString maxTier}"
    else if tier < minSystemTier then
      fail "tier 0 is Nix alone, so there is no decknix system to build. Raise the tier or remove the file"
    else if unknownComponents != [ ] then
      fail "unknown components: ${toString unknownComponents} (known: ${toString (builtins.attrNames components)})"
    else if nonBool componentToggles != [ ] then
      fail "component toggles must be true or false: ${toString (nonBool componentToggles)}"
    else if nonBool orgToggles != [ ] then
      fail "org component toggles must be true or false: ${toString (nonBool orgToggles)}"
    else { inherit tier; components = componentToggles; org = orgToggles; };

  # Module setting the adoption options from a parsed file. Values use
  # mkDefault so a plain assignment in a personal module still wins.
  module = state: { lib, ... }:
    lib.optionalAttrs (state != null) {
      decknix.adoption = {
        fromFile = true;
        tier = lib.mkDefault state.tier;
        components = lib.mapAttrs (_: enable: { enable = lib.mkDefault enable; }) state.components;
        org = lib.mapAttrs (_: enable: { enable = lib.mkDefault enable; }) state.org;
      };
    };
}
