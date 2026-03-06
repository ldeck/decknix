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

  # Loads personal overrides from ~/.config/decknix/
  #
  # Org/team configs come via flake inputs. This loader handles personal
  # overrides, organised into directories:
  #
  #   local/              — generic personal overrides (always loaded)
  #   <org-name>/         — per-org personal overrides (name matches flake input)
  #
  # Each directory supports:
  #   home.nix, system.nix, secrets.nix   — direct files
  #   home/<anything>.nix                 — recursive subdirectory loading
  #
  # Example layout:
  #   ~/.config/decknix/
  #   ├── local/
  #   │   ├── home.nix           — personal packages, git identity
  #   │   └── system.nix         — machine-specific tweaks
  #   ├── nc-config/             — overrides for the nc-config flake input
  #   │   ├── home.nix           — disable a team git hook, etc.
  #   │   └── home/
  #   │       └── extra.nix      — recursively loaded
  #   └── secrets.nix            — root-level secrets (also supported)
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
    # --- HELPERS ---

    # Recursively find all .nix files in a directory
    findNixFiles = dir:
      if lib.pathIsDirectory dir then
        lib.filter (path: lib.hasSuffix ".nix" (toString path))
          (lib.filesystem.listFilesRecursive dir)
      else [];

    importWithTrace = type: paths:
      map (path:
        builtins.trace "  [Loader] ${type} + ${toString path}" (import path)
      ) paths;

    # --- Directory Discovery ---
    # Find all subdirectories in ~/.config/decknix/
    # Each corresponds to either "local" (personal) or an org name
    allDirs =
      if lib.pathIsDirectory configDir then
        let
          contents = builtins.readDir configDir;
        in
          builtins.attrNames (lib.filterAttrs (n: v: v == "directory") contents)
      else [];

    # --- Load Logic ---
    # For a given type (home, system, secrets), gather files from:
    #   1. Root-level: ~/.config/decknix/<type>.nix
    #   2. Each subdirectory:
    #      - Direct file:  <dir>/<type>.nix
    #      - Nested files:  <dir>/<type>/**/*.nix (recursive)
    load = type:
      let
        # 1. Root-level file
        rootFile = "${configDir}/${type}.nix";
        rootFiles = if lib.pathIsRegularFile rootFile then [ rootFile ] else [];

        # 2. Per-directory files (local + org override dirs)
        dirFiles = builtins.concatMap (dir:
          let
            dirPath = "${configDir}/${dir}";

            # Direct file: <dir>/<type>.nix
            directFile = "${dirPath}/${type}.nix";
            direct = if lib.pathIsRegularFile directFile then [ directFile ] else [];

            # Nested files: <dir>/<type>/**/*.nix
            nestedDir = "${dirPath}/${type}";
            nested = findNixFiles nestedDir;
          in
            direct ++ nested
        ) allDirs;

        allFiles = dirFiles ++ rootFiles;
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
    inherit allDirs;
  };
}

