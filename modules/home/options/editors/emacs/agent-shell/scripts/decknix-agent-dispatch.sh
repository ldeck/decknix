#!/usr/bin/env bash
# decknix-agent-dispatch: hand ONE prompt to ONE live agent-shell session.
#
# Sender half of the explicit-approval dispatcher (receiver:
# agent-shell/dispatch/decknix-agent-dispatch.el).  `send` only drops a private
# request file; it never contacts Emacs, never attaches to a session and never
# resumes one.  Nothing is delivered unless the user has turned on
# `decknix-agent-dispatch-mode' in Emacs, and a request expires on its own.
#
#   send --session TARGET (--prompt-file FILE | --prompt-stdin) [--ttl SECONDS]
#                  TARGET: full session UUID, or a tag, buffer name or id
#                  prefix that `decknix session find --live` resolves to one
#   status ID      exit 0 accepted, 10 pending/in-flight, 11 not delivered,
#                  12 unknown outcome, 2 no such request
#   cancel ID      withdraw a request that has not been claimed yet
#   sweep          settle expired, undelivered requests
#   list           ids and states (never prompt text)
#   paths          print the state directory

state_dir="${DECKNIX_AGENT_DISPATCH_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/decknix/agent-dispatch}"
max_ttl=900
default_ttl=120
max_bytes=65536
uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
subdirs=(pending inflight receipts tmp)

die() { echo "decknix-agent-dispatch: $*" >&2; exit "${2:-1}"; }

usage() {
  cat >&2 <<'USAGE'
usage: decknix-agent-dispatch COMMAND
  send --session TARGET (--prompt-file FILE | --prompt-stdin) [--ttl SECONDS]
              TARGET: full session UUID, or a tag, buffer name or id prefix
              that "decknix session find --live" resolves to one session
  status ID   exit 0 accepted, 10 pending/in-flight, 11 not delivered,
              12 unknown outcome, 2 no such request
  cancel ID   withdraw a request that has not been claimed yet
  sweep       settle expired, undelivered requests
  list        ids and states (never prompt text)
  paths       print the state directory
USAGE
  exit 2
}

check_id() {
  [[ $1 =~ $uuid_re ]] || die "not a full lowercase UUID: $1" 2
}

ensure_dirs() {
  umask 077
  local d
  for d in "" "${subdirs[@]}"; do
    [[ -e ${state_dir%/}/$d ]] || mkdir -p "${state_dir%/}/$d"
  done
}

check_dirs() {
  local d p
  for d in "" "${subdirs[@]}"; do
    p="$state_dir/$d"
    p="${p%/}"
    [[ -d $p && ! -L $p ]] || die "$p is not a real directory"
    [[ $(stat -c '%a %u' "$p") == "700 $(id -u)" ]] ||
      die "$p must be mode 700 and owned by you"
  done
}

new_id() {
  local h
  h="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s-%s-4%s-%s%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" \
    "$(printf '%x' $(( 8 + 0x${h:16:1} % 4 )))" "${h:17:3}" "${h:20:12}"
}

# Atomic no-clobber publish: a hard link fails if the target exists.
publish() { # tmpfile target
  ln "$1" "$2" 2>/dev/null
  local rc=$?
  rm -f "$1"
  return $rc
}

write_receipt() { # id session state reason
  local tmp
  tmp="$(mktemp "$state_dir/tmp/receipt.XXXXXX")"
  jq -n --arg id "$1" --arg sid "$2" --arg state "$3" --arg reason "$4" \
    --argjson at "$(date +%s)" \
    '{v:1,id:$id,state:$state,at:$at}
     + (if $sid == "" then {} else {session_id:$sid} end)
     + (if $reason == "" then {} else {reason:$reason} end)' >"$tmp"
  chmod 600 "$tmp"
  publish "$tmp" "$state_dir/receipts/$1.json"
}

cmd_send() {
  local sid="" pfile="" use_stdin=0 ttl="$default_ttl" tmp_prompt=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session)
        [[ -z $sid ]] || die "--session given twice: exactly one session per request" 2
        sid="${2:-}"; shift 2 ;;
      --prompt-file) pfile="${2:-}"; shift 2 ;;
      --prompt-stdin) use_stdin=1; shift ;;
      --ttl) ttl="${2:-}"; shift 2 ;;
      *) die "unknown option: $1" 2 ;;
    esac
  done
  [[ -n $sid ]] || die "--session UUID is required" 2
  if ! [[ $sid =~ $uuid_re ]]; then
    # A tag, buffer name or id prefix: resolve it with the shared resolver,
    # which prints the matches or closest sessions itself when it cannot.
    command -v decknix >/dev/null ||
      die "--session must be a full lowercase session UUID (decknix is not on PATH to resolve '$sid')" 2
    local resolved rc
    resolved="$(decknix session find --live --id -- "$sid")"
    rc=$?
    (( rc == 0 )) || die "cannot resolve --session '$sid' to one live session" "$rc"
    sid="$resolved"
  fi
  if ! [[ $ttl =~ ^[0-9]+$ ]] || (( ttl < 1 || ttl > max_ttl )); then
    die "--ttl must be 1..$max_ttl seconds" 2
  fi
  if [[ -n $pfile && $use_stdin -eq 1 ]] || [[ -z $pfile && $use_stdin -eq 0 ]]; then
    die "give exactly one of --prompt-file or --prompt-stdin" 2
  fi

  ensure_dirs
  check_dirs
  if [[ $use_stdin -eq 1 ]]; then
    tmp_prompt="$(mktemp "$state_dir/tmp/prompt.XXXXXX")"
    cat >"$tmp_prompt"
    pfile="$tmp_prompt"
  fi
  [[ -f $pfile && -r $pfile ]] || { rm -f "$tmp_prompt"; die "cannot read prompt file: $pfile" 2; }

  local size
  size="$(wc -c <"$pfile" | tr -d ' ')"
  if (( size > max_bytes )); then rm -f "$tmp_prompt"; die "prompt is $size bytes; limit is $max_bytes" 2; fi
  local trimmed
  trimmed="$(tr -d '[:space:]' <"$pfile")"
  if [[ -z $trimmed ]]; then rm -f "$tmp_prompt"; die "prompt is empty" 2; fi
  case "$(tr '[:upper:]' '[:lower:]' <<<"$trimmed")" in
    help|clear|config) rm -f "$tmp_prompt"; die "reserved shell-maker word, not a prompt" 2 ;;
  esac

  local id now hash tmp
  id="$(new_id)"
  now="$(date +%s)"
  hash="$(sha256sum <"$pfile" | cut -d' ' -f1)"
  tmp="$(mktemp "$state_dir/tmp/request.XXXXXX")"
  jq -n --arg id "$id" --arg sid "$sid" --rawfile prompt "$pfile" --arg hash "$hash" \
    --argjson created "$now" --argjson expires "$(( now + ttl ))" \
    '{v:1,id:$id,session_id:$sid,prompt:$prompt,prompt_sha256:$hash,
      created_at:$created,expires_at:$expires}' >"$tmp"
  rm -f "$tmp_prompt"
  if [[ "$(jq -j .prompt "$tmp" | sha256sum | cut -d' ' -f1)" != "$hash" ]]; then
    rm -f "$tmp"
    die "prompt is not valid UTF-8 text" 2
  fi
  chmod 600 "$tmp"
  publish "$tmp" "$state_dir/pending/$id.json" || die "could not publish the request"
  echo "$id"
  echo "queued for session $sid; expires in ${ttl}s; delivered only while decknix-agent-dispatch-mode is on in Emacs" >&2
  echo "check with: decknix-agent-dispatch status $id" >&2
}

cmd_status() {
  [[ $# -eq 1 ]] || usage
  local id="$1"
  check_id "$id"
  local f="$state_dir/receipts/$id.json"
  if [[ -f $f ]]; then
    jq -c . "$f"
    case "$(jq -r .state "$f")" in
      accepted) exit 0 ;;
      unknown) exit 12 ;;
      *) exit 11 ;;
    esac
  fi
  if [[ -f $state_dir/inflight/$id.json || -f $state_dir/inflight/$id.attempt ]]; then
    if [[ -f $state_dir/inflight/$id.attempt ]]; then
      echo "in-flight: submit attempted, outcome not yet recorded (treat as unknown if it persists)"
      exit 12
    fi
    echo "in-flight: claimed by the receiver, waiting to send"
    exit 10
  fi
  if [[ -f $state_dir/pending/$id.json ]]; then
    local left
    left="$(( $(jq .expires_at "$state_dir/pending/$id.json" 2>/dev/null || echo 0) - $(date +%s) ))"
    if (( left > 0 )); then
      echo "pending: ${left}s left; not claimed (is decknix-agent-dispatch-mode on?)"
      exit 10
    fi
    echo "expired-undelivered: never claimed; run 'decknix-agent-dispatch sweep'"
    exit 11
  fi
  echo "no such request: $id" >&2
  exit 2
}

cmd_cancel() {
  [[ $# -eq 1 ]] || usage
  local id="$1"
  check_id "$id"
  [[ -d $state_dir/pending ]] || die "no such request: $id"
  if mv "$state_dir/pending/$id.json" "$state_dir/inflight/$id.json" 2>/dev/null; then
    write_receipt "$id" "" cancelled "cancelled-by-cli"
    rm -f "$state_dir/inflight/$id.json"
    echo "cancelled $id"
  else
    die "too late or unknown: $id is not pending (see: decknix-agent-dispatch status $id)"
  fi
}

cmd_sweep() {
  [[ -d $state_dir/pending ]] || { echo "nothing to sweep"; return 0; }
  local f id exp now swept=0
  now="$(date +%s)"
  for f in "$state_dir"/pending/*.json; do
    [[ -e $f ]] || continue
    id="$(basename "$f" .json)"
    [[ $id =~ $uuid_re ]] || continue
    exp="$(jq -r '.expires_at // 0' "$f" 2>/dev/null || echo 0)"
    if (( exp <= now )) && mv "$f" "$state_dir/inflight/$id.json" 2>/dev/null; then
      write_receipt "$id" "" expired "swept-by-cli"
      rm -f "$state_dir/inflight/$id.json"
      swept=$(( swept + 1 ))
    fi
  done
  find "$state_dir/tmp" -type f -mmin +60 -delete 2>/dev/null || true
  echo "swept $swept expired request(s)"
}

cmd_list() {
  local sub f
  for sub in pending inflight; do
    for f in "$state_dir/$sub"/*.json; do
      [[ -e $f ]] || continue
      printf '%s\t%s\t%s\n' "$sub" "$(basename "$f" .json)" \
        "$(jq -r '.session_id // "-"' "$f" 2>/dev/null || echo -)"
    done
  done
  for f in "$state_dir"/receipts/*.json; do
    [[ -e $f ]] || continue
    jq -r '[.state, .id, (.session_id // "-"), (.reason // "")] | @tsv' "$f" 2>/dev/null || true
  done
}

cmd="${1:-}"
[[ $# -gt 0 ]] && shift
case "$cmd" in
  send) cmd_send "$@" ;;
  status) cmd_status "$@" ;;
  cancel) cmd_cancel "$@" ;;
  sweep) cmd_sweep ;;
  list) cmd_list ;;
  paths) echo "$state_dir" ;;
  *) usage ;;
esac
