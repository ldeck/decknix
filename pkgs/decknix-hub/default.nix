{ lib, rustPlatform, ... }:

let
  manifest = (lib.importTOML ./Cargo.toml).package;

in
rustPlatform.buildRustPackage {
  pname = manifest.name;
  version = manifest.version;

  src = ./.;

  cargoHash = "sha256-loixXl17H0/99CCBFPSsBWeg5Xxze6bEZOlnOkG/zGU=";

  meta = with lib; {
    description = "Background work-item aggregator — polls GitHub, Jira, CI/CD";
    mainProgram = manifest.name;
    maintainers = [ "ldeck" ];
    platforms = platforms.darwin ++ platforms.linux;
  };
}
