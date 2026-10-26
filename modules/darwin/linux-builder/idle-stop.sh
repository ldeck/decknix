# Powers the on-demand builder VM off gracefully. launchd runs it every few
# minutes with --if-idle, which only stops a VM nothing has used for
# idle_minutes; run by hand (as root) it stops the VM now.
set -u +e -o pipefail

backend_port="${LINUX_BUILDER_BACKEND_PORT:-31023}"
label="${LINUX_BUILDER_LABEL:-org.nixos.linux-builder}"
idle_minutes="${LINUX_BUILDER_IDLE_MINUTES:-20}"
state_dir="${LINUX_BUILDER_STATE_DIR:-/var/lib/linux-builder-on-demand}"
ssh_key="${LINUX_BUILDER_SSH_KEY:-/etc/nix/builder_ed25519}"
host_key_b64="${LINUX_BUILDER_HOST_KEY_B64:-}"
shutdown_timeout="${LINUX_BUILDER_SHUTDOWN_TIMEOUT:-60}"
last_activity="$state_dir/last-activity"

log() { printf '%s idle-stop: %s\n' "$EPOCHSECONDS" "$*" >&2; }

vm_running() {
  launchctl print "system/${label}" 2>/dev/null | grep -q 'state = running'
}

# Both ends of a relayed session (socat and qemu) hold a socket on the
# backend port, so this sees every in-flight build, however long it runs.
has_connections() {
  [[ -n "$(lsof -nP -t "-iTCP:${backend_port}" -sTCP:ESTABLISHED 2>/dev/null)" ]]
}

mark_activity() {
  mkdir -p "$state_dir"
  printf '%s\n' "$EPOCHSECONDS" > "$last_activity"
}

# A guest poweroff flushes ext4 and the qcow2 cleanly; signalling qemu (what
# launchctl kill does) is a power cut. The builder profile ships a polkit rule
# letting the `builder' user power off for exactly this. Goes straight to the
# backend port so stopping never re-triggers the activator.
guest_poweroff() {
  local known_hosts="$state_dir/known_hosts"
  printf 'linux-builder %s\n' "$(printf '%s' "$host_key_b64" | base64 -d)" > "$known_hosts"
  ssh -F /dev/null -n \
    -o BatchMode=yes -o ConnectTimeout=10 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
    -o HostKeyAlias=linux-builder -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$known_hosts" -o IdentitiesOnly=yes \
    -i "$ssh_key" -p "$backend_port" builder@127.0.0.1 systemctl poweroff
}

stop_vm() {
  log "stopping ${label}"
  guest_poweroff || log "guest poweroff failed (exit $?)"
  local waited=0
  while vm_running && (( waited < shutdown_timeout )); do
    sleep 1
    waited=$((waited + 1))
  done
  if vm_running; then
    log "guest still up after ${shutdown_timeout}s; sending SIGTERM to qemu"
    launchctl kill SIGTERM "system/${label}"
  fi
  rm -f "$last_activity"
}

vm_running || exit 0

if [[ "${1:-}" != "--if-idle" ]]; then
  stop_vm
  exit 0
fi

if has_connections; then
  mark_activity
  exit 0
fi

# Started by hand (kickstart) rather than via the activator: start the idle
# clock now instead of stopping a VM someone may be about to use.
if [[ ! -s "$last_activity" ]]; then
  mark_activity
  exit 0
fi

idle_seconds=$((EPOCHSECONDS - $(< "$last_activity")))
if (( idle_seconds >= idle_minutes * 60 )); then
  log "idle for ${idle_seconds}s (limit ${idle_minutes}m)"
  stop_vm
fi
