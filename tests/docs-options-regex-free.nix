# The options generator must not run regex builtins over module text.
#
# lib.hasInfix, lib.splitString, builtins.match and builtins.split all go
# through std::regex. Nix on Linux links libstdc++, whose regex recurses once
# per character, so one match over agent-shell.nix (~450KB) overflows the
# evaluator stack and the docs CI job dies with "stack overflow (possible
# infinite recursion)". macOS Nix uses libc++ and evaluates it fine, so the
# coverage check passes locally while CI fails; this check is the local guard.
{ pkgs }:

pkgs.runCommand "decknix-docs-options-regex-free" { } ''
  pattern='hasInfix|splitString|escapeRegex|builtins\.(match|split)'
  if grep -nE "$pattern" ${../docs/generate-options.nix} \
      | grep -vE '^[0-9]+:[[:space:]]*#'; then
    echo "docs/generate-options.nix: regex builtins overflow the Linux evaluator stack" >&2
    echo "on large module files; use builtins.replaceStrings or lib.hasPrefix/hasSuffix." >&2
    exit 1
  fi
  touch $out
''
