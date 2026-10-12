"""Tests for claude-wait-guard.py, run by the Nix build.

The cases come from the replay over three weeks of real Bash calls: the
blocks it should make, and the false positives the first version made.
"""
import importlib.util
import json
import os
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("guard", os.path.join(here, "claude-wait-guard.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
v = guard.verdict

BLOCK = [
    "sleep 150; tail -3 /tmp/out",
    "for i in $(seq 1 40); do grep -q done /tmp/x && break; sleep 15; done",
    "until gh pr checks 12; do sleep 30; done",
    "cd ~/Code/upside && ./gradlew :core:test --tests '*Foo*'",
    "timeout 400 nix build .#darwinConfigurations.default.system",
    "decknix wt audit --json > /tmp/a.json",
    "~/Code/nurturecloud/.nc-tools/bin/wait-for-pr-reviews 20861",
    "gh run watch 123",
    "sleep 2m",
]
ALLOW = [
    "sleep 5; git status",
    "for pr in 1 2 3; do gh pr view $pr; sleep 1; done",
    "git log --format='%h %s' -- gradle.properties | head",
    "grep -n 'nix build' modules/*.nix",
    "atlassian-cli jira issue comments add --body 'run decknix switch then sleep 600' X-1",
    "pkill -f \"sleep 1700\"; sleep 1",
    "python3 - <<'EOF'\nimport time\nprint('sleep 900')\nEOF",
    "git commit -q -m 'fix' && git push",
    "./gradlew --version",
]


def test_blocks():
    for cmd in BLOCK:
        assert v(cmd), f"should block: {cmd!r}"


def test_allows():
    for cmd in ALLOW:
        assert v(cmd) is None, f"should allow: {cmd!r} -> {v(cmd)}"


def test_overrides():
    assert v("sleep 300", background=True) is None
    assert v("sleep 300", timeout_ms=600_000) is None
    assert v("sleep 300  # allow-foreground") is None
    assert v("sleep 300", timeout_ms=60_000)


def test_hook_protocol():
    def run(event):
        out = subprocess.run([sys.executable, os.path.join(here, "claude-wait-guard.py")],
                             input=json.dumps(event).encode(), capture_output=True)
        assert out.returncode == 0
        return out.stdout.decode()
    denied = json.loads(run({"tool_name": "Bash", "tool_input": {"command": "sleep 120"}}))
    hso = denied["hookSpecificOutput"]
    assert hso["permissionDecision"] == "deny"
    assert "run_in_background" in hso["permissionDecisionReason"]
    assert run({"tool_name": "Bash", "tool_input": {"command": "ls"}}) == ""
    assert run({"tool_name": "Read", "tool_input": {"file_path": "/x"}}) == ""
    assert run({}) == ""


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
