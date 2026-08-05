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

  meta = with lib; {
    description = "ACP (Agent Client Protocol) adapter for Anthropic Claude Code";
    homepage = "https://github.com/agentclientprotocol/claude-agent-acp";
    license = licenses.mit;
    mainProgram = "claude-agent-acp";
    platforms = platforms.unix;
  };
}
