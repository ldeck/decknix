# Gemini CLI, from the upstream release bundle.
#
# nixpkgs' source-built `gemini-cli' has been stuck at 0.47.0 since upstream's
# workspace lockfile started drifting from its package.json ranges: every bump
# breaks npmDepsHash/npm ci (NixOS/nixpkgs#572216; upstream fix pending in
# google-gemini/gemini-cli#29700).  nixpkgs' `gemini-cli-bin' packages the
# prebuilt bundle instead and tracks upstream, but lags a release or two, so
# this pins the version here.  Drop the override once nixpkgs-current carries
# a gemini-cli-bin at or past this version (NixOS/nixpkgs#575941 is 0.64.0).
{ gemini-cli-bin, fetchzip }:

gemini-cli-bin.overrideAttrs (_: rec {
  version = "0.64.0";

  src = fetchzip {
    url = "https://github.com/google-gemini/gemini-cli/releases/download/v${version}/gemini-cli-bundle.zip";
    hash = "sha256-4xBGPuIIryOJLBLVlZWLsVmHnJWCsLQVXeSL17ATFQE=";
    stripRoot = false;
  };
})
