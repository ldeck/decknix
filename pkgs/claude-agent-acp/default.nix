{ lib, buildNpmPackage, fetchFromGitHub, nodejs_22, stdenv }:

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

  # Trim the lockfile to the current host platform so npmDeps only prefetches
  # the one Claude SDK binary we can actually use.  The upstream lockfile lists
  # darwin/linux/win32 variants together; leaving them in makes Nix fetch a
  # useless cross-platform blob for every resume.
  postPatch = let
    hostOs = if stdenv.hostPlatform.isDarwin then "darwin" else "linux";
    hostCpu = if stdenv.hostPlatform.isAarch64 then "arm64" else "x64";
    hostLibc = if stdenv.hostPlatform.isMusl then "musl" else "glibc";
  in ''
    cat > prune-lockfile.mjs <<'EOF'
    import fs from 'node:fs';

    const file = process.argv[2];
    const hostOs = process.argv[3];
    const hostCpu = process.argv[4];
    const hostLibc = process.argv[5];

    const lock = JSON.parse(fs.readFileSync(file, 'utf8'));
    const keep = (meta) => {
      if (!meta || meta.optional !== true) return true;
      if (meta.os && !meta.os.includes(hostOs)) return false;
      if (meta.cpu && !meta.cpu.includes(hostCpu)) return false;
      if (meta.libc && !meta.libc.includes(hostLibc)) return false;
      return true;
    };

    for (const [key, meta] of Object.entries(lock.packages || {})) {
      if (key === "" || keep(meta)) continue;
      delete lock.packages[key];
    }

    const root = lock.packages?.[""] ?? {};
    if (root.optionalDependencies) {
      root.optionalDependencies = Object.fromEntries(
        Object.entries(root.optionalDependencies)
          .filter(([name]) => keep(lock.packages?.['node_modules/' + name]))
      );
      lock.packages[""] = root;
    }

    fs.writeFileSync(file, JSON.stringify(lock, null, 2) + "\n");
    EOF
    ${nodejs_22}/bin/node prune-lockfile.mjs package-lock.json ${hostOs} ${hostCpu} ${hostLibc}

  '';

  # Strip the resume replay flag from the built bridge binary.  The transcript
  # is already restored in Emacs and the model context is restored natively via
  # ACP `session/resume`, so replaying the old user turns just burns CPU.
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
