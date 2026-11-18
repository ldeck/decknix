# Build tests for the iap-proxy bind-address patch (pkgs/iap-proxy).
#
# The real source is a private flake input, so these build the package from
# small fixture trees under tests/fixtures/iap-proxy that mimic the shape of
# upstream's run():
#
#   exposed         hardcoded host="0.0.0.0": must be rewritten to read IAP_PROXY_HOST
#                   with a loopback default.
#   upstream-fixed  already reads IAP_PROXY_HOST with a loopback default: accepted as is.
#   reshaped        binds all interfaces in a shape the patch does not know:
#                   the build must fail, never ship an exposed proxy.
#
#   nix build .#checks.<system>.iap-proxy-bind
{ pkgs }:

let
  build = fixture: pkgs.callPackage ../pkgs/iap-proxy/default.nix {
    iap-proxy-src = ./fixtures/iap-proxy + "/${fixture}";
  };

  exposed = build "exposed";
  upstreamFixed = build "upstream-fixed";
  reshaped = pkgs.testers.testBuildFailure (build "reshaped");
in
pkgs.runCommand "iap-proxy-bind-check" { } ''
  set -euo pipefail
  main=$(echo ${exposed}/lib/python3*/site-packages/iap_proxy/main.py)
  grep -qF 'host=os.getenv("IAP_PROXY_HOST", "127.0.0.1")' "$main"
  grep -qx 'import os' "$main"
  if grep -qF '0.0.0.0' "$main"; then
    echo "exposed fixture still binds 0.0.0.0" >&2
    exit 1
  fi

  grep -qF 'getenv("IAP_PROXY_HOST", "127.0.0.1")' \
    ${upstreamFixed}/lib/python3*/site-packages/iap_proxy/main.py

  grep -qF 'bind-address patch target not found' ${reshaped}/testBuildFailure.log

  touch $out
''
