{
  description = "Decknix Local Configuration";

  inputs = {
    # Point to the shared repo
    decknix.url = "github:ldeck/decknix";

    # follow decknix inputs by default
    nixpkgs.follows = "decknix/nixpkgs";
    nix-darwin.follows = "decknix/nix-darwin";
  };

  outputs = inputs@{ self, decknix, nixpkgs, nix-darwin, ... }:
  let
    # 1. required settings path
    settingsPath = ./settings.nix;

    # If the file is missing (e.g. deleted), use defaults that trigger the error below
    settings = if builtins.pathExists settingsPath 
               then import settingsPath 
               else { username = "setup-required"; hostname = "setup-required"; system = "aarch64-darwin"; };

    inherit (settings) username hostname system;

    # 2. Path to external customizations
    externalConfig = "/Users/${username}/.local/decknix/config.nix";
  in
  {
    darwinConfigurations."default" = nix-darwin.lib.darwinSystem {
      inherit system;
      modules = [
        # 1. Import Shared Team Config
        decknix.darwinModules.default

        # 2. Local User Config
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
          users.users.${username}.home = "/Users/${username}";

          home-manager.users.${username} = { pkgs, ... }: {
            imports = [
              decknix.homeModules.default
              # Import external config if it exists
              (if builtins.pathExists externalConfig then externalConfig else {})
            ];

            # --- CONFIGURATION ---
            # Inject the email from settings.nix as a default
            programs.git.userEmail = lib.mkDefault (if settings ? email then settings.email else "user@example.com");

            # Select the role here. This determines which template is
            # generated if the local config is missing.
            decknix.role = lib.mkDefault (if settings ? role then settings.role else "developer");
            
            home.stateVersion = "24.05";
          };
        })
      ];
    };
  };
}
