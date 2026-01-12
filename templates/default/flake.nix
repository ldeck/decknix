{
  description = "Decknix Local Configuration";

  inputs = {
    # Point to the shared repo
    decknix.url = "github:ldeck/decknix"; # or "path:/<abs>/<path/<to>/<decknix>"

    # follow decknix inputs by default
    nixpkgs.follows = "decknix/nixpkgs";
    nix-darwin.follows = "decknix/nix-darwin";
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
    };
  in
  {
    darwinConfigurations."default" = nix-darwin.lib.darwinSystem {
      inherit system;
      modules = [
        # 1. Import Shared Team Config
        decknix.darwinModules.default

        # 2. Inject Dynamic System-Level Configuration
        #    (Loads ~/.local/decknix/<org>/system.nix for enabled orgs)
      ] ++ loader.modules.system ++ [

        # 3. Local User Config
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

          home-manager.users.${username} = { pkgs, ... }: {
            imports = [
              decknix.homeModules.default
              # Import external config if it exists
              (if builtins.pathExists externalConfig then externalConfig else {})
            ]
            # 4. Inject Dynamic Home-Level Configuration
            #    (Loads ~/.local/decknix/<org>/home.nix for enabled orgs)
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
