# JetBrains' standalone Kotlin Language Server.
#
# Why this exists at all: `kotlin-language-server' (fwcd) is 1.3.13 and cannot
# resolve private repos or Google Artifact Registry, while the monolith is on
# Kotlin 2.4.10 / JDK 25.  So Kotlin LSP is degraded on the largest codebase we
# work in.  See modules/home/options/editors/emacs/specs/language-tooling.md §3.
#
# Why a local derivation rather than an input: the nix-casks route produced a
# derivation that RESOLVED -- attribute evaluated, build succeeded -- and left a
# 0 MB stub whose bin/kotlin-lsp was a dangling symlink into a `.sit' payload it
# never extracted.  Eglot then reported "Searching for program: No such file or
# directory, kotlin-lsp" and NO Kotlin server ran, not even fwcd's.  The lesson
# is in the spec and it governs this file: building is not evidence.  Acceptance
# is running the thing.
#
# Two traps, both already paid for:
#
#   * The `.sit' extension is a lie.  It is a plain ZIP (`PK\x03\x04'), so
#     `unzip' handles it and no StuffIt tooling is needed.
#   * The `.vsix' build is NOT a substitute.  It launches
#     `intellij-server --socket 0' -- TCP on an ephemeral port.  The binary
#     itself does support `--stdio' (verified: `intellij-server --help' lists
#     both), so the objection is to how the extension INVOKES it, not to the
#     server's transport support.
#
# Entry point: `bin/intellij-server', not `kotlin-lsp.sh'.  The shell launcher
# still works but prints "kotlin-lsp.sh is deprecated and will be removed in a
# future release. Use bin/intellij-server instead" on every start -- which would
# land on the stderr of every LSP session and pin us to something already
# scheduled for removal.
#
# Upgrading: the archive is linked from the release notes rather than uploaded
# as a release asset, so `gh api repos/Kotlin/kotlin-lsp/releases --jq
# '.[0].body'' is how you find the next URL.  JetBrains publish a `.sha256'
# beside each archive; use it rather than a hash you computed yourself.
#
# ==========================================================================
# BLOCKED: THE BUILD IS TIME-BOMBED, AND THE CURRENT ONE HAS EXPIRED
# ==========================================================================
#
# This derivation is correct.  It downloads (checksum matches JetBrains'
# published one), unpacks, wraps `bin/intellij-server', and the wrapper runs:
#
#     $ kotlin-lsp --version
#     LS-262.9593.0
#
# But an actual LSP session dies immediately:
#
#     This build of intellij-server has expired.
#     The IDE will now close.
#     Please download a new build from https://www.jetbrains.com/intellij-server/
#
# v262.9593.0 (2026-07-27) is the NEWEST release and it had already expired by
# 2026-09-08 -- roughly six weeks.  There is nothing newer to pin.
#
# This is the reason `useJetBrainsLsp' stays off, and it is a different reason
# from last time.  Previously the packaging was broken; now the packaging is
# fine and the software refuses to run.  `--version' answering was not evidence
# of a working server, which is the same lesson one level further in: even
# RUNNING the binary was not enough, because the failure only appears once a
# session is actually opened.
#
# The maintenance consequence matters more than this one expiry: a time-bombed
# build means any pinned version stops working after weeks, silently, and
# Kotlin LSP dies for everyone on the next expiry rather than at a switch we
# chose.  Adopting this server is therefore a recurring commitment, not a
# one-off packaging job -- worth weighing before turning it on even once
# JetBrains ship a build that runs.
{ lib
, stdenvNoCC
, fetchurl
, unzip
, makeWrapper
, jdk
}:

let
  version = "262.9593.0";

  # Per-platform archive.  Only the two macOS `.sit' builds are wired here
  # because that is what this machine is; the Linux builds are `.tar.gz' at
  # predictable URLs and would need a different unpack phase, so they are left
  # unimplemented rather than guessed at.
  sources = {
    aarch64-darwin = fetchurl {
      url = "https://download-cdn.jetbrains.com/language-server/kotlin-server/${version}/kotlin-server-${version}-aarch64.sit";
      # JetBrains' own published checksum, not one computed from a download.
      hash = "sha256-a6YCGnBrIeZM7zP34refGHwJEDIHIrstPtBa0RFexD8=";
    };
  };
in
stdenvNoCC.mkDerivation {
  pname = "kotlin-lsp";
  inherit version;

  src = sources.${stdenvNoCC.hostPlatform.system} or (throw
    "kotlin-lsp: no standalone archive wired for ${stdenvNoCC.hostPlatform.system}");

  nativeBuildInputs = [ unzip makeWrapper ];

  # `unzip' rather than the default unpacker: stdenv dispatches on the file
  # EXTENSION, and `.sit' is not one it knows, so it would refuse a file it is
  # perfectly capable of reading.
  unpackPhase = ''
    runHook preUnpack
    unzip -q $src -d .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/kotlin-lsp $out/bin
    cp -r ./* $out/share/kotlin-lsp/

    # Prefer `bin/intellij-server'.  `kotlin-lsp.sh' still works but warns
    # on every start that it "is deprecated and will be removed in a future
    # release"; wrapping it would put that warning on stderr of every LSP
    # session and leave us pinned to something scheduled for removal.
    # Fall back to it only if a future archive drops the binary.
    launcher=$(find $out/share/kotlin-lsp -name intellij-server -type f -maxdepth 3 | head -1)
    if [ -z "$launcher" ]; then
      launcher=$(find $out/share/kotlin-lsp -name kotlin-lsp.sh -maxdepth 3 | head -1)
    fi
    if [ -z "$launcher" ]; then
      echo "kotlin-lsp: neither bin/intellij-server nor kotlin-lsp.sh found." >&2
      echo "Without a launcher this package would install a stub, which is" >&2
      echo "the exact failure this derivation was written to avoid." >&2
      find $out/share/kotlin-lsp -maxdepth 2 | head -30 >&2
      exit 1
    fi
    chmod +x "$launcher"

    # `--stdio' is supplied by the caller (eglot), not baked in: the launcher
    # also serves a socket mode, and hard-coding one would quietly remove the
    # other.
    makeWrapper "$launcher" $out/bin/kotlin-lsp \
      --set JAVA_HOME "${jdk}" \
      --prefix PATH : "${lib.makeBinPath [ jdk ]}"

    runHook postInstall
  '';

  # The archive ships a JVM application; there is nothing to strip and the
  # bundled jars must not be rewritten.
  dontStrip = true;
  dontPatchELF = true;

  meta = with lib; {
    description = "JetBrains standalone Kotlin Language Server";
    homepage = "https://github.com/Kotlin/kotlin-lsp";
    license = licenses.asl20;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "kotlin-lsp";
  };
}
