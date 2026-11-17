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
  version = "1.5.11";
  buildId = "5332071107919872";
  base = "https://storage.googleapis.com/antigravity-public/antigravity-cli/${version}-${buildId}";

  sources = {
    aarch64-darwin = {
      path = "darwin-arm/cli_mac_arm64.tar.gz";
      hash = "sha512-zqcP9fOP+NDdMdOO29XDbMWPz8Nc53psCJMeNYhNFpF5ZIQBwCzpNCRtaWSTZPSrtIUXn2qHqYtNhZPFaveqDQ==";
    };
    x86_64-darwin = {
      path = "darwin-x64/cli_mac_x64.tar.gz";
      hash = "sha512-FhmKWoVdPLkicUBU7H22/kvrN3kHK42EJp6rfC4r8FCjmMAgOdI8LHkIwH36FdDXrhXYqV8gOOELu2UHLxKhsQ==";
    };
    x86_64-linux = {
      path = "linux-x64/cli_linux_x64.tar.gz";
      hash = "sha512-gA8bJfXA9N2X1WIPKF2xwHwxUsj1Oa0ImoxMNfobvGhkgLjiIfuZK445O2y1xtLySQqN/DOUerTxEAR3NSHUnQ==";
    };
    aarch64-linux = {
      path = "linux-arm/cli_linux_arm64.tar.gz";
      hash = "sha512-ZFlsJ62VhR3hKfMU0vNzP118HO6PdV0IMolmplPlx3zZ1yCBHJTCbaGb75t1xoMxPjbbxfUkeMQvyjb9uPUpnA==";
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
