# Reconcile and sync agent skills, commands, and guidelines between live files
# and Nix-managed repositories.
#
# This module provides a 3-way reconciliation guard for files that the agent
# might modify at runtime (like custom commands or guidelines).
#
# Logic:
#   - If live == last-deployed: overwrite with new Nix version (normal sync).
#   - If live != last-deployed AND Nix == last-deployed: keep live (local is ahead).
#   - If live != last-deployed AND Nix != last-deployed: keep live + warn (conflict).
#
# Use `decknix pull-local-changes` to pull live edits back into the repos.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.cli.agentSync;

  manifestPath = "$HOME/.config/decknix/agent-sync-manifest.json";

  syncScript = files: ''
    MANIFEST_PATH="${manifestPath}"
    mkdir -p "$(dirname "$MANIFEST_PATH")"

    # If manifest doesn't exist, start with empty
    if [ ! -f "$MANIFEST_PATH" ]; then
      echo '{"version":1,"files":{}}' > "$MANIFEST_PATH"
    fi

    ${concatStringsSep "\n" (mapAttrsToList (target: info: ''
      TARGET_PATH="${target}"
      # Expand ~ if present
      TARGET_PATH="''${TARGET_PATH/#\~/$HOME}"
      SOURCE_PATH="${info.source}"
      REPO_NAME="${info.repo}"
      REPO_PATH="${info.repoPath}"

      # Compute hashes
      NEW_HASH=$(${pkgs.coreutils}/bin/sha256sum "$SOURCE_PATH" | cut -d' ' -f1)

      if [ -f "$TARGET_PATH" ]; then
        LIVE_HASH=$(${pkgs.coreutils}/bin/sha256sum "$TARGET_PATH" | cut -d' ' -f1)
        # Get last-deployed hash from manifest using jq
        LAST_HASH=$(${pkgs.jq}/bin/jq -r ".files[\"${target}\"].hash // \"\"" "$MANIFEST_PATH")

        if [ "$LIVE_HASH" == "$LAST_HASH" ]; then
          # Safe to overwrite (no local changes)
          cp -f "$SOURCE_PATH" "$TARGET_PATH"
          chmod 644 "$TARGET_PATH"
          echo "  [agent-sync] Updated $TARGET_PATH"
          # Update manifest
          TEMP_MANIFEST=$(mktemp)
          ${pkgs.jq}/bin/jq ".files[\"${target}\"] = {hash: \"$NEW_HASH\", nix_store_path: \"$SOURCE_PATH\", source_repo: \"$REPO_NAME\", repo_path: \"$REPO_PATH\"}" "$MANIFEST_PATH" > "$TEMP_MANIFEST"
          mv "$TEMP_MANIFEST" "$MANIFEST_PATH"
        elif [ "$NEW_HASH" == "$LAST_HASH" ]; then
          # Local is ahead, nix is unchanged
          echo "  [agent-sync] SKIP $TARGET_PATH (locally modified, Nix version unchanged)"
        else
          # Conflict! (both changed)
          echo "  [agent-sync] WARNING: CONFLICT in $TARGET_PATH (both live and Nix versions changed). Keeping live version."
          echo "  [agent-sync] Run 'decknix pull-local-changes' to reconcile."
        fi
      else
        # Brand new file
        mkdir -p "$(dirname "$TARGET_PATH")"
        cp -f "$SOURCE_PATH" "$TARGET_PATH"
        chmod 644 "$TARGET_PATH"
        echo "  [agent-sync] Initialised $TARGET_PATH"
        # Update manifest
        TEMP_MANIFEST=$(mktemp)
        ${pkgs.jq}/bin/jq ".files[\"${target}\"] = {hash: \"$NEW_HASH\", nix_store_path: \"$SOURCE_PATH\", source_repo: \"$REPO_NAME\", repo_path: \"$REPO_PATH\"}" "$MANIFEST_PATH" > "$TEMP_MANIFEST"
        mv "$TEMP_MANIFEST" "$MANIFEST_PATH"
      fi
    '') files)}
  '';

in {
  options.decknix.cli.agentSync = {
    enable = mkEnableOption "agent-shell sync (managed copies of guidelines and commands)";

    files = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          source = mkOption {
            type = types.path;
            description = "The Nix store path of the file to deploy.";
          };
          repo = mkOption {
            type = types.str;
            description = "The repository name it belongs to (e.g. 'decknix').";
          };
          repoPath = mkOption {
            type = types.str;
            description = "The relative path within that repository.";
          };
        };
      });
      default = {};
      description = "Files to manage via the 3-way reconciliation sync.";
    };
  };

  config = mkIf cfg.enable {
    home.activation.agent-sync = lib.hm.dag.entryAfter [ "writeBoundary" ] (syncScript cfg.files);
  };
}
