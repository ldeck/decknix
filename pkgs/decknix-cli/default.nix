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
  cargoHash = "sha256-GXgDhPvXf6qnKHUq2U0L2v8/z09CQVoi5U5CvkUu/EM=";

  # Tests require git for classify_drift_covers_all_branches
  nativeCheckInputs = [ git ];

  meta = with lib; {
    description = "The Decknix CLI Manager";
    mainProgram = manifest.name;
    maintainers = [ "ldeck" ];
  };
}
