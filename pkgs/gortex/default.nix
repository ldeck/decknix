{ lib, stdenvNoCC, fetchurl, installShellFiles }:

# Gortex ships prebuilt, checksummed release tarballs, and we install those
# rather than building from source.  Building would mean Go 1.26 + CGO against
# tree-sitter C bindings for 257 languages -- a heavy compile for a tool that
# publishes a signed binary per platform.  The hashes below are the upstream
# `checksums.txt` for the tag, converted to SRI, so the fixed-output derivation
# fails closed if a release asset is ever re-cut under the same tag.

let
  version = "0.64.7";

  # sha256 values transcribed from
  # https://github.com/zzet/gortex/releases/download/v${version}/checksums.txt
  sources = {
    aarch64-darwin = {
      asset = "gortex_darwin_arm64.tar.gz";
      hash = "sha256-u3t+FQG6fDkVAfUzgHfYneHzk8Ya1LeGzynXC3eJaQQ=";
    };
    x86_64-darwin = {
      asset = "gortex_darwin_amd64.tar.gz";
      hash = "sha256-j+5uxxfQakrZeg/Try3m94hNsQO05SQ1n76rdT8Whw8=";
    };
    x86_64-linux = {
      asset = "gortex_linux_amd64.tar.gz";
      hash = "sha256-XYeJTZ+gnWX460hlfRTdFu1c4Q3VoDB3zHmY+4V0ANQ=";
    };
    aarch64-linux = {
      asset = "gortex_linux_arm64.tar.gz";
      hash = "sha256-27FrZndsTTlMBdRkZ6kdIpx3+om4JibivFgc0pm026M=";
    };
  };

  source =
    sources.${stdenvNoCC.hostPlatform.system}
      or (throw "gortex: no released binary for ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "gortex";
  inherit version;

  src = fetchurl {
    url = "https://github.com/zzet/gortex/releases/download/v${version}/${source.asset}";
    inherit (source) hash;
  };

  # Flat tarball: gortex, LICENSE.md, README.md -- no leading directory.
  sourceRoot = ".";

  nativeBuildInputs = [ installShellFiles ];

  dontConfigure = true;
  dontBuild = true;
  # A prebuilt Go binary is statically linked apart from libSystem; stripping or
  # rewriting it only risks breaking the upstream signature.
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 gortex $out/bin/gortex
    install -Dm644 LICENSE.md $out/share/doc/gortex/LICENSE.md
    install -Dm644 README.md $out/share/doc/gortex/README.md
    runHook postInstall
  '';

  # Cobra generates completions from the binary itself.
  postInstall = ''
    installShellCompletion --cmd gortex \
      --bash <($out/bin/gortex completion bash) \
      --zsh <($out/bin/gortex completion zsh) \
      --fish <($out/bin/gortex completion fish)
  '';

  meta = with lib; {
    description = "Code-intelligence engine that serves a repo knowledge graph to AI agents over MCP";
    longDescription = ''
      Gortex indexes repositories into a queryable knowledge graph and serves it
      to coding agents over MCP, HTTP and a web UI, so an agent answers a
      question with one graph query instead of many file reads.  A long-living
      daemon holds one graph across every tracked repo and every editor window.
    '';
    homepage = "https://gortex.dev/";
    downloadPage = "https://github.com/zzet/gortex/releases";
    changelog = "https://github.com/zzet/gortex/releases/tag/v${version}";
    license = licenses.asl20;
    mainProgram = "gortex";
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    platforms = attrNames sources;
  };
}
