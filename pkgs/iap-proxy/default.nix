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

  # Source is provided as a flake input (a private GitHub repo), e.g. in an
  # org config flake.nix:
  #   inputs.iap-proxy-src = {
  #     url = "github:my-org/iap-proxy";
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
    mainProgram = "iap-proxy";
    maintainers = [ "ldeck" ];
    platforms = platforms.darwin ++ platforms.linux;
  };
}
