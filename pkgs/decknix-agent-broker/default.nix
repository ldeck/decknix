{ lib, rustPlatform, ... }:

let
  manifest = (lib.importTOML ./Cargo.toml).package;

in
rustPlatform.buildRustPackage {
  pname = manifest.name;
  version = manifest.version;

  src = ./.;

  # Per-crate fetchurl FODs via the lockfile (see decknix-hub for the rationale:
  # avoids crates.io rate-limiting on the single-staging fetcher).
  cargoLock.lockFile = ./Cargo.lock;

  meta = with lib; {
    description = "Pipe-clean ACP broker — holds an agent bridge, relays to attaching clients over a unix socket (#151)";
    mainProgram = manifest.name;
    maintainers = [ "ldeck" ];
    platforms = platforms.darwin ++ platforms.linux;
  };
}
