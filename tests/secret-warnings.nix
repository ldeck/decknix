# The config loader warns, by path only, about secrets left inside the flake
# dir (lib/default.nix `secretWarnings`): that directory is copied into the
# world-readable /nix/store on every evaluation.
#
#   nix build .#checks.<system>.secret-warnings
{ pkgs, self }:

let
  lib = pkgs.lib;
  warningsFor = fixture: (self.lib.configLoader {
    inherit lib;
    username = "test";
    configDir = ./fixtures + "/${fixture}";
  }).secretWarnings;
  audit = warningsFor "secret-audit";
  has = s: lib.any (w: lib.hasInfix s w) audit;
  expect = name: ok: if ok then null else throw "secret-warnings: ${name}\n${lib.concatStringsSep "\n" audit}";
  results = [
    (expect "flags a raw <org>/secrets dir" (has "acme/secrets/ holds raw secret files"))
    (expect "flags a secret-named file" (has "local/service.env looks like a raw secret file"))
    (expect "flags a literal in secrets.nix, by line" (has "secrets.nix has what look like secret literals (lines 3)"))
    (expect "ignores non-secret json" (!has "token-quotas.json"))
    (expect "never quotes contents" (!has "placeholder"))
    (expect "three findings" (builtins.length audit == 3))
    (expect "an empty config dir is quiet" (warningsFor "config-empty" == []))
  ];
in
builtins.seq (builtins.deepSeq results null)
  (pkgs.runCommand "decknix-secret-warnings" { } "touch $out")
