#!/usr/bin/env bash
# Tests for decknix-agent-dispatch (the CLI half). Usage: test.sh /path/to/decknix-agent-dispatch
# Touches only a throwaway state dir; it cannot reach Emacs or any session.
set -u
cli="$1"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export DECKNIX_AGENT_DISPATCH_DIR="$root/state"
SID="11111111-2222-4333-8444-555555555555"
fails=0
n=0

ok() { n=$((n + 1)); }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
expect_rc() { # want desc cmd...
  local want="$1" desc="$2"; shift 2
  "$@" >"$root/out" 2>"$root/err"; local rc=$?
  ok
  [[ $rc -eq $want ]] || fail "$desc: rc=$rc want $want ($(cat "$root/err"))"
}
expect_fail() { # desc cmd...
  local desc="$1"; shift
  "$@" >"$root/out" 2>"$root/err"; local rc=$?
  ok
  [[ $rc -ne 0 ]] || fail "$desc: unexpectedly succeeded"
}
count() { find "$DECKNIX_AGENT_DISPATCH_DIR/$1" -type f 2>/dev/null | wc -l | tr -d ' '; }
mode() { stat -c '%a' "$1"; }

printf 'plain prompt\n' >"$root/p.txt"

# A stub `decknix` so target resolution is hermetic: it knows one tag.
mkdir -p "$root/bin"
cat >"$root/bin/decknix" <<STUB
#!/usr/bin/env bash
[[ "\$*" == "session find --live --id -- lane-1" ]] && { echo "$SID"; exit 0; }
echo "no live session matches" >&2; exit 20
STUB
chmod +x "$root/bin/decknix"
export PATH="$root/bin:$PATH"

# read-only commands never create the state dir
"$cli" status "$SID" >/dev/null 2>&1; ok
[[ ! -e $DECKNIX_AGENT_DISPATCH_DIR ]] || fail "status created the state dir"
"$cli" list >/dev/null 2>&1; ok
[[ ! -e $DECKNIX_AGENT_DISPATCH_DIR ]] || fail "list created the state dir"

# a valid send
expect_rc 0 "valid send" "$cli" send --session "$SID" --prompt-file "$root/p.txt"
id="$(cat "$root/out")"
ok; [[ $id =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || fail "id not a v4 uuid: $id"
req="$DECKNIX_AGENT_DISPATCH_DIR/pending/$id.json"
ok; [[ -f $req ]] || fail "no pending file"
ok; [[ $(mode "$req") == 600 ]] || fail "request mode $(mode "$req")"
ok; [[ $(mode "$DECKNIX_AGENT_DISPATCH_DIR") == 700 ]] || fail "state dir mode"
for sub in pending inflight receipts tmp; do
  ok; [[ $(mode "$DECKNIX_AGENT_DISPATCH_DIR/$sub") == 700 ]] || fail "$sub mode"
done
ok; [[ $(jq -r .session_id "$req") == "$SID" ]] || fail "session_id"
ok; [[ $(jq -r .v "$req") == 1 && $(jq -r .id "$req") == "$id" ]] || fail "v/id"
ok; jq -j .prompt "$req" | cmp -s - "$root/p.txt" || fail "prompt bytes"
ok; [[ $(jq -r .prompt_sha256 "$req") == "$(sha256sum <"$root/p.txt" | cut -d' ' -f1)" ]] || fail "hash"
ok; [[ $(( $(jq .expires_at "$req") - $(jq .created_at "$req") )) -eq 120 ]] || fail "default ttl"
ok; [[ $(count tmp) == 0 ]] || fail "tmp not cleaned"

# unicode + stdin round-trips byte-exactly
printf 'héllo ☃ wörld' | "$cli" send --session "$SID" --prompt-stdin --ttl 30 >"$root/out" 2>"$root/err"; ok
id2="$(cat "$root/out")"
ok; [[ $id2 != "$id" ]] || fail "ids not unique"
ok; [[ $(jq -j .prompt "$DECKNIX_AGENT_DISPATCH_DIR/pending/$id2.json") == 'héllo ☃ wörld' ]] || fail "unicode prompt"
ok; [[ $(jq -r .prompt_sha256 "$DECKNIX_AGENT_DISPATCH_DIR/pending/$id2.json") == "$(printf 'héllo ☃ wörld' | sha256sum | cut -d' ' -f1)" ]] || fail "unicode hash"
ok; [[ $(count pending) == 2 ]] || fail "expected 2 pending"

# a tag resolves through `decknix session find`
expect_rc 0 "tag target" "$cli" send --session lane-1 --prompt-file "$root/p.txt"
ok; [[ $(jq -r .session_id "$DECKNIX_AGENT_DISPATCH_DIR/pending/$(cat "$root/out").json") == "$SID" ]] || fail "tag resolved to the wrong session"
expect_rc 20 "unknown tag keeps the resolver's exit code" "$cli" send --session lane-9 --prompt-file "$root/p.txt"

# refusals: nothing written
before="$(count pending)"
expect_fail "short id"        "$cli" send --session "${SID:0:8}" --prompt-file "$root/p.txt"
expect_fail "uppercase id"    "$cli" send --session "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE" --prompt-file "$root/p.txt"
expect_fail "trailing junk"   "$cli" send --session "${SID}x" --prompt-file "$root/p.txt"
expect_fail "no session"      "$cli" send --prompt-file "$root/p.txt"
expect_fail "no prompt"       "$cli" send --session "$SID"
expect_fail "both prompts"    "$cli" send --session "$SID" --prompt-file "$root/p.txt" --prompt-stdin </dev/null
expect_fail "two sessions"    "$cli" send --session "$SID" --session "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" --prompt-file "$root/p.txt"
expect_fail "missing file"    "$cli" send --session "$SID" --prompt-file "$root/none"
printf '  \n' >"$root/blank"
expect_fail "blank prompt"    "$cli" send --session "$SID" --prompt-file "$root/blank"
printf 'Help\n' >"$root/help"
expect_fail "reserved prompt" "$cli" send --session "$SID" --prompt-file "$root/help"
expect_fail "ttl zero"        "$cli" send --session "$SID" --prompt-file "$root/p.txt" --ttl 0
expect_fail "ttl too long"    "$cli" send --session "$SID" --prompt-file "$root/p.txt" --ttl 901
expect_fail "ttl junk"        "$cli" send --session "$SID" --prompt-file "$root/p.txt" --ttl abc
head -c 70000 /dev/zero | tr '\0' a >"$root/big"
expect_fail "oversize"        "$cli" send --session "$SID" --prompt-file "$root/big"
expect_fail "unknown flag"    "$cli" send --session "$SID" --prompt-file "$root/p.txt" --all
expect_fail "unknown command" "$cli" broadcast
ok; [[ $(count pending) == "$before" ]] || fail "a refused send left a request behind"

# unsafe state dir refuses to send
chmod 755 "$DECKNIX_AGENT_DISPATCH_DIR"
expect_fail "loose state dir" "$cli" send --session "$SID" --prompt-file "$root/p.txt"
chmod 700 "$DECKNIX_AGENT_DISPATCH_DIR"

# status
expect_rc 10 "status pending" "$cli" status "$id"
expect_rc 2  "status unknown id" "$cli" status "aaaaaaaa-0000-4000-8000-000000000000"
expect_rc 2  "status bad id" "$cli" status "nope"
write_receipt() { # id state
  jq -n --arg id "$1" --arg s "$2" '{v:1,id:$id,session_id:"x",state:$s,at:1}' >"$DECKNIX_AGENT_DISPATCH_DIR/receipts/$1.json"
}
r1="aaaaaaaa-0000-4000-8000-000000000001"; write_receipt $r1 accepted
r2="aaaaaaaa-0000-4000-8000-000000000002"; write_receipt $r2 rejected
r3="aaaaaaaa-0000-4000-8000-000000000003"; write_receipt $r3 unknown
r4="aaaaaaaa-0000-4000-8000-000000000004"; write_receipt $r4 expired
r5="aaaaaaaa-0000-4000-8000-000000000005"; write_receipt $r5 not-sent
expect_rc 0  "status accepted" "$cli" status $r1
expect_rc 11 "status rejected" "$cli" status $r2
expect_rc 12 "status unknown"  "$cli" status $r3
expect_rc 11 "status expired"  "$cli" status $r4
expect_rc 11 "status not-sent" "$cli" status $r5
inf="aaaaaaaa-0000-4000-8000-000000000006"
echo '{}' >"$DECKNIX_AGENT_DISPATCH_DIR/inflight/$inf.json"
expect_rc 10 "status inflight" "$cli" status $inf
touch "$DECKNIX_AGENT_DISPATCH_DIR/inflight/$inf.attempt"
expect_rc 12 "status inflight after attempt" "$cli" status $inf
rm -f "$DECKNIX_AGENT_DISPATCH_DIR/inflight/$inf".*

# cancel
expect_rc 0 "cancel pending" "$cli" cancel "$id"
ok; [[ ! -e $req ]] || fail "cancelled request still pending"
ok; [[ $(jq -r .state "$DECKNIX_AGENT_DISPATCH_DIR/receipts/$id.json") == cancelled ]] || fail "cancel receipt"
expect_rc 11 "status cancelled" "$cli" status "$id"
expect_fail "cancel twice" "$cli" cancel "$id"
expect_fail "cancel after receipt (claimed elsewhere)" "$cli" cancel $r1

# sweep expires stale pending requests, leaves live ones
stale="$DECKNIX_AGENT_DISPATCH_DIR/pending/$id2.json"
jq '.created_at -= 500 | .expires_at -= 500' "$stale" >"$root/stale" && cat "$root/stale" >"$stale"
expect_rc 11 "status stale pending" "$cli" status "$id2"
expect_rc 0 "sweep" "$cli" sweep
ok; [[ ! -e $stale ]] || fail "sweep left stale request"
ok; [[ $(jq -r .state "$DECKNIX_AGENT_DISPATCH_DIR/receipts/$id2.json") == expired ]] || fail "sweep receipt"
"$cli" send --session "$SID" --prompt-file "$root/p.txt" >"$root/out" 2>/dev/null; live="$(cat "$root/out")"
"$cli" sweep >/dev/null 2>&1
ok; [[ -f $DECKNIX_AGENT_DISPATCH_DIR/pending/$live.json ]] || fail "sweep removed a live request"

expect_rc 0 "list" "$cli" list
expect_rc 0 "paths" "$cli" paths

echo "$n checks, $fails failed"
[[ $fails -eq 0 ]]
