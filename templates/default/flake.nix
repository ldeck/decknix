{
  description = "Decknix Local Configuration";

  inputs = {
    # --- DECKNIX SOURCE (Uncomment one) ---

    # 1. Standard Production (Default)
    decknix.url = "github:ldeck/decknix";

    # 2. Local Development (For testing local changes to the framework)
    # decknix.url = "path:/Users/ldeck/tools/decknix";

    # 3. Specific Branch
    # decknix.url = "github:ldeck/decknix/feature-branch";

    # 4. Specific Tag/Commit (Immutable/Stable)
    # decknix.url = "github:ldeck/decknix?rev=a1b2c3d4...";

    # --- ORG CONFIG (Optional) ---
    # Add org-specific configs as versioned flake inputs.
    # Each org repo exports darwinModules.default and homeModules.default.
    #
    # my-org-config = {
    #   url = "github:my-org/decknix-config";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };

    # follow decknix inputs by default
    nixpkgs.follows = "decknix/nixpkgs";
    nix-darwin.follows = "decknix/nix-darwin";
    nix-casks.follows = "decknix/nix-casks";
  };

  outputs = inputs@{ self, decknix, nixpkgs, nix-darwin, ... }:
  let
    # 1. Load Settings with Fallbacks
    settingsPath = ./settings.nix;

    defaults = {
      username = "setup-required";
      hostname = "setup-required";
      system   = "aarch64-darwin";
      role     = "developer";
    };

    settings = if builtins.pathExists settingsPath
               then (defaults // import settingsPath)
               else defaults;

    # 2. Inherit the 4 key settings
    inherit (settings) username hostname system role;

    # 3. Initialize the Configuration Loader
    #    We pass all context variables so the lib can use them if needed
    loader = decknix.lib.configLoader {
      inherit username hostname system role;
      lib = nixpkgs.lib;
    };
  in
  {
    darwinConfigurations."default" = nix-darwin.lib.darwinSystem {
      # Use nixpkgs.hostPlatform instead of deprecated 'system' argument
      specialArgs = { inherit inputs; };

      modules = [
        # Set the system via module (modern approach)
        { nixpkgs.hostPlatform = system; }

        # 1. Import Shared Team Config
        decknix.darwinModules.default

        # 2. Org Config via Flake Input (versioned, reproducible)
        #    Uncomment if using an org config flake input above:
        # inputs.my-org-config.darwinModules.default

        # 3. Org Config via Filesystem (local auto-discovery fallback)
        #    Loads ~/.config/decknix/<org>/system.nix for discovered orgs
      ] ++ loader.modules.system ++ [

        # 4. Local User Config
        ({ pkgs, lib, ... }: {
          # --- VALIDATION ---
          # This assertion runs at EVALUATION time (fastest feedback loop)
          assertions = [
            {
              assertion = username != "REPLACE_ME" && username != "setup-required";
              message = "Decknix Setup: You must edit 'settings.nix' and set your 'username' before building.";
            }
          ];

          # --- SYSTEM CONFIG ---
          networking.hostName = hostname;
          system.primaryUser = username;
          users.users.${username}.home = "/Users/${username}";

          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.users.${username} = { pkgs, ... }: {
            imports = [
              decknix.homeModules.default

              # 4. Org Config via Flake Input (versioned, reproducible)
              #    Uncomment if using an org config flake input above:
              # inputs.my-org-config.homeModules.default
            ]
            # 5. Org Config via Filesystem (local auto-discovery fallback)
            #    Loads ~/.config/decknix/<org>/home.nix for discovered orgs
            ++ loader.modules.home;

            # --- CONFIGURATION ---
            # Select the role here. This determines which template is
            # generated if the local config is missing.
            decknix.role = role;

            home.stateVersion = "24.05";
          };
        })
      ];
    };
  };
}
