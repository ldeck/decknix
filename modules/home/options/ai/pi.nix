# Configuration for Pi agent.
#
# Pi's canonical global config lives at ~/.pi/agent/settings.json (verified
# against pi-coding-agent 0.83.0; it does not read ~/.pi.json at all), so the
# declarative `settings' keys are merged into that file.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.ai.pi;

  # Scoped to Pi rather than set in the session: GOOGLE_CLOUD_PROJECT is the
  # default project for every Google SDK and Terraform provider, so exporting
  # it globally to reach Vertex from Pi would silently retarget them too.
  # --set-default keeps a value already in the environment winning.
  piPackage =
    if cfg.env == {} then pkgs.unstable.pi-coding-agent
    else pkgs.symlinkJoin {
      name = "pi-coding-agent-${pkgs.unstable.pi-coding-agent.version}-env";
      paths = [ pkgs.unstable.pi-coding-agent ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/pi ${concatStringsSep " "
          (mapAttrsToList (n: v: "--set-default ${n} ${escapeShellArg v}") cfg.env)}
      '';
    };
in {
  options.decknix.ai.pi = {
    enable = mkEnableOption "Pi agent configuration";

    settings = mkOption {
      type = types.attrs;
      default = {};
      description = ''
        Keys enforced in Pi's global settings (~/.pi/agent/settings.json)
        on every switch.  Merged per key, so the keys Pi writes itself
        (defaultModel from /model, packages, lastChangelogVersion) are kept;
        a key set here wins over a runtime edit of the same key.
        Example: { enabledModels = [ "openai-codex/gpt-6-sol" ]; tuiMode = "regular"; }.
      '';
    };

    env = mkOption {
      type = types.attrsOf types.str;
      default = {};
      example = { GOOGLE_CLOUD_PROJECT = "my-project"; GOOGLE_CLOUD_LOCATION = "global"; };
      description = ''
        Environment defaults for the `pi' binary only, e.g. the Vertex AI
        project and location its google-vertex provider requires alongside
        ADC credentials.  pi-acp launches `pi' from PATH, so agent-shell
        sessions get them too.  A value already set in the environment wins.
      '';
    };
  };

  config = mkIf cfg.enable {
    # The `pi' coding agent itself (binary `pi'; the pi-acp bridge shells
    # out to it) plus the ACP bridge that lets agent-shell (Emacs) launch
    # Pi over the Agent Client Protocol.  Managed by Nix; no manual npm
    # install needed.  `pi-coding-agent' is currently only in
    # nixpkgs-unstable, so it comes through the `unstable' overlay. That
    # attribute is sourced from the newer nixpkgs-current pin in flake.nix;
    # the shared unstable pin still carries 0.83.0.
    home.packages = [ piPackage pkgs.pi-acp ];

    # Pi rewrites settings.json at runtime (defaultModel on /model,
    # lastChangelogVersion after an update), so a whole-file agent-sync copy
    # never applied: the live file always differed from the seed, which
    # agent-sync treats as a conflict and keeps live.  Merge per key instead,
    # as claude.nix does for its settings.
    home.activation.pi-settings = mkIf (cfg.settings != {})
      (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        PI_SETTINGS="$HOME/.pi/agent/settings.json"
        ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$PI_SETTINGS")"
        [ -f "$PI_SETTINGS" ] || echo '{}' > "$PI_SETTINGS"
        TMP="$(${pkgs.coreutils}/bin/mktemp)"
        if ${pkgs.jq}/bin/jq --argjson seed ${escapeShellArg (builtins.toJSON cfg.settings)} \
             '. * $seed' "$PI_SETTINGS" > "$TMP"; then
          if ${pkgs.diffutils}/bin/cmp -s "$TMP" "$PI_SETTINGS"; then
            ${pkgs.coreutils}/bin/rm -f "$TMP"
          else
            $DRY_RUN_CMD ${pkgs.coreutils}/bin/mv "$TMP" "$PI_SETTINGS"
            echo "  [pi-settings] Merged ${toString (length (attrNames cfg.settings))} key(s) into $PI_SETTINGS"
          fi
        else
          ${pkgs.coreutils}/bin/rm -f "$TMP"
          echo "  [pi-settings] WARNING: failed to update $PI_SETTINGS (left unchanged)" >&2
        fi
      '');
  };
}
