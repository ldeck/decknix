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

    # Helper: record a file's deployed hash + provenance into the manifest.
    record_manifest() {
      # $1 = manifest key (target spec, with ~), $2 = hash, $3 = source path,
      # $4 = repo name, $5 = repo-relative path
      TEMP_MANIFEST=$(mktemp)
      ${pkgs.jq}/bin/jq --arg k "$1" --arg h "$2" --arg s "$3" --arg r "$4" --arg p "$5" \
        '.files[$k] = {hash: $h, nix_store_path: $s, source_repo: $r, repo_path: $p}' \
        "$MANIFEST_PATH" > "$TEMP_MANIFEST"
      mv "$TEMP_MANIFEST" "$MANIFEST_PATH"
    }

    ${concatStringsSep "\n" (mapAttrsToList (target: info: ''
      TARGET_PATH="${target}"
      # Expand ~ if present
      TARGET_PATH="''${TARGET_PATH/#\~/$HOME}"
      SOURCE_PATH="${info.source}"
      REPO_NAME="${info.repo}"
      REPO_PATH="${info.repoPath}"
      # Scripts (executable = true) deploy 755; everything else stays 644.
      MODE="${if info.executable then "755" else "644"}"

      # Ensure the parent directory exists (skills nest several levels deep).
      mkdir -p "$(dirname "$TARGET_PATH")"

      # Migration safety: if the target is still a Home-Manager symlink into
      # the Nix store (from the previous home.file deployment), remove it so we
      # write a real, editable copy rather than failing on the read-only store.
      if [ -L "$TARGET_PATH" ]; then
        rm -f "$TARGET_PATH"
      fi

      # Compute hashes
      NEW_HASH=$(${pkgs.coreutils}/bin/sha256sum "$SOURCE_PATH" | cut -d' ' -f1)
      LAST_HASH=$(${pkgs.jq}/bin/jq -r ".files[\"${target}\"].hash // \"\"" "$MANIFEST_PATH")

      if [ -f "$TARGET_PATH" ]; then
        LIVE_HASH=$(${pkgs.coreutils}/bin/sha256sum "$TARGET_PATH" | cut -d' ' -f1)

        if [ "$LIVE_HASH" == "$NEW_HASH" ]; then
          # Already identical (incl. untracked-but-identical on first migration).
          # Adopt it: refresh mode + record provenance, no copy needed.
          chmod "$MODE" "$TARGET_PATH"
          record_manifest "${target}" "$NEW_HASH" "$SOURCE_PATH" "$REPO_NAME" "$REPO_PATH"
        elif [ "$LIVE_HASH" == "$LAST_HASH" ]; then
          # Live matches last-deployed (no local edits) → safe to update.
          cp -f "$SOURCE_PATH" "$TARGET_PATH"
          chmod "$MODE" "$TARGET_PATH"
          echo "  [agent-sync] Updated $TARGET_PATH"
          record_manifest "${target}" "$NEW_HASH" "$SOURCE_PATH" "$REPO_NAME" "$REPO_PATH"
        elif [ "$NEW_HASH" == "$LAST_HASH" ]; then
          # Local is ahead, Nix is unchanged → keep live.
          echo "  [agent-sync] SKIP $TARGET_PATH (locally modified, Nix version unchanged)"
        else
          # Conflict: both live and Nix diverged from last-deployed. Keep live.
          echo "  [agent-sync] WARNING: CONFLICT in $TARGET_PATH (both live and Nix versions changed). Keeping live version."
          echo "  [agent-sync] Run 'decknix pull-local-changes' to reconcile."
        fi
      else
        # Brand new file
        cp -f "$SOURCE_PATH" "$TARGET_PATH"
        chmod "$MODE" "$TARGET_PATH"
        echo "  [agent-sync] Initialised $TARGET_PATH"
        record_manifest "${target}" "$NEW_HASH" "$SOURCE_PATH" "$REPO_NAME" "$REPO_PATH"
      fi
    '') files)}
  '';

in {
  options.decknix.cli.agentSync = {
    # Auto-enables whenever any module registers files for sync, so consumers
    # (decknix's agent-shell.nix, an org's decknix-config) only need to append
    # to `files` — no coordination on a shared `enable` flag (which would be a
    # multiple-definition conflict across modules).
    enable = mkOption {
      type = types.bool;
      default = cfg.files != {};
      description = "Whether to sync managed agent guidelines/commands/skills (auto-enabled when files are registered).";
    };

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
          executable = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Whether to deploy the file with the executable bit (755 instead
              of 644). Use for skill helper scripts (e.g. files under a
              `scripts/` directory). `decknix pull-local-changes` preserves the
              mode on the way back, so the repo source stays executable too.
            '';
          };
        };
      });
      default = {};
      description = "Files to manage via the 3-way reconciliation sync.";
    };
  };

  config = mkIf cfg.enable {
    # Run after linkGeneration so Home Manager has already torn down any stale
    # home.file symlinks (e.g. files migrated off the old symlink deployment)
    # before we lay down real, editable copies.
    home.activation.agent-sync =
      lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" ] (syncScript cfg.files);
  };
}
