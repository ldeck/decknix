# Shared fakes for the linux-builder script tests. The fake VM's state lives in
# files: $fake/running (launchd job up) and $fake/up (guest sshd answering).
make_stubs() {
  local fake="$1"
  mkdir -p "$fake/bin"
  cat > "$fake/bin/socat" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" -u "* ]]; then
  echo probe >> "$FAKE/calls"
  [[ -e "$FAKE/up" ]] && printf 'SSH-2.0-OpenSSH_10.2\r\n'
  exit 0
fi
echo "relay $*" >> "$FAKE/calls"
cat
STUB
  cat > "$fake/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  print) [[ -e "$FAKE/running" ]] && echo '	state = running' || echo '	state = not running' ;;
  kickstart)
    echo "kickstart $2" >> "$FAKE/calls"
    touch "$FAKE/running"
    [[ "${NO_BOOT:-0}" == 1 ]] || touch "$FAKE/up" ;;
  kill) echo "kill $2 $3" >> "$FAKE/calls"; rm -f "$FAKE/running" "$FAKE/up" ;;
esac
STUB
  cat > "$fake/bin/lsof" <<'STUB'
#!/usr/bin/env bash
echo "lsof $*" >> "$FAKE/calls"
[[ -e "$FAKE/connections" ]] && echo 4242
exit 0
STUB
  cat > "$fake/bin/ssh" <<'STUB'
#!/usr/bin/env bash
echo "ssh ${*: -2}" >> "$FAKE/calls"
grep -qx 'linux-builder ssh-ed25519 AAAAtest root@nixos' "$FAKE/state/known_hosts" || exit 255
[[ "${STUCK:-0}" == 1 ]] || rm -f "$FAKE/running" "$FAKE/up"
STUB
  cat > "$fake/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exec /bin/sleep "${FAST_SLEEP:-$1}"
STUB
  chmod +x "$fake/bin/"*
}

reset_fake() {
  rm -rf "$FAKE/state" "$FAKE/calls" "$FAKE/running" "$FAKE/up" "$FAKE/connections" "$FAKE/log"
  mkdir -p "$FAKE/state"
  : > "$FAKE/calls"
}

fail() { printf 'FAIL: %s\n' "$*" >&2; printf -- '--- calls\n' >&2; cat "$FAKE/calls" >&2; exit 1; }
