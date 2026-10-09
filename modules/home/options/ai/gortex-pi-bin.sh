#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 3 && "$1" == daemon && "$2" == start && "$3" == --detach ]]; then
  exit 0
fi
exec "$GORTEX_PACKAGE_BIN" "$@"
