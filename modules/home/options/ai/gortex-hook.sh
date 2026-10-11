#!/usr/bin/env bash
# Run `gortex hook' with its output made safe to inject into an agent.
#
# gortex 0.64.7 hardcodes, in every hook mode including `enrich':
#
#   "Native Gortex MCP is mandatory for this profile. If a referenced Gortex
#    tool is missing ... surface a Gortex MCP integration failure to the user
#    and stop. Do not start a daemon or use any CLI/shell fallback."
#
# and, at session start with the daemon unreachable, "stop indexed code
# operations and report it".  Pi sessions obeyed that literally and refused
# to work: four of seventeen in a month stopped with "I won't fall back to
# repo scans".  The graph is meant to be the better path when it is there,
# not a precondition for working at all.
#
# So: say nothing when the daemon is unreachable, drop the stop instruction,
# and present a "BLOCKED" read (which `enrich' does not actually block) as a
# suggestion.  Always exit 0: a hook must never fail the tool it decorates.
set -uo pipefail

out=$(GORTEX_AUTOSTART=0 "$GORTEX_PACKAGE_BIN" hook "$@" 2>/dev/null) || exit 0

case "$out" in
  *unreachable*) exit 0 ;;
esac

printf '%s' "$out" | perl -0pe '
  s/(?:\\n|\n)[ \t]*-?[ \t]*Native Gortex MCP is mandatory for this profile\..*?fallback\.//gs;
  s/\[Gortex\] BLOCKED: /[Gortex] The graph has this: /g;
'
exit 0
