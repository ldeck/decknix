#!/usr/bin/env bash
set -euo pipefail

script="$(dirname "$0")/../gortex-pi-bin.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/gortex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALL_LOG"
EOF
chmod +x "$tmp/gortex"

CALL_LOG="$tmp/calls" GORTEX_PACKAGE_BIN="$tmp/gortex" bash "$script" daemon start --detach
[[ ! -e "$tmp/calls" ]] || { echo 'Pi started an unmanaged daemon' >&2; exit 1; }
CALL_LOG="$tmp/calls" GORTEX_PACKAGE_BIN="$tmp/gortex" bash "$script" mcp
[[ "$(< "$tmp/calls")" == mcp ]] || { echo 'MCP call not forwarded' >&2; exit 1; }
printf 'gortex Pi launch guard: OK\n'
