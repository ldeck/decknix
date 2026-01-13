{
  # Returns a set of helper functions for loading local configurations
  configLoader = {
    username,
    hostname ? "unknown",
    system ? "unknown",
    role ? "developer",
    configDir ? "/Users/${username}/.local/decknix",
    ...
  }:
  let
    # 1. Helper to safely import a path if it exists
    optionalImport = path:
      if builtins.pathExists path then
        builtins.trace "  [Loader] Found: ${path}" [ (import path) ]
      else
        builtins.trace "  [Loader] Miss : ${path}" [];

    # 2. Get the list of active orgs
    enabledOrgsPath = "${configDir}/enabled-orgs.nix";
    enabledOrgs =
      if builtins.pathExists enabledOrgsPath
      then builtins.trace "  [Loader] Orgs : Custom (${enabledOrgsPath})" (import enabledOrgsPath)
      else builtins.trace "  [Loader] Orgs : Default" [ "default" ];

    # 3. The internal worker function
    load = type:
      let
        _ = builtins.trace "  [Loader] Scan : ${type} in ${configDir}..." null;

        orgModules = builtins.concatMap (org:
          optionalImport "${configDir}/${org}/${type}.nix"
        ) enabledOrgs;

        rootModules = optionalImport "${configDir}/${type}.nix";
      in
        orgModules ++ rootModules;

  in {
    # We pre-calculate the modules so flake.nix can access loader.modules.system
    modules = {
      home = load "home";
      system = load "system";
    };

    # Expose metadata for debugging
    inherit enabledOrgs;
  };
}
