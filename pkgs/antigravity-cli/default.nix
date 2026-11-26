# Antigravity CLI (`agy'), Google's successor to the Gemini CLI.
#
# nixpkgs-current carries `antigravity-cli' 1.4.1, which predates the `acp'
# subcommand agent-shell launches it with (`agy acp', first shipped in the
# 1.5 line), so this pins a newer upstream release bundle on nixpkgs'
# derivation.  It also adds x86_64-darwin, which nixpkgs omits.  Drop the
# override once nixpkgs-current reaches this version.
#
# Upstream publishes `<base>/latest' and `<base>/<version>/manifest.json';
# the download URL embeds a build id next to the version, and the hashes
# below are the manifest's sha512 values.
{ antigravity-cli, fetchurl, lib, stdenvNoCC }:

let
  version = "1.5.18";
  buildId = "6386224290725888";
  base = "https://storage.googleapis.com/antigravity-public/antigravity-cli/${version}-${buildId}";

  sources = {
    aarch64-darwin = {
      path = "darwin-arm/cli_mac_arm64.tar.gz";
      hash = "sha512-0Q4ST1602pTrtsSUzS57OHRPn2bo6HFF0sutHL08QWD9iKec1CIN/OfJ2g3erWUjRrzIOZFFdfZEdDiujR1dzA==";
    };
    x86_64-darwin = {
      path = "darwin-x64/cli_mac_x64.tar.gz";
      hash = "sha512-xqs5tBUR7glRIjtsF44FcegxBYAHAQQdmrxSAWHvA4FyRCXsbpJz+8YJQRlByJhu2ar9cRsaP4aFfHBe/jrCoA==";
    };
    x86_64-linux = {
      path = "linux-x64/cli_linux_x64.tar.gz";
      hash = "sha512-7zeeyGlxkRL2lujHz933dmGHEuWPw45T34CAHWUoq7Rnd4LHyHePnAnJEj+kTCwyZ10ijAbyqPeo9CFOdfW7Jg==";
    };
    aarch64-linux = {
      path = "linux-arm/cli_linux_arm64.tar.gz";
      hash = "sha512-bFnLzlp2Mgg91O9ZQpblLOCr3BL4tOy1VSPgk3SM8Xj4+Dg9flHp7XhZ6m5GyDpDp7RjZLDgM90Tr7JNa/vkyA==";
    };
  };

  system = stdenvNoCC.hostPlatform.system;
  source = sources.${system} or (throw "antigravity-cli: unsupported system ${system}");
in
antigravity-cli.overrideAttrs (old: {
  inherit version;

  src = fetchurl {
    url = "${base}/${source.path}";
    inherit (source) hash;
  };

  passthru = (old.passthru or { }) // { wholeVersion = "${version}-${buildId}"; };

  meta = old.meta // { platforms = lib.attrNames sources; };
})
