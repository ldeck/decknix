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
      # Filesystem-discovered identity modules (config.<org>.user.*)
      ++ loader.modules.identity
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
            # Identity modules — same options available in home-manager context
            ++ loader.modules.identity
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
  #   identity.nix                        — org user identity (auto-wired to config.<org>.user.*)
  #   home.nix, system.nix, secrets.nix   — direct files
  #   home/<anything>.nix                 — recursive subdirectory loading
  #
  # Identity files:
  #   When <org>/identity.nix exists, the loader generates NixOS module
  #   options under config.<org>.user.* (email, name, githubUser, gpgKey)
  #   and sets them from the identity file data. These options are available
  #   in both darwin and home-manager modules, so org configs can reference
  #   config.<org>.user.email without importing anything.
  #
  # Example layout:
  #   ~/.config/decknix/
  #   ├── local/
  #   │   ├── home.nix           — personal packages, git identity
  #   │   └── system.nix         — machine-specific tweaks
  #   ├── nurturecloud/
  #   │   ├── identity.nix       — { email = "you@nurturecloud.com"; name = "..."; }
  #   │   ├── home.nix           — NC-specific home overrides
  #   │   └── system.nix         — NC-specific system overrides
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

    # --- Identity Module Generation ---
    # For each <org>/identity.nix, generate a module that defines
    # options.<org>.user.* and sets them from the identity data.
    # This makes config.<org>.user.email etc. available everywhere.
    mkIdentityModule = orgName: identityPath:
      let
        identity = builtins.trace "  [Loader] identity + ${toString identityPath}" (import identityPath);
      in
      { lib, ... }: {
        options.${orgName}.user = {
          email = lib.mkOption {
            type = lib.types.str;
            default = identity.email or "";
            description = "User email for the ${orgName} organisation.";
          };
          name = lib.mkOption {
            type = lib.types.str;
            default = identity.name or "";
            description = "User full name for the ${orgName} organisation.";
          };
          githubUser = lib.mkOption {
            type = lib.types.str;
            default = identity.githubUser or "";
            description = "GitHub username for the ${orgName} organisation.";
          };
          gpgKey = lib.mkOption {
            type = lib.types.str;
            default = identity.gpgKey or "";
            description = "GPG signing key ID for the ${orgName} organisation.";
          };
        };
      };

    # Discover all identity files and generate modules
    identityModules =
      builtins.concatMap (dir:
        let
          identityFile = "${configDir}/${dir}/identity.nix";
        in
          if dir != "local" && lib.pathIsRegularFile identityFile
          then [ (mkIdentityModule dir identityFile) ]
          else []
      ) allDirs;

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
      # Identity modules — injected into both darwin and home-manager
      # so config.<org>.user.* is available in both contexts.
      identity = identityModules;
    };
    inherit allDirs;
  };
}

