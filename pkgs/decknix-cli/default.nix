{ lib, rustPlatform, git, ... }:

let
  manifest = (lib.importTOML ../../cli/Cargo.toml).package;

in
rustPlatform.buildRustPackage {
  pname = manifest.name;
  version = manifest.version;

  # Point to your actual Rust source directory
  src = ../../cli;

  # This hash locks dependencies.
  # Set to lib.fakeHash initially; Nix will error and give you the real one.
  cargoHash = "sha256-diW/1vnwlt1C3re57EXr+o9ypmcP/8tAar+tDUYLE+M=";

  # Tests require git for classify_drift_covers_all_branches
  nativeCheckInputs = [ git ];

  meta = with lib; {
    description = "The Decknix CLI Manager";
    mainProgram = manifest.name;
    maintainers = [ "ldeck" ];
  };
}
