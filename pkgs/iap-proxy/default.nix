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

  # Upstream hardcodes `host="0.0.0.0"` in run(), which exposes the proxy
  # (and the IAP identity it injects, with no auth of its own) on every
  # network interface. Bind from $HOST instead, defaulting to loopback.
  #
  # This guard must fail the build rather than degrade silently: if upstream
  # reshapes run() so the literal is gone, an unpatched build could quietly
  # go back to listening on all interfaces. A source that already reads
  # HOST with a loopback default (the upstream fix) is accepted as is; any
  # other shape, or any remaining 0.0.0.0, stops the build.
  postPatch = ''
    main=src/iap_proxy/main.py
    loopbackDefault='getenv("HOST", "127.0.0.1")'
    if grep -qF 'host="0.0.0.0"' "$main"; then
      substituteInPlace "$main" \
        --replace-fail 'host="0.0.0.0"' "host=os.$loopbackDefault" \
        --replace-fail 'import asyncio' $'import asyncio\nimport os'
    elif ! grep -rqF "$loopbackDefault" src/iap_proxy; then
      echo "iap-proxy: bind-address patch target not found in $main and the" >&2
      echo "source does not read HOST with a 127.0.0.1 default; refusing to" >&2
      echo "build a proxy that may listen on all interfaces." >&2
      exit 1
    fi
    if grep -rnF '0.0.0.0' src/iap_proxy; then
      echo "iap-proxy: 0.0.0.0 still present in the source after patching" >&2
      exit 1
    fi
  '';

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
