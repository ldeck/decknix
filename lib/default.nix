{
  # Build a complete darwinConfigurations set from minimal user input.
  #
  # Usage in user's flake.nix:
  #   outputs = inputs@{ decknix, ... }:
  #     decknix.lib.mkSystem {
  #       inherit inputs;
  #       settings = import ./settings.nix;
  #       darwinModules = [ inputs.nc-config.darwinModules.default ];
  #       homeModules   = [ inputs.nc-config.homeModules.default ];
  #     };
  mkSystem = {
    # The user's flake inputs (must include decknix, nixpkgs, nix-darwin)
    inputs,
    # Settings attrset: { username, hostname, system, role }
    settings ? {},
    # Extra darwin modules from org configs or user
    darwinModules ? [],
    # Extra home-manager modules from org configs or user
    homeModules ? [],
    # Extra specialArgs passed to darwinSystem
    extraSpecialArgs ? {},
    # home.stateVersion
    stateVersion ? "24.05",
  }:
  let
    decknix = inputs.decknix or (throw "mkSystem: inputs must include 'decknix'");
    nixpkgs = inputs.nixpkgs or (throw "mkSystem: inputs must include 'nixpkgs'");
    nix-darwin = inputs.nix-darwin or (throw "mkSystem: inputs must include 'nix-darwin'");

    lib = nixpkgs.lib;

    defaults = {
      username = "setup-required";
      hostname = "setup-required";
      system   = "aarch64-darwin";
      role     = "developer";
    };

    merged = defaults // settings;
    inherit (merged) username hostname system role;

    loader = decknix.lib.configLoader {
      inherit lib username hostname system role;
    };
  in {
    darwinConfigurations."default" = nix-darwin.lib.darwinSystem {
      specialArgs = { inherit inputs; } // extraSpecialArgs;

      modules = [
        { nixpkgs.hostPlatform = system; }

        # Framework
        decknix.darwinModules.default
      ]
      # Org/user darwin modules
      ++ darwinModules
      # Filesystem-discovered local system modules
      ++ loader.modules.system
      ++ [
        # User wiring
        ({ pkgs, ... }: {
          networking.hostName = hostname;
          system.primaryUser = username;
          users.users.${username}.home =
            if builtins.elem system [ "aarch64-linux" "x86_64-linux" ]
            then "/home/${username}"
            else "/Users/${username}";

          home-manager.extraSpecialArgs = { inherit inputs; } // extraSpecialArgs;
          home-manager.users.${username} = { pkgs, ... }: {
            imports = [
              decknix.homeModules.default
            ]
            ++ homeModules
            ++ loader.modules.home;

            decknix.username = username;
            decknix.hostname = hostname;
            decknix.role = role;

            home.stateVersion = stateVersion;
          };
        })
      ];
    };
  };

  # Returns a set of helper functions for loading local configurations
  configLoader = {
    lib,
    username,
    hostname ? "unknown",
    system ? "unknown",
    role ? "developer",
    homeDir ? (if builtins.elem system [ "aarch64-linux" "x86_64-linux" ] then "/home/${username}" else "/Users/${username}"),
    configDir ? "${homeDir}/.config/decknix",
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
        # Auto-discover directories in ~/.config/decknix
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
      # Load home.nix and secrets.nix together for home-manager
      # secrets.nix is gitignored and contains sensitive data like auth tokens
      home = (load "home") ++ (load "secrets");
      system = load "system";
    };
    inherit allOrgs;
  };
}

