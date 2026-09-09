{ lib, buildNpmPackage, fetchFromGitHub, makeWrapper }:

buildNpmPackage rec {
  pname = "pi-acp";
  version = "0.0.31";

  src = fetchFromGitHub {
    owner = "svkozak";
    repo = "pi-acp";
    rev = "v${version}";
    hash = "sha256-bM3V/3fxkY2Ib+OyfT82StIIRSLXGDuYUbt1CZKpTuo=";
  };

  npmDepsHash = "sha256-qN+b/tMbnJLkWjotl3XrA0nfZ3KT/mT6gM+n3Qiz8Wk=";

  patches = [ ./optimise-startup.patch ];

  nativeBuildInputs = [ makeWrapper ];

  # Nix owns upgrades, so suppress pi-acp's npm registry probe. Combined with
  # quietStartup this also avoids launching a second full Pi process just to
  # obtain the version while an ACP session is opening.
  postFixup = ''
    wrapProgram $out/bin/pi-acp \
      --set-default PI_SKIP_VERSION_CHECK 1 \
      --set-default PI_TELEMETRY 0
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    npm test
    runHook postCheck
  '';

  meta = with lib; {
    description = "ACP (Agent Client Protocol) adapter for Pi coding agent";
    homepage = "https://github.com/svkozak/pi-acp";
    license = licenses.mit;
    mainProgram = "pi-acp";
    platforms = platforms.unix;
  };
}
