#!/usr/bin/env bash
set -euo pipefail

expected="$1"
uid="$2"
mode="${3:-cleanup}"
service="gui/$uid/org.nix-community.home.gortex"

if ! state="$(launchctl print "$service" 2>/dev/null)"; then
  exit 0
fi
managed_bin="$(printf '%s\n' "$state" | awk '$1 == "program" && $2 == "=" { print $3; exit }')"
managed_pid="$(printf '%s\n' "$state" | awk '$1 == "pid" && $2 == "=" { print $3; exit }')"
[[ "$managed_bin" == "$expected" && "$managed_pid" =~ ^[0-9]+$ ]] || exit 0
managed_args="$(ps -p "$managed_pid" -o args= -ww 2>/dev/null)" || exit 0
[[ "$managed_args" == "$expected daemon start"* ]] || exit 0

candidates="$(ps -axo pid=,ppid=,uid=,args= -ww | while read -r pid ppid owner binary command action rest; do
  [[ "$pid" =~ ^[0-9]+$ && "$ppid" == 1 && "$owner" == "$uid" ]] || continue
  [[ "$binary" == /nix/store/*-gortex-*/bin/gortex && "$binary" != "$expected" ]] || continue
  [[ "$command" == daemon && "$action" == start ]] || continue
  printf '%s %s\n' "$pid" "$binary"
done)"

[[ -n "$candidates" ]] || exit 0
if [[ "$mode" == --candidates ]]; then
  printf '%s\n' "$candidates"
  exit 0
fi

still_old() {
  local args
  args="$(ps -p "$1" -o args= -ww 2>/dev/null)" || return 1
  [[ "$args" == "$2 daemon start"* ]]
}

while read -r pid binary; do
  if still_old "$pid" "$binary"; then
    printf 'gortex: stopping orphaned daemon %s (%s)\n' "$pid" "$binary"
    env kill -TERM "$pid" 2>/dev/null || true
  fi
done <<< "$candidates"
sleep 3
while read -r pid binary; do
  if still_old "$pid" "$binary"; then
    printf 'gortex: old daemon %s ignored SIGTERM; sending SIGKILL\n' "$pid" >&2
    env kill -KILL "$pid" 2>/dev/null || true
  fi
done <<< "$candidates"
sleep 1
while read -r pid binary; do
  if still_old "$pid" "$binary"; then
    printf 'gortex: orphaned daemon %s is still running\n' "$pid" >&2
    exit 1
  fi
done <<< "$candidates"
