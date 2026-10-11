#!/usr/bin/env bash
# Pi's extension calls the gortex binary for three things.  Route each one:
#
#   daemon start --detach   suppressed: launchd owns the daemon
#   mcp ...                 the shared client launcher, so Pi gets the same
#                           wait-then-proxy behaviour as every other agent.
#                           Plain `mcp' reconnected too, but its first call
#                           after a restart was refused as reorient_then_retry,
#                           which the extension surfaces as "run /reload".
#   hook ...                the shared filter, so Pi is not told to stop
set -euo pipefail

if [[ "$#" -eq 3 && "$1" == daemon && "$2" == start && "$3" == --detach ]]; then
  exit 0
fi
case "${1:-}" in
  mcp)  shift; exec "$GORTEX_CLIENT" "$@" ;;
  hook) shift; exec "$GORTEX_HOOK" "$@" ;;
esac
exec "$GORTEX_PACKAGE_BIN" "$@"
