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

  # Loads personal overrides from ~/.config/decknix/local/
  #
  # Org/team configs should come via flake inputs (not filesystem discovery).
  # This loader only handles personal, machine-specific overrides:
  #   local/home.nix     — personal packages, shell config
  #   local/system.nix   — machine-specific tweaks
  #   local/secrets.nix  — tokens, keys (gitignored)
  #
  # For backwards compatibility, also checks the legacy "default/" directory
  # and any other subdirectories. This will be removed in a future version.
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
    localDir = "${configDir}/local";

    # --- HELPERS ---
    findNixFiles = dir:
      if lib.pathIsDirectory dir then
        lib.filter (path: lib.hasSuffix ".nix" (toString path))
          (lib.filesystem.listFilesRecursive dir)
      else [];

    importWithTrace = type: paths:
      map (path:
        builtins.trace "  [Loader] ${type} + ${toString path}" (import path)
      ) paths;

    # --- Legacy compatibility ---
    # Auto-discover subdirectories (e.g., "default/") for users who haven't
    # migrated to "local/" yet. Will be removed in a future version.
    legacyDirs =
      if lib.pathIsDirectory configDir then
        let
          contents = builtins.readDir configDir;
          dirs = builtins.attrNames (lib.filterAttrs (n: v: v == "directory") contents);
          nonLocal = builtins.filter (d: d != "local") dirs;
        in
          if nonLocal != [] then
            builtins.trace "  [Loader] Legacy dirs found: ${toString nonLocal} (migrate to local/)" nonLocal
          else []
      else [];

    # --- Load Logic ---
    load = type:
      let
        # 1. Root-level file (e.g., ~/.config/decknix/home.nix)
        rootFile = "${configDir}/${type}.nix";
        rootFiles = if lib.pathIsRegularFile rootFile then [ rootFile ] else [];

        # 2. local/ directory (the canonical location)
        localFile = "${localDir}/${type}.nix";
        localFiles = if lib.pathIsRegularFile localFile then [ localFile ] else [];

        # 3. Legacy subdirectories (backwards compat)
        legacyFiles = builtins.concatMap (dir:
          let
            f = "${configDir}/${dir}/${type}.nix";
          in
            if lib.pathIsRegularFile f then [ f ] else []
        ) legacyDirs;

        allFiles = localFiles ++ legacyFiles ++ rootFiles;
      in
        if allFiles == [] then
          builtins.trace "  [Loader] No ${type} modules found." []
        else
          importWithTrace type allFiles;
  in {
    modules = {
      home = (load "home") ++ (load "secrets");
      system = load "system";
    };
  };
}

