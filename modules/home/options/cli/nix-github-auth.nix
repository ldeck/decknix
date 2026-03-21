# Automatic GitHub API authentication for Nix
#
# When enabled, generates ~/.config/nix/access-tokens.conf with a fresh
# GitHub token (via `gh auth token`) on every `decknix switch`. This file
# is included by the nix-daemon via !include in /etc/nix/nix.conf (set in
# modules/darwin/default.nix), giving both daemon and user-level nix
# authenticated GitHub API access (5000 req/hr instead of 60).
#
# No secrets are stored in the Nix store or git — the token file is
# written directly to the filesystem by an activation script.
{ config, lib, pkgs, ... }:

let
  cfg = config.decknix.nix.githubAuth;
in
{
  options.decknix.nix.githubAuth = {
    enable = lib.mkEnableOption "automatic GitHub API authentication for Nix" // {
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    # On activation, write a fresh access-tokens.conf using `gh auth token`.
    # Also ensures ~/.config/nix/nix.conf includes the token file so
    # user-level nix commands (outside the daemon) also get auth.
    # This runs on every `decknix switch`, keeping the token current.
    home.activation.nix-github-auth = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      NIX_DIR="$HOME/.config/nix"
      TOKEN_FILE="$NIX_DIR/access-tokens.conf"
      NIX_CONF="$NIX_DIR/nix.conf"
      INCLUDE_LINE="!include access-tokens.conf"
      GH="${pkgs.gh}/bin/gh"

      mkdir -p "$NIX_DIR"

      # 1. Write fresh token file (use Nix store path — gh may not be on
      #    PATH yet during activation)
      if [ -x "$GH" ]; then
        TOKEN=$("$GH" auth token 2>/dev/null || true)
        if [ -n "$TOKEN" ]; then
          echo "access-tokens = github.com=$TOKEN" > "$TOKEN_FILE"
          chmod 600 "$TOKEN_FILE"
          echo "  [nix-github-auth] Updated $TOKEN_FILE"
        else
          echo "  [nix-github-auth] Warning: gh auth token returned empty (not logged in?)"
        fi
      else
        echo "  [nix-github-auth] Warning: gh not found at $GH, skipping token generation"
      fi

      # 2. Ensure nix.conf includes the token file (idempotent)
      if [ ! -f "$NIX_CONF" ]; then
        echo "$INCLUDE_LINE" > "$NIX_CONF"
        echo "  [nix-github-auth] Created $NIX_CONF with include"
      elif ! grep -qF "$INCLUDE_LINE" "$NIX_CONF"; then
        echo "$INCLUDE_LINE" >> "$NIX_CONF"
        echo "  [nix-github-auth] Added include to $NIX_CONF"
      fi
    '';
  };
}

