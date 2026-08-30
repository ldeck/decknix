{ lib, buildNpmPackage, fetchFromGitHub, nodejs_22 }:

buildNpmPackage rec {
  pname = "claude-agent-acp";
  version = "0.64.2";

  # Requires Node >= 22 (per package.json engines field)
  nodejs = nodejs_22;

  src = fetchFromGitHub {
    owner = "agentclientprotocol";
    repo = "claude-agent-acp";
    rev = "v${version}";
    hash = "sha256-EVFfQrUeAyG4NjJDqaebhc4E6LEoHFySwkvEhkdYq00=";
  };

  npmDepsHash = "sha256-gFBPyxtv7u4sa44XXJqdUBZPA1wG2kErO9wNLFjPzmQ=";

  # `replay-user-messages` forces the bridge to reprocess prior user turns on
  # every resume.  That makes saved-session restore expensive and is already
  # redundant for decknix, which restores transcript history in Emacs and uses
  # ACP `session/resume` to restore model context natively.  Strip the flag so
  # resuming a Claude session is as cheap as starting a fresh one.
  postFixup = ''
    bridge="$out/lib/node_modules/@agentclientprotocol/claude-agent-acp/dist/acp-agent.js"
    substituteInPlace "$bridge" \
      --replace '                "replay-user-messages": "",' ""
    if grep -q '"replay-user-messages": ""' "$bridge"; then
      echo "claude-agent-acp: replay-user-messages still present after patch" >&2
      exit 1
    fi
  '';

  meta = with lib; {
    description = "ACP (Agent Client Protocol) adapter for Anthropic Claude Code";
    homepage = "https://github.com/agentclientprotocol/claude-agent-acp";
    license = licenses.mit;
    mainProgram = "claude-agent-acp";
    platforms = platforms.unix;
  };
}
