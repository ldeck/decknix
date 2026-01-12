{
  description = "decknix: Shared Team Nix Configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";

    nix-darwin.url = "github:LnL7/nix-darwin/nix-darwin-25.11";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];

      perSystem = { config, self', inputs', pkgs, system, ... }: {
        # Devshell for working on decknix itself
        devShells.default = pkgs.mkShell {
          packages = [ pkgs.nixpkgs-fmt ];
        };
      };

      flake = {
        # EXPOSED MODULES
        # These are what the user's local flake will import.
        darwinModules = {
          default = { config, pkgs, ... }: {
            imports = [
              ./modules/darwin/default.nix
              inputs.home-manager.darwinModules.home-manager
            ];
          };
        };
        
        homeModules = {
          default = ./modules/home/default.nix;
        };

        templates = {
          default = {
            path = ./templates/default;
            description = "Standard Decknix User Configuration";
            welcomeText = ''
              # Welcome to Decknix!
  
              To finish setup:
              1. Edit 'flake.nix' and update 'username' and 'hostname'.
              2. Run 'nix run nix-darwin -- switch --flake .#default --impure'
  
              Enjoy!
            '';
          };
        };
      };
    };
}
