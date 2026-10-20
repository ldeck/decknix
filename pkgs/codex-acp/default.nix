# ACP bridge for OpenAI Codex (@agentclientprotocol/codex-acp, the
# TypeScript successor to zed-industries/codex-acp), which agent-shell's
# `agent-shell-openai' launches as `codex-acp'.
#
# Built on nixpkgs' derivation, which drops npm's bundled Codex binaries
# and pins CODEX_PATH to the source-built `codex', so the bridge and the
# `codex' CLI on PATH are always the same version.  nixpkgs-current lags
# upstream by a minor release; bump here and drop the override once it
# catches up.
{ codex-acp, fetchFromGitHub, fetchNpmDeps }:

codex-acp.overrideAttrs (final: _: {
  version = "2.2.2";

  src = fetchFromGitHub {
    owner = "agentclientprotocol";
    repo = "codex-acp";
    tag = "v${final.version}";
    hash = "sha256-9qIKaDZJ80PVO7/qBfbOE7un2Ukk92bZVrIaHG/K8P8=";
  };

  npmDeps = fetchNpmDeps {
    inherit (final) src patches;
    name = "codex-acp-${final.version}-npm-deps";
    hash = "sha256-4wXnQnPEUp0DtNphXBS5/WQkgErRD631xOB0KqDXf4U=";
  };
})
