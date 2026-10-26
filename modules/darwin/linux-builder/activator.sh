# Spawned by launchd (inetd-style, Wait=false) once per connection to the
# builder's public port, with the accepted socket as stdin/stdout. Anything
# written to stdout before the relay starts would corrupt the SSH stream, so
# diagnostics go to the log only.
set -u +e -o pipefail

backend_port="${LINUX_BUILDER_BACKEND_PORT:-31023}"
label="${LINUX_BUILDER_LABEL:-org.nixos.linux-builder}"
start_timeout="${LINUX_BUILDER_START_TIMEOUT:-120}"
state_dir="${LINUX_BUILDER_STATE_DIR:-/var/lib/linux-builder-on-demand}"
log_file="${LINUX_BUILDER_LOG:-/var/log/linux-builder-activator.log}"

exec 2>>"$log_file"

log() { printf '%s activator[%s]: %s\n' "$EPOCHSECONDS" "$$" "$*" >&2; }

mark_activity() {
  mkdir -p "$state_dir"
  printf '%s\n' "$EPOCHSECONDS" > "$state_dir/last-activity"
}

# qemu's hostfwd accepts TCP as soon as qemu is up, long before the guest's
# sshd is, so an open port proves nothing: only an SSH banner does.
serves_ssh() {
  local banner
  banner="$(socat -T 2 -u "TCP:127.0.0.1:${backend_port},connect-timeout=2" - </dev/null 2>/dev/null | head -c 4)"
  [[ "$banner" == "SSH-" ]]
}

vm_running() {
  launchctl print "system/${label}" 2>/dev/null | grep -q 'state = running'
}

mark_activity

if ! serves_ssh; then
  log "builder not serving SSH; starting ${label}"
  deadline=$((SECONDS + start_timeout))
  # Kickstart inside the loop, not once: a connection that lands while the
  # idle stopper is powering the guest off sees the job still running, and
  # must start it again once that shutdown completes.
  until serves_ssh; do
    if ! vm_running; then
      launchctl kickstart "system/${label}" >&2 || log "kickstart failed"
    fi
    if (( SECONDS >= deadline )); then
      log "builder did not serve SSH within ${start_timeout}s; giving up"
      exit 1
    fi
    sleep 1
  done
  log "builder serving SSH after $((SECONDS))s"
fi

socat STDIO "TCP:127.0.0.1:${backend_port}"
status=$?
mark_activity
exit "$status"
