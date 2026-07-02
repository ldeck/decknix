{ lib, buildNpmPackage, fetchFromGitHub, nodejs_22 }:

buildNpmPackage rec {
  pname = "claude-agent-acp";
  version = "0.54.1";

  # Requires Node >= 22 (per package.json engines field)
  nodejs = nodejs_22;

  src = fetchFromGitHub {
    owner = "agentclientprotocol";
    repo = "claude-agent-acp";
    rev = "v${version}";
    hash = "sha256-Ykwd1/RH9L/wSEJgc2HdhpDiIiE7wH19v/DQgpFKXFI=";
  };

  npmDepsHash = "sha256-S3bpXFcOW6ZhM7KJ9hVrKIwT4eKg5oqmmloeCx6YnPw=";

  meta = with lib; {
    description = "ACP (Agent Client Protocol) adapter for Anthropic Claude Code";
    homepage = "https://github.com/agentclientprotocol/claude-agent-acp";
    license = licenses.mit;
    mainProgram = "claude-agent-acp";
    platforms = platforms.unix;
  };
}
