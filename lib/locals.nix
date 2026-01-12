{
  # Returns a set of helper functions for loading local configurations

  # Usage: (configLoader { username = "ldeck"; }).load "home"
  configLoader = {
    username,
    hostname ? "unknown",    # Optional with default
    system ? "unknown",      # Optional with default
    role ? "developer",      # Optional with default
    configDir ? "/Users/${username}/.local/decknix",
    ...                      # Ellipsis allows future params without breaking
  }:

  let
    # 1. Helper to safely import a path if it exists
    optionalImport = path:
      if builtins.pathExists path then [ (import path) ] else [];

    # 2. Get the list of active orgs from 'enabled-orgs.nix' (defaults to ["default"])
    enabledOrgsPath = "${configDir}/enabled-orgs.nix";
    enabledOrgs =
      if builtins.pathExists enabledOrgsPath
      then import enabledOrgsPath
      else [ "default" ];

  in rec {
    # Expose the list of active orgs if needed for debugging
    activeOrgs = enabledOrgs;

    # Main function to load modules for a specific type ("home" or "system")
    load = type:
      let
        # A. Org-specific files (e.g. decknix/client-a/home.nix)
        orgModules = builtins.concatMap (org:
          optionalImport "${configDir}/${org}/${type}.nix"
        ) enabledOrgs;

        # B. Root-level files (e.g. decknix/home.nix) - for backwards compatibility or global overrides
        rootModules = optionalImport "${configDir}/${type}.nix";
      in
        orgModules ++ rootModules;
  };
}
