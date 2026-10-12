"""Claude Code PreToolUse hook: keep waiting out of the foreground.

Over three weeks of Claude sessions, 1,458 Bash calls slept in the
foreground (33 hours of sessions doing nothing) and 232 more ran into the
2-minute tool timeout and were usually re-run (~7.7 hours).  The workspace
rule already says waiting belongs in a background task that notifies on
completion; agents ignored it.  This enforces it.

Blocked when the call is NOT backgrounded:
  - a `sleep` of 30s or more, or a loop that sleeps 5s or more a pass
  - a command known to run for minutes: gradle, nix build, decknix
    switch/update, `decknix wt audit`, the PR-wait scripts

Not `git commit' in the build-guarded repos, though it can take minutes:
replayed, 90 of 105 such commits finished in under 20 seconds on a cached
build, so blocking them cost more than it saved.

Allowed regardless: `run_in_background`, an explicit tool timeout of at
least 5 minutes (a deliberate wait), or `# allow-foreground` in the
command.  The reason says how to background the call, so the agent can
retry it correctly rather than give up.
"""

import json
import re
import sys

LONG_SLEEP = 30
POLL_SLEEP = 5
EXPLICIT_WAIT_MS = 300_000

HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n.*?\n\s*\2\s*(?:\n|$)", re.S)
QUOTED = re.compile(r"'[^']*'|\"(?:\\.|[^\"\\])*\"")
SEGMENT = re.compile(r"(?:&&|\|\||[;&|\n(){}]|\b(?:do|then|else|elif)\b)")
ASSIGN = re.compile(r"^\w+=\S*$")

# Matched against a segment's leading words only.  The first version matched
# anywhere in the command and blocked `git log -- gradle.properties', a grep
# for "nix build", and a Jira comment mentioning `decknix switch': replayed
# over three weeks, ~93 of its 128 command blocks were calls that finished
# in under 20 seconds.
LONG_COMMANDS = [
    (re.compile(r"^(?:\S*/)?gradlew?\b(?!.*\s--?(?:version|help)\b)"), "a Gradle build"),
    (re.compile(r"^nix\s+(?:build|flake\s+check)\b"), "a Nix build"),
    (re.compile(r"^(?:sudo\s+)?darwin-rebuild\b"), "a system rebuild"),
    (re.compile(r"^decknix\s+(?:switch|update)\b"), "a decknix switch or update"),
    (re.compile(r"^decknix\s+wt\s+audit\b"), "a worktree audit"),
    (re.compile(r"^(?:\S*/)?(?:wait-for-pr-reviews|pr-poll-reviews)\b"), "a PR review wait"),
    (re.compile(r"^gh\s+(?:run\s+watch\b|pr\s+checks\b.*--watch\b)"), "a CI watch"),
]

SLEEP = re.compile(r"^sleep\s+(\d+(?:\.\d+)?)([smh]?)$")
LOOP = re.compile(r"\b(?:while|until|for)\b.*?\bdo\b", re.S)


def seconds(value, unit):
    return float(value) * {"": 1, "s": 1, "m": 60, "h": 3600}[unit]


def segments(command):
    """Yield each simple command's words, with quoted text and heredoc
    bodies removed, so only what the shell would RUN is examined."""
    text = QUOTED.sub("''", HEREDOC.sub("\n", command))
    for part in SEGMENT.split(text):
        words = part.split()
        while words and (ASSIGN.match(words[0]) or words[0] in ("time", "exec", "command", "nohup")):
            words = words[1:]
        if words and words[0] == "timeout":
            words = [w for w in words[1:] if not w.startswith("-")][1:]
        if words:
            yield " ".join(words)


def verdict(command, cwd="", background=False, timeout_ms=None):
    """Return a reason to refuse COMMAND, or None to let it run."""
    if background or "# allow-foreground" in command:
        return None
    if timeout_ms and timeout_ms >= EXPLICIT_WAIT_MS:
        return None

    segs = list(segments(command))
    sleeps = [seconds(*m.groups()) for m in (SLEEP.match(s) for s in segs) if m]
    looped = bool(LOOP.search(QUOTED.sub("''", HEREDOC.sub("\n", command))))
    # A short sleep between iterations is rate limiting, not waiting.
    if sleeps and looped and max(sleeps) >= POLL_SLEEP:
        return "this polls in a loop with `sleep`"
    if sleeps and max(sleeps) >= LONG_SLEEP:
        return f"this sleeps for {int(max(sleeps))}s"

    for seg in segs:
        for pattern, what in LONG_COMMANDS:
            if pattern.search(seg):
                return f"{what} usually outlasts the 2-minute tool timeout"
    return None


ADVICE = (
    "Run it with `run_in_background: true` and carry on; you are notified "
    "when it finishes, so there is nothing to poll.  If you genuinely must "
    "block on it, pass an explicit `timeout` of at least 300000 ms, or add "
    "`# allow-foreground` to the command to say so."
)


def main():
    try:
        event = json.load(sys.stdin)
    except Exception:
        return
    if event.get("tool_name") != "Bash":
        return
    tool_input = event.get("tool_input") or {}
    reason = verdict(
        tool_input.get("command") or "",
        event.get("cwd") or "",
        bool(tool_input.get("run_in_background")),
        tool_input.get("timeout"),
    )
    if reason:
        json.dump({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": f"Not in the foreground: {reason}.  {ADVICE}",
            }
        }, sys.stdout)


if __name__ == "__main__":
    main()
