#!/usr/bin/env bash
# Run: bash modules/darwin/linux-builder/tests/activator-test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../activator.sh"
source "$here/stubs.sh"
FAKE="$(mktemp -d)"
export FAKE
trap 'rm -rf "$FAKE"' EXIT
make_stubs "$FAKE"

run_activator() {
  PATH="$FAKE/bin:$PATH" \
    LINUX_BUILDER_STATE_DIR="$FAKE/state" LINUX_BUILDER_LOG="$FAKE/log" \
    LINUX_BUILDER_START_TIMEOUT="${TIMEOUT:-10}" \
    bash "$script"
}

# VM down: kickstart, wait for the banner, then relay the client's bytes.
reset_fake
out="$(printf 'client-bytes' | run_activator)" || fail "VM-down run exited non-zero"
[[ "$out" == client-bytes ]] || fail "relay did not pass bytes through: '$out'"
grep -qx 'kickstart system/org.nixos.linux-builder' "$FAKE/calls" || fail "VM down but not kickstarted"
[[ "$(tail -n1 "$FAKE/calls")" == "relay STDIO TCP:127.0.0.1:31023" ]] || fail "did not relay to backend last"
[[ -s "$FAKE/state/last-activity" ]] || fail "activity not recorded"

# VM already up: relay only, no kickstart, nothing but relayed bytes on stdout.
reset_fake
touch "$FAKE/running" "$FAKE/up"
out="$(printf 'x' | run_activator)" || fail "VM-up run exited non-zero"
[[ "$out" == x ]] || fail "unexpected stdout with VM up: '$out'"
! grep -q kickstart "$FAKE/calls" || fail "kickstarted a VM that was already serving"
[[ "$(grep -c probe "$FAKE/calls")" == 1 ]] || fail "expected a single probe"

# Job running but guest never answers: give up within the timeout, no relay.
reset_fake
if printf 'x' | NO_BOOT=1 TIMEOUT=2 run_activator >/dev/null; then
  fail "timed-out start exited zero"
fi
! grep -q relay "$FAKE/calls" || fail "relayed to a builder that never came up"
grep -q 'giving up' "$FAKE/log" || fail "timeout not logged"

# A connection that races a shutdown (job up, guest gone) restarts the job
# once launchd reports it stopped.
reset_fake
touch "$FAKE/running"
( /bin/sleep 1.5; rm -f "$FAKE/running" ) &
printf 'x' | TIMEOUT=10 run_activator >/dev/null || fail "racing-shutdown run failed"
wait
grep -q kickstart "$FAKE/calls" || fail "did not restart after a racing shutdown"

printf 'linux-builder activator: OK\n'
