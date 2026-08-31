{
  lib,
  stdenv,
  fetchFromGitHub,
  nodejs_22,
  importNpmLock,
  makeWrapper,
}:

let
  pname = "claude-agent-acp";
  version = "0.64.2";

  src = fetchFromGitHub {
    owner = "agentclientprotocol";
    repo = "claude-agent-acp";
    rev = "v${version}";
    hash = "sha256-EVFfQrUeAyG4NjJDqaebhc4E6LEoHFySwkvEhkdYq00=";
  };

  package = lib.importJSON "${src}/package.json";
  rawLock = lib.importJSON "${src}/package-lock.json";

  hostOs = if stdenv.hostPlatform.isDarwin then "darwin" else "linux";
  hostCpu = if stdenv.hostPlatform.isAarch64 then "arm64" else "x64";
  hostLibc = if stdenv.hostPlatform.isMusl then "musl" else "glibc";

  compatible = meta:
    !(meta.optional or false)
    || ((!(meta ? os) || builtins.elem hostOs meta.os)
      && (!(meta ? cpu) || builtins.elem hostCpu meta.cpu)
      && (!(meta ? libc) || builtins.elem hostLibc meta.libc));

  platformPackages = lib.filterAttrs
    (path: meta: path == "" || compatible meta)
    rawLock.packages;

  # Remove references to optional packages pruned above. importNpmLock resolves
  # every dependency name through the lock's package map, so dangling optional
  # references would otherwise fail evaluation before any build starts.
  filteredPackages = lib.mapAttrs (_path: meta:
    meta // lib.optionalAttrs (meta ? optionalDependencies) {
      optionalDependencies = lib.filterAttrs
        (name: _version: builtins.hasAttr "node_modules/${name}" platformPackages)
        meta.optionalDependencies;
    }) platformPackages;

  packageLock = rawLock // { packages = filteredPackages; };

  # Unlike buildNpmPackage's monolithic prefetch-npm-deps FOD, importNpmLock
  # gives each tarball its own fixed-output derivation. Successful downloads are
  # therefore retained in the Nix store if another registry request flakes, and
  # subsequent builds are fully offline. HTTP/1.1 avoids the registry's observed
  # HTTP/2 framing failures; retries apply independently to each small tarball.
  fetcherOpts = lib.mapAttrs (_path: _meta: {
    curlOptsList = [
      "--http1.1"
      "--retry" "8"
      "--retry-delay" "1"
      "--retry-all-errors"
    ];
  }) filteredPackages;

  npmSources = importNpmLock {
    inherit package packageLock fetcherOpts;
  };

  nodeModules = importNpmLock.buildNodeModules {
    inherit package packageLock;
    nodejs = nodejs_22;
    derivationArgs = {
      pname = "${pname}-node-modules";
      inherit version;
      npmDeps = npmSources;
    };
  };
in
stdenv.mkDerivation {
  inherit pname version src;

  npmDeps = nodeModules;
  nativeBuildInputs = [
    nodejs_22
    importNpmLock.linkNodeModulesHook
    makeWrapper
  ];

  buildPhase = ''
    runHook preBuild
    npm run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    target="$out/lib/node_modules/@agentclientprotocol/claude-agent-acp"
    mkdir -p "$target" "$out/bin"
    cp -R dist package.json README.md LICENSE "$target/"
    ln -s ${nodeModules}/node_modules "$target/node_modules"

    makeWrapper ${nodejs_22}/bin/node "$out/bin/claude-agent-acp" \
      --add-flags "$target/dist/index.js"

    runHook postInstall
  '';

  meta = with lib; {
    description = "ACP (Agent Client Protocol) adapter for Anthropic Claude Code";
    homepage = "https://github.com/agentclientprotocol/claude-agent-acp";
    license = licenses.asl20;
    mainProgram = "claude-agent-acp";
    platforms = platforms.unix;
  };
}
