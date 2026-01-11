{
  description = "decknix: Shared Team Nix Configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-parts.url = "github:hercules-ci/nix-parts";
  };

  outputs = inputs@{ self, nix-parts, ... }:
    nix-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" ];

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
      };
    };
}
