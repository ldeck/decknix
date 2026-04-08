{ lib, rustPlatform, ... }:

let
  manifest = (lib.importTOML ./Cargo.toml).package;

in
rustPlatform.buildRustPackage {
  pname = manifest.name;
  version = manifest.version;

  src = ./.;

  cargoHash = "sha256-D4qUKLz6bhjBmnNOMWLrdhlLvSCC+yPYvP+y4QHf4vo=";

  meta = with lib; {
    description = "Nix-aware macOS application launcher";
    mainProgram = manifest.name;
    maintainers = [ "ldeck" ];
    platforms = platforms.darwin;
  };
}
