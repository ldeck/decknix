{ lib, rustPlatform, ... }:

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
  cargoHash = "sha256-ZnUDJWLMJutFhm5bDz3D2srPy0WqVmua+uQUqjiWgBA="; # use lib.fakeHash for discovery

  meta = with lib; {
    description = "The Decknix CLI Manager";
    mainProgram = manifest.name;
    maintainers = [ "ldeck" ];
  };
}
