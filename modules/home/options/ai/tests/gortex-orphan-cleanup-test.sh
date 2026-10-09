#!/usr/bin/env bash
set -euo pipefail

script="$(dirname "$0")/../gortex-orphan-cleanup.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
expected=/nix/store/new-gortex-0.64.7/bin/gortex
old=/nix/store/old-gortex-0.63.8/bin/gortex

cat > "$tmp/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '    program = /nix/store/new-gortex-0.64.7/bin/gortex\n    pid = 50\n'
EOF
cat > "$tmp/ps" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -p && "$2" == 50 ]]; then
  printf '/nix/store/new-gortex-0.64.7/bin/gortex daemon start --log-level warn\n'
elif [[ "$1" == -p ]]; then
  printf '/nix/store/old-gortex-0.63.8/bin/gortex daemon start\n'
else
  printf '50 1 501 /nix/store/new-gortex-0.64.7/bin/gortex daemon start --log-level warn\n'
  printf '51 1 501 /nix/store/old-gortex-0.63.8/bin/gortex daemon start\n'
  printf '52 1 501 /nix/store/old-gortex-0.63.8/bin/gortex mcp --proxy\n'
  printf '53 1 502 /nix/store/old-gortex-0.63.8/bin/gortex daemon start\n'
  printf '54 101 501 /nix/store/old-gortex-0.63.8/bin/gortex daemon start\n'
  printf '55 1 501 /nix/store/old-gortex-0.63.8/bin/gortex daemon status\n'
fi
EOF
cat > "$tmp/kill" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SIGNAL_LOG"
EOF
cat > "$tmp/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/launchctl" "$tmp/ps" "$tmp/kill" "$tmp/sleep"

actual="$(PATH="$tmp:$PATH" bash "$script" "$expected" 501 --candidates)"
[[ "$actual" == "51 $old" ]] || { printf 'Unexpected candidates: %s\n' "$actual" >&2; exit 1; }

SIGNAL_LOG="$tmp/signals" PATH="$tmp:$PATH" bash "$script" "$expected" 501
actual="$(< "$tmp/signals")"
[[ "$actual" == $'-TERM 51\n-KILL 51' ]] || { printf 'Unexpected signals: %s\n' "$actual" >&2; exit 1; }

cat > "$tmp/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '    program = /nix/store/old-gortex-0.63.8/bin/gortex\n    pid = 50\n'
EOF
actual="$(PATH="$tmp:$PATH" bash "$script" "$expected" 501 --candidates)"
[[ -z "$actual" ]] || { printf 'Cleaned without managed current daemon: %s\n' "$actual" >&2; exit 1; }
SIGNAL_LOG="$tmp/signals" PATH="$tmp:$PATH" bash "$script" "$expected" 501
[[ "$(< "$tmp/signals")" == $'-TERM 51\n-KILL 51' ]] || { echo 'Signalled without managed current daemon' >&2; exit 1; }

printf 'gortex orphan selection: OK\n'
