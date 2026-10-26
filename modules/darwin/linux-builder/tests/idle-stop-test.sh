#!/usr/bin/env bash
# Run: bash modules/darwin/linux-builder/tests/idle-stop-test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../idle-stop.sh"
source "$here/stubs.sh"
FAKE="$(mktemp -d)"
export FAKE
trap 'rm -rf "$FAKE"' EXIT
make_stubs "$FAKE"

run_stop() {
  PATH="$FAKE/bin:$PATH" FAST_SLEEP=0 \
    LINUX_BUILDER_STATE_DIR="$FAKE/state" LINUX_BUILDER_IDLE_MINUTES=20 \
    LINUX_BUILDER_SHUTDOWN_TIMEOUT=3 \
    LINUX_BUILDER_HOST_KEY_B64="$(printf 'ssh-ed25519 AAAAtest root@nixos\n' | base64)" \
    bash "$script" "$@" 2>>"$FAKE/log"
}

ago() { printf '%s\n' "$((EPOCHSECONDS - $1 * 60))" > "$FAKE/state/last-activity"; }

# Active connection: never stop, and refresh the idle clock.
reset_fake
touch "$FAKE/running" "$FAKE/up" "$FAKE/connections"
ago 60
run_stop --if-idle
[[ -e "$FAKE/running" ]] || fail "stopped a VM with a live connection"
(( EPOCHSECONDS - $(< "$FAKE/state/last-activity") < 5 )) || fail "live connection did not refresh activity"

# Idle beyond the threshold: graceful guest poweroff, no qemu signal.
reset_fake
touch "$FAKE/running" "$FAKE/up"
ago 21
run_stop --if-idle
[[ ! -e "$FAKE/running" ]] || fail "idle VM left running"
grep -qx 'ssh systemctl poweroff' "$FAKE/calls" || fail "no guest poweroff"
! grep -q '^kill' "$FAKE/calls" || fail "signalled qemu after a clean poweroff"
[[ ! -e "$FAKE/state/last-activity" ]] || fail "activity marker survived the stop"

# Recently active: leave it alone.
reset_fake
touch "$FAKE/running" "$FAKE/up"
ago 5
run_stop --if-idle
[[ -e "$FAKE/running" ]] || fail "stopped a recently active VM"
! grep -q ssh "$FAKE/calls" || fail "contacted a recently active VM"

# Started by hand, never seen by the activator: start the clock, do not stop.
reset_fake
touch "$FAKE/running" "$FAKE/up"
run_stop --if-idle
[[ -e "$FAKE/running" ]] || fail "stopped a VM with no activity record"
[[ -s "$FAKE/state/last-activity" ]] || fail "idle clock not started"

# VM not running: nothing to do.
reset_fake
run_stop --if-idle
[[ ! -s "$FAKE/calls" ]] || fail "acted on a stopped VM"

# Guest ignores poweroff: fall back to SIGTERM after the shutdown timeout.
reset_fake
touch "$FAKE/running" "$FAKE/up"
ago 30
STUCK=1 run_stop --if-idle
grep -qx 'kill SIGTERM system/org.nixos.linux-builder' "$FAKE/calls" || fail "no SIGTERM fallback"

# Manual stop (no flag) stops even while recently active.
reset_fake
touch "$FAKE/running" "$FAKE/up"
ago 1
run_stop
[[ ! -e "$FAKE/running" ]] || fail "manual stop left VM running"

printf 'linux-builder idle-stop: OK\n'
