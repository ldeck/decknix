{ lib, rustPlatform, ... }:

let
  manifest = (lib.importTOML ./Cargo.toml).package;

in
rustPlatform.buildRustPackage {
  pname = manifest.name;
  version = manifest.version;

  src = ./.;

  # Use per-crate fetchurl FODs (importCargoLock) rather than the single
  # parallel fetchCargoVendor staging derivation. The latter downloads every
  # crate in one multiprocessing pool, which trips crates.io rate-limiting and
  # yields intermittent HTTP 403s on the /api/v1/.../download endpoint. With a
  # lockFile, each crate is its own cached fixed-output derivation that nix
  # fetches (and retries) independently, so partial progress is never lost.
  cargoLock.lockFile = ./Cargo.lock;

  meta = with lib; {
    description = "Background work-item aggregator — polls GitHub, Jira, CI/CD";
    mainProgram = manifest.name;
    maintainers = [ "ldeck" ];
    platforms = platforms.darwin ++ platforms.linux;
  };
}
