{ lib, python3Packages, iap-proxy-src, ... }:

python3Packages.buildPythonApplication rec {
  pname = "iap-proxy";
  version = "0.2.0";
  pyproject = true;

  # Source is provided as a flake input (private GitHub repo).
  # In the downstream decknix-config flake.nix:
  #   inputs.iap-proxy-src = {
  #     url = "github:UpsideRealty/experiment-iap-proxy/feature/token-persistence";
  #     flake = false;
  #   };
  src = iap-proxy-src;

  build-system = [ python3Packages.hatchling ];

  dependencies = with python3Packages; [
    fastapi
    uvicorn
    httpx
    google-auth
    requests
    python-dotenv
  ];

  # Tests require network access
  doCheck = false;

  meta = with lib; {
    description = "HTTP proxy with Google IAP authentication for local development";
    homepage = "https://github.com/UpsideRealty/experiment-iap-proxy";
    mainProgram = "iap-proxy";
    maintainers = [ "ldeck" ];
    platforms = platforms.darwin ++ platforms.linux;
  };
}
