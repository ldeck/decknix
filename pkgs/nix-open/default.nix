{ lib, rustPlatform, ... }:

let
  manifest = (lib.importTOML ./Cargo.toml).package;

in
rustPlatform.buildRustPackage {
  pname = manifest.name;
  version = manifest.version;

  src = ./.;

  # Use cargoLock so each crate is a separate fixed-output derivation keyed on
  # the checksum in Cargo.lock.  This avoids the single-vendor-staging fetch
  # that crates.io rate-limits, and lets already-cached crates (clap, syn,
  # etc.) be reused without re-downloading.
  cargoLock = {
    lockFile = ./Cargo.lock;
  };

  meta = with lib; {
    description = "Nix-aware macOS application launcher";
    mainProgram = manifest.name;
    maintainers = [ "ldeck" ];
    platforms = platforms.darwin;
  };
}
