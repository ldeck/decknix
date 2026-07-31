#!/usr/bin/env bash
# decknix-agent-broker-attach — spawn-or-attach a brokered ACP bridge (#151 M3).
#
# acp.el runs this as its client `:command'.  It gives the caller a clean stdio
# pipe to the broker, spawning the broker (which holds the real bridge, detached
# out of Emacs' process tree via the broker's own `--daemonize') on the FIRST
# attach and just re-attaching on every reconnect.  So the bridge — and the
# running agent turn — survives Emacs dying, `decknix switch', and crashes;
# brokering is invisible to acp.el.
#
# Usage:
#   decknix-agent-broker-attach <session-key> -- <bridge-cmd> [args...]
#
# <session-key> keys the socket + registry entry; the same key reattaches to the
# same live bridge.  Everything after `--' is the ACP bridge acp.el would
# otherwise have spawned directly (e.g. `claude-agent-acp').

set -euo pipefail

key="${1:?session key required}"
shift
if [ "${1:-}" = "--" ]; then shift; fi
if [ "$#" -lt 1 ]; then
  echo "usage: decknix-agent-broker-attach KEY -- BRIDGE-CMD [args...]" >&2
  exit 2
fi

reg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/decknix/agent-sockets"
mkdir -p "$reg_dir"
sock="$reg_dir/$key.sock"
pidf="$sock.pid"
log="$reg_dir/$key.log"

# Live if the broker's pidfile names a running process. A broker killed with
# SIGKILL leaves a stale socket/pidfile, which we clear before respawning.
if ! { [ -f "$pidf" ] && kill -0 "$(cat "$pidf" 2>/dev/null || echo -1)" 2>/dev/null; }; then
  rm -f "$sock" "$pidf"
  # `--daemonize' forks the broker into its own session and the launching
  # process returns immediately, so no `&' is needed; the daemon writes $pidf
  # once it has bound the socket.
  decknix-agent-broker --daemonize \
    --socket "$sock" --session-id "$key" --log "$log" -- "$@" \
    </dev/null >>"$log.broker" 2>&1 || true
  for _ in $(seq 1 50); do
    [ -S "$sock" ] && break
    sleep 0.1
  done
  # Registry entry the sidebar/CLI can list sessions from without connecting.
  bpid="$(cat "$pidf" 2>/dev/null || echo 0)"
  printf '{"sid":"%s","socket":"%s","pid":%s,"cwd":"%s","created":"%s","bridge":"%s"}\n' \
    "$key" "$sock" "$bpid" "$PWD" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" \
    >"$reg_dir/$key.json"
fi

exec socat - "UNIX-CONNECT:$sock"
