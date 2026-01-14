{
  # Returns a set of helper functions for loading local configurations
  configLoader = {
    lib,
    username,
    hostname ? "unknown",
    system ? "unknown",
    role ? "developer",
    configDir ? "/Users/${username}/.local/decknix",
    ...
  }:
  let
    # --- HELPER: Recursive File Scanner ---
    # Recursively find all .nix files in a dir
    findFiles = dir: ext:
      if lib.pathIsDirectory dir then
        let
          allPaths = lib.filesystem.listFilesRecursive dir;
        in
          lib.filter (path: lib.hasSuffix ext (toString path)) allPaths
      else [];

    findNixFiles = dir:
      findFiles dir "nix";

    # --- 2. Import and Trace Helper ---
    # Imports a list of paths, adding a debug trace for each one
    importWithTrace = type: paths:
      map (path:
        builtins.trace "  [Loader] ${type} + ${toString path}" (import path)
      ) paths;

    # --- 3. Org Discovery ---
    enabledOrgsPath = "${configDir}/enabled-orgs.nix";

    allOrgs =
      if lib.pathIsRegularFile enabledOrgsPath then
        import enabledOrgsPath
      else if lib.pathIsDirectory configDir then
        # Auto-discover directories in ~/.local/decknix
        let
          contents = builtins.readDir configDir;
          dirs = builtins.attrNames (lib.filterAttrs (n: v: v == "directory") contents);
        in
          builtins.trace "  [Loader] Auto-discovered orgs: ${toString dirs}" dirs
      else
        builtins.trace "  [Loader] No local config directory found." [];

    # --- 4. Main Load Logic ---
    load = type:
      let
        # root only file path
        rootFilePath = "${configDir}/${type}.nix";

        # also support simpler root only files (e.g., decknix/home.nix)
        rootFiles =
          (if lib.pathIsRegularFile rootFilePath then [ rootFilePath ] else []);

        # Gather all relevant files from all enabled orgs
        orgNestedFiles = builtins.concatMap (org:
          let
            orgTypePath = "${configDir}/${org}/${type}";
            orgTypeFile = "${orgTypePath}.nix";

            # check for direct file (e.g., decknix/default/home.nix)
            direct = if lib.pathIsRegularFile orgTypeFile then [ orgTypeFile ] else [];

            nested = findNixFiles orgTypePath;
          in
            direct ++ nested
        ) allOrgs;

        allNixFiles = orgNestedFiles ++ rootFiles;
      in
        if allNixFiles == [] then
          builtins.trace "  [Loader] No ${type} modules found." []
        else
          importWithTrace type allNixFiles;
  in {
    modules = {
      home = load "home";
      system = load "system";
    };
    inherit allOrgs;
  };
}

