# direnv — per-directory environment loading (`.envrc` support).
#
# This was previously missing: `.direnv` was git-ignored but the program
# itself was never enabled, so `.envrc` files were silently ignored (no
# `direnv hook zsh` was ever installed). Enabling the home-manager
# `programs.direnv` module wires the shell hook automatically
# (`enableZshIntegration` defaults to true), so `cd`-ing into a directory
# with an authorised `.envrc` now loads its environment.
#
# `nix-direnv` adds fast, cached `use nix` / `use flake` support and keeps
# the build alive as a GC root, so flake dev-shells reload quickly instead
# of re-evaluating on every `cd`.
#
# All framework defaults use `lib.mkDefault` so a personal/org config can
# disable direnv entirely (`programs.direnv.enable = false`) or drop
# nix-direnv without conflict.
{ lib, ... }:

with lib;

{
  programs.direnv = {
    enable = mkDefault true;
    nix-direnv.enable = mkDefault true;
  };
}
