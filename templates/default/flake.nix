{
  description = "Decknix Local Configuration";

  inputs = {
    # Point to the shared repo
    decknix.url = "github:ldeck/decknix";

    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, decknix, nix-darwin, ... }:
  let
    # ==========================================
    # USER CONFIGURATION - EDIT THESE
    # ==========================================
    username = "james"; # change this to <your username>
    hostname = "james-macbook"; # change this to the output of `hostname -s`
    system   = "aarch64-darwin"; # or x86_64-darwin if on intel. Switch 'darwin' for 'linux' if on linux. 
    # ==========================================

    # Path to purely local, untracked customizations
    externalConfig = "/Users/${username}/.local/decknix/config.nix";
  in
  {
    darwinConfigurations."default" = nix-darwin.lib.darwinSystem {
      inherit system;
      modules = [
        # 1. Import Shared Team Config
        decknix.darwinModules.default

        # 2. Local User Config
        ({ pkgs, ... }: {
          users.users.${username}.home = "/Users/${username}";
          networking.hostName = hostname;

          home-manager.users.${username} = { pkgs, ... }: {
            imports = [
              decknix.homeModules.default
              # Import external config if it exists
              (if builtins.pathExists externalConfig then externalConfig else {})
            ];

            # --- CONFIGURATION ---
            # Select the role here. This determines which template is
            # generated if the local config is missing.
            decknix.role = "developer";
            
            home.stateVersion = "24.05";
          };
        })
      ];
    };
  };
}
