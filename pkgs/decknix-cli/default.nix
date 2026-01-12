{ lib, rustPlatform, ... }:

rustPlatform.buildRustPackage {
  pname = "decknix";
  version = "0.1.0";

  # Point to your actual Rust source directory
  src = ../../cli;

  # This hash locks dependencies.
  # Set to lib.fakeHash initially; Nix will error and give you the real one.
  cargoHash = "sha256-o+XIfc26NMIdnC7SAn3QMXIq78CME6cyotOm18VMCD4="; # use lib.fakeHash for discovery

  meta = with lib; {
    description = "The Decknix CLI Manager";
    mainProgram = "decknix";
    maintainers = [ "ldeck" ];
  };
}
