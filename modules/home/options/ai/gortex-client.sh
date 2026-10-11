#!/usr/bin/env bash
# The MCP client every agent launches.  Two gortex defaults are wrong here:
#
#   - With no daemon reachable, a client STARTS ONE (GORTEX_AUTOSTART is on by
#     default).  launchd owns the daemon, so a client that connects in the
#     seconds launchd takes to restart it would spawn a rival.  Measured in a
#     scratch home: `gortex mcp --proxy' with no daemon detached its own.
#   - With autostart off and no daemon, the client exits at once (rc=1), so a
#     session started in that window never gets gortex: Claude marks the
#     server failed and Pi's extension tells the agent to ask for /reload.
#
# So wait for launchd's socket, then connect with autostart off.  Once
# connected, `--proxy' rides out daemon restarts on its own: measured, the
# same client reconnected after a kill and restart with no session restart.
set -uo pipefail

socket="$HOME/.gortex/cache/daemon.sock"
for ((i = 0; i < ${GORTEX_CLIENT_WAIT_SECS:-20} * 2; i++)); do
  [[ -S "$socket" ]] && break
  sleep 0.5
done

args=()
for a in "$@"; do
  [[ "$a" == --proxy ]] || args+=("$a")
done

export GORTEX_AUTOSTART=0
exec "$GORTEX_PACKAGE_BIN" mcp --proxy "${args[@]}"
