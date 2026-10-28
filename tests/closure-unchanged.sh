#!/usr/bin/env bash
# Prove that a decknix change leaves an existing install's system untouched.
#
# Evaluates the darwin system derivation of a real user flake twice, once with
# decknix at a baseline revision and once with the working tree, and fails if
# the two drv paths differ. Adoption-state work must keep installs that have no
# adoption.toml on exactly their current behaviour; equal drv paths mean the
# whole closure is identical, which is a stronger statement than "the options
# came out the same".
#
# Usage: tests/closure-unchanged.sh <baseline-rev>
# Env:   DECKNIX_USER_FLAKE  user flake directory (default ~/.config/decknix)
#        DECKNIX_OVERRIDES   extra "INPUT=PATH" overrides, space separated,
#                            applied identically to both evaluations
set -euo pipefail

baseline_rev=${1:?usage: $0 <baseline-rev>}
repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
flake=${DECKNIX_USER_FLAKE:-$HOME/.config/decknix}

if [ -e "$flake/adoption.toml" ]; then
  echo "$flake/adoption.toml exists; this test is about installs without one" >&2
  exit 2
fi

overrides=()
for pair in ${DECKNIX_OVERRIDES:-}; do
  overrides+=(--override-input "${pair%%=*}" "git+file://${pair#*=}")
done

baseline=$(mktemp -d)
trap 'rm -rf "$baseline"' EXIT
git clone --quiet --no-checkout "$repo" "$baseline"
git -C "$baseline" checkout --quiet "$(git -C "$repo" rev-parse "$baseline_rev")"

drv() {
  nix eval --raw --impure \
    "$flake#darwinConfigurations.default.system.drvPath" \
    --override-input decknix "git+file://$1" "${overrides[@]}" 2> >(grep -v "^trace:" >&2)
}

before=$(drv "$baseline")
after=$(drv "$repo")
echo "baseline  $baseline_rev: $before"
echo "candidate worktree: $after"
if [ "$before" != "$after" ]; then
  echo "system derivation changed" >&2
  exit 1
fi
echo "unchanged"
