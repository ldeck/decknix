{
  description = "decknix: Shared Team Nix Configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";

    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    # Newer nixpkgs sourced *solely* for rustPlatform. The pinned stable
    # (nixos-25.11) and the current nixpkgs-unstable pin both predate the
    # crates.io vendoring fixes — #512735 (sets a non-generic User-Agent on
    # fetchCargoVendor) and #524985 (switches importCargoLock to the
    # static.crates.io CDN). Without them crates.io returns HTTP 403 to the
    # generic library User-Agent during the Rust vendor phase. Scoped to the
    # three Rust derivations (decknix-cli/hub, nix-open) so the rest of the
    # package set is unaffected; resolved to a concrete rev by nix flake lock.
    nixpkgs-rust.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    nix-darwin = {
      url = "github:LnL7/nix-darwin/nix-darwin-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-casks = {
      url = "github:atahanyorganci/nix-casks/archive";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];

      # make 'pkgs.decknix' available to any module that uses this overlay.
      flake.overlays.default = final: prev:
        let
          # rustPlatform pinned to nixpkgs-rust (see input comment) so the
          # crates.io 403s during vendoring are fixed without moving the rest
          # of the package set. Threaded into the three Rust derivations only.
          rustPkgs = import inputs.nixpkgs-rust {
            inherit (final.stdenv.hostPlatform) system;
            inherit (final) config;
          };
          rustArgs = { inherit (rustPkgs) rustPlatform; };
        in
        {
          decknix-cli = final.callPackage ./pkgs/decknix-cli/default.nix rustArgs;
          decknix-hub = final.callPackage ./pkgs/decknix-hub/default.nix rustArgs;
          nix-open = final.callPackage ./pkgs/nix-open/default.nix rustArgs;
          # ACP bridges for agent-shell providers (not yet in nixpkgs)
          claude-agent-acp = final.callPackage ./pkgs/claude-agent-acp/default.nix { };
          pi-acp = final.callPackage ./pkgs/pi-acp/default.nix { };
        };

      perSystem = { config, self', inputs', pkgs, system, ... }:
        let
          # Same pinned rustPlatform as the overlay, for the flake's own
          # 'nix build .#decknix-cli' / CI package outputs.
          rustPkgs = import inputs.nixpkgs-rust {
            inherit system;
            inherit (pkgs) config;
          };
          rustArgs = { inherit (rustPkgs) rustPlatform; };
        in
        {
        # --- Expose the Decknix CLI Package ---
        # This allows you to run 'nix run .#decknix' or 'nix build'
        packages.decknix-cli = pkgs.callPackage ./pkgs/decknix-cli/default.nix rustArgs;
        packages.decknix-hub = pkgs.callPackage ./pkgs/decknix-hub/default.nix rustArgs;
        packages.nix-open = pkgs.callPackage ./pkgs/nix-open/default.nix rustArgs;
        packages.claude-agent-acp = pkgs.callPackage ./pkgs/claude-agent-acp/default.nix { };
        packages.pi-acp = pkgs.callPackage ./pkgs/pi-acp/default.nix { };

        # Set it as the default so 'nix run' works without arguments
        packages.default = config.packages.decknix-cli;

        # Devshell for working on decknix itself
        devShells.default = pkgs.mkShell {
          packages = [
            # nix
            pkgs.nixpkgs-fmt

            # rust
            pkgs.cargo
            pkgs.rustc
            pkgs.rustfmt
          ];
        };
      };

      flake = {
        # 1. EXPOSE DECKNIX LIBS HERE
        # This allows downstream flakes to use e.g., inputs.decknix.lib.configLoader
        lib = import ./lib;

        # 2. EXPOSED MODULES
        # These are what the user's local flake will import.
        darwinModules = {
          default = { config, ... }: let
            find = import ./lib/find.nix { lib = nixpkgs.lib; };
            unstableOverlay = final: prev: {
              unstable = import inputs.nixpkgs-unstable {
                system = prev.stdenv.hostPlatform.system;
                config = prev.config;
              };
            };
          # LLVM 20.x getMacOSHostVersion test fails on macOS Sequoia (Darwin 25.x).
          # Skip tests until upstream fixes: https://github.com/llvm/llvm-project/issues/
          # Use overrideScope so clang and other dependents pick up the patched llvm.
            llvmTestFixOverlay = final: prev: {
              llvmPackages_20 = prev.llvmPackages_20.overrideScope (llvmFinal: llvmPrev: {
                llvm = llvmPrev.llvm.overrideAttrs { doCheck = false; };
              });
            };
          in
          {
            imports =
              (find.nixFiles ./modules/darwin) ++ [
              inputs.home-manager.darwinModules.home-manager
            ];

            # expose 'lib.find' globally
            config.lib.find = find;

            # Tiered package sourcing: make pkgs.unstable available to all modules
            # Priority: stable nixpkgs > unstable nixpkgs > nix-casks > custom derivations
            # self.overlays.default provides the decknix custom packages
            # (decknix-cli/hub, nix-open, claude-agent-acp, pi-acp) built with a
            # pinned rustPlatform; it must be applied here (not in
            # modules/darwin) because only this flake closes over the private
            # nixpkgs-rust input.
            # llvmTestFixOverlay disables LLVM 20 tests that fail on macOS Sequoia.
            config.nixpkgs.overlays = [ llvmTestFixOverlay unstableOverlay self.overlays.default ];

            # Propagate pkgs.unstable AND the decknix custom-package overlay
            # (decknix-cli/hub, nix-open, claude-agent-acp, pi-acp) into
            # home-manager's own pkgs.  home-manager does not use useGlobalPkgs,
            # so it does not inherit the system's nixpkgs.overlays — modules
            # that reference e.g. pkgs.pi-acp need the overlay applied here too.
            config.home-manager.sharedModules = [{
              nixpkgs.overlays = [ llvmTestFixOverlay unstableOverlay self.overlays.default ];
            }];
          };
        };

        homeModules = {
          default = ./modules/home/default.nix;
        };

        # 3. TEMPLATES
        # (This is where you'd define flake template for each "role")
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
