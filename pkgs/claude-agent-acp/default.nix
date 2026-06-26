{ lib, buildNpmPackage, fetchFromGitHub, nodejs_22 }:

buildNpmPackage rec {
  pname = "claude-agent-acp";
  version = "0.52.0";

  # Requires Node >= 22 (per package.json engines field)
  nodejs = nodejs_22;

  src = fetchFromGitHub {
    owner = "agentclientprotocol";
    repo = "claude-agent-acp";
    rev = "v${version}";
    hash = "sha256-w8lrc/4cW7QZNDMvq663eas7Dl4tnya4JCM9xkLF8S8=";
  };

  npmDepsHash = "sha256-czNQInLxK/DMFViJWa15PGOU61qnqm0wNwFqjTH3Z+k=";

  meta = with lib; {
    description = "ACP (Agent Client Protocol) adapter for Anthropic Claude Code";
    homepage = "https://github.com/agentclientprotocol/claude-agent-acp";
    license = licenses.mit;
    mainProgram = "claude-agent-acp";
    platforms = platforms.unix;
  };
}
