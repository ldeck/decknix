{ lib, python3Packages, iap-proxy-src, ... }:

let
  # setproctitle tests segfault on macOS with Python 3.13 — skip them
  py3 = python3Packages.override {
    overrides = _final: prev: {
      setproctitle = prev.setproctitle.overridePythonAttrs {
        doCheck = false;
      };
    };
  };
in
py3.buildPythonApplication rec {
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

  build-system = [ py3.hatchling ];

  dependencies = with py3; [
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
