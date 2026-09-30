# Configuration for Claude agent (managed via agent-sync).
#
# This module ensures ~/.claude.json and ~/.claude/ are managed via the
# 3-way reconciliation sync, allowing for local edits to skills/commands.
#
# It also configures Claude Code's permission allowlist
# (~/.claude/settings.json -> permissions.allow) so that tools installed by
# decknix/Nix -- the executable skill helper scripts registered via
# `decknix.cli.agentSync` with `executable = true` -- run without a per-session
# "allow this command?" prompt.  See the `permissions` options below.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.ai.claude;

  home = config.home.homeDirectory;

  # Expand a leading "~/" in an agent-sync target to an absolute path, since
  # Claude matches permission rules against the absolute command it runs.
  expandTilde = p:
    if hasPrefix "~/" p then "${home}/${removePrefix "~/" p}" else p;

  # Auto-derived allow rules for every decknix-managed *executable* tool: each
  # `decknix.cli.agentSync` file with `executable = true` (the skill helper
  # scripts, framework- or org-registered) becomes a narrow prefix rule
  # `Bash(<abs-path>:*)` -- matching that script invoked with any arguments.
  # We only read the sibling agent-sync entries' `executable` flag; this
  # module's own agent-sync contribution (~/.claude.json) is never executable,
  # so no self-referential evaluation cycle is introduced.
  managedExecutables =
    mapAttrsToList (target: _info: "Bash(${expandTilde target}:*)")
      (filterAttrs (_target: info: info.executable)
        config.decknix.cli.agentSync.files);

  # Final allowlist: managed executables (opt-out) plus any explicit extras.
  allowRules = unique
    ((optionals cfg.permissions.allowManagedTools managedExecutables)
     ++ cfg.permissions.allow);
in {
  options.decknix.ai.claude = {
    enable = mkEnableOption "Claude agent configuration";

    settings = mkOption {
      type = types.attrs;
      default = {};
      description = "Declarative settings for ~/.claude.json";
    };

    permissions = {
      allowManagedTools = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Automatically allowlist decknix/Nix-installed executable tools in
          Claude Code's `~/.claude/settings.json` (`permissions.allow`), so
          Claude does not prompt "allow this command?" every session for the
          skill helper scripts it manages.  Covers every `decknix.cli.agentSync`
          file marked `executable = true` (framework- or org-registered),
          rendered as a narrow `Bash(<abs-path>:*)` prefix rule.  Set to false
          to manage the allowlist entirely by hand (or via `permissions.allow`).
        '';
      };

      allow = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "Bash(gh pr view:*)" "Bash(npm run test:*)" ];
        description = ''
          Extra Claude Code permission rules to merge into
          `~/.claude/settings.json` (`permissions.allow`), in addition to the
          auto-derived managed-tool rules.  Use Claude's rule syntax, e.g.
          `Bash(<prefix>:*)` for a prefix match with a word boundary.

          Rules are deep-merged (union + de-duplicated) into the existing file
          without disturbing Claude's own runtime-written keys.
        '';
      };

      deny = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "Bash(sudo:*)" "Read(~/.config/decknix/**/secrets/**)" ];
        description = ''
          Claude Code permission DENY rules to merge into
          `~/.claude/settings.json` (`permissions.deny`).  Deny always wins
          over allow, so this is the backstop for a broad allow-list
          ("blacklist" model): allow a tool generally via `permissions.allow`
          (e.g. bare `Bash`), then name the few never-do commands here.

          Deep-merged (union + de-duplicated) like `allow`, and never removes
          Claude's own runtime-written keys.  Uses Claude's rule syntax, e.g.
          `Bash(<prefix>:*)` for a prefix match or `Read(<glob>)` for a path
          glob.  The host's own destructive-command classifier remains an
          independent guard regardless of what is (or isn't) denied here.
        '';
      };
    };

    disableAutoUpdate = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Stop Claude Code updating itself, so the Nix-pinned version is the
        one that actually runs.

        Claude Code ships an auto-updater that downloads newer builds into
        `~/.local/share/claude/versions/` and hands off to them at launch.
        That silently defeats the Nix pin: `decknix switch` installs one
        version and you run another.  Observed on this machine -- Nix
        provided claude-code 2.1.220 while `~/.local/share/claude/versions/`
        held 2.1.246 through 2.1.257 (a fresh one that morning), and a
        single session transcript recorded three different `version` values
        across its lifetime.  It also accumulates ~200MB per build.

        Sets `DISABLE_AUTOUPDATER=1` both as a session variable (covering
        CLI launches) and in `~/.claude/settings.json`'s `env` block
        (covering Claude's own start-up), because the two paths are read at
        different points and only the pair reliably covers both.

        Note `~/.claude.json` already carried `autoUpdates: false` and was
        NOT honoured -- that is the legacy runtime-state file, not the
        settings file, which is why versions kept appearing.

        Turning this off means Claude updates itself again and the Nix pin
        becomes advisory; bump the flake input to move versions instead.
      '';
    };

    mcpServers = mkOption {
      type = types.attrsOf types.attrs;
      default = {};
      example = {
        # Atlassian (Jira + Confluence) via the mcp-remote bridge.  Once
        # authenticated (first invocation opens a browser flow), Claude gets
        # native Jira/Confluence tools and no longer has to shell out to
        # `auggie --print --ask` for issue lookups.
        atlassian = {
          type = "stdio";
          command = "npx";
          args = [ "-y" "mcp-remote" "https://mcp.atlassian.com/v1/sse" ];
        };
      };
      description = ''
        MCP (Model Context Protocol) server configurations for Claude Code.
        Each key is the server name (as shown in Claude's `/mcp` list); the
        value is the MCP server config object.  Same shape as
        `decknix.cli.auggie.mcpServers` — stdio servers use `type`,
        `command`, `args`, `env`; remote servers use `type = "http"` /
        `"sse"` plus `url` and optional `headers`.

        Deep-merged into the `.mcpServers` object of the runtime-managed
        `~/.claude.json` on every `decknix switch`.  Nix-declared entries
        take precedence over Claude-added entries with the same name;
        Claude-added entries with unrelated names are preserved.  Removing
        an entry from Nix does NOT remove it from `~/.claude.json` (Claude
        may have converged on it independently); use `/mcp remove <name>`
        inside Claude to purge those.

        Global configuration lives here so every workspace inherits the
        same servers without per-repo `.mcp.json` sprawl.  Add a workspace
        `.mcp.json` only when a server should be strictly project-local.
      '';
    };
  };

  config = mkIf cfg.enable {
    # ACP bridge — allows agent-shell (Emacs) to launch Claude Code sessions
    # via the Agent Client Protocol. Managed by Nix; no manual npm install needed.
    # Its lockfile is pruned to the active host platform and each npm tarball is
    # fetched into its own Nix store path, making successful fetches reusable and
    # subsequent builds offline instead of restarting one monolithic npm download.
    # The Claude Code CLI itself, plus the ACP bridge.
    #
    # The CLI was NEVER managed here -- only the bridge was -- which is why
    # `~/.local/bin/claude' ended up ahead of Nix on PATH, running a
    # self-updated build out of `~/.local/share/claude/versions/'.  The
    # `disableAutoUpdate' machinery below was therefore guarding a pin that
    # did not exist.
    #
    # `pkgs.unstable.claude-code' is overlaid from the independent
    # nixpkgs-current input in flake.nix. The shared unstable lock was still
    # at 2.1.220 on 2026-10-01 while upstream had 2.1.283. A separate pin
    # lets us refresh selected tools without advancing all unstable packages (and
    # also updates consumers that list unstable.claude-code themselves).
    # A stale CLI can withhold new models from the C-c C-v picker.
    home.packages = [ pkgs.unstable.claude-code pkgs.claude-agent-acp ];

    # Keep the Nix pin authoritative (see `disableAutoUpdate').  The session
    # variable covers a CLI launch; the settings.json `env' merge below
    # covers Claude's own start-up path.
    home.sessionVariables = mkIf cfg.disableAutoUpdate {
      DISABLE_AUTOUPDATER = "1";
    };

    # If we have settings, generate the file and sync it
    decknix.cli.agentSync.enable = true;
    decknix.cli.agentSync.files = mkIf (cfg.settings != {}) {
      "~/.claude.json" = {
        source = pkgs.writeText "claude-settings.json" (builtins.toJSON cfg.settings);
        repo = "decknix";
        repoPath = "modules/home/options/ai/claude.nix";
      };
    };

    # Merge the managed-tool allowlist into ~/.claude/settings.json.  This file
    # is *mutated by Claude at runtime* (e.g. it writes
    # `skipDangerousModePermissionPrompt`), so we must NOT deploy it as a whole
    # file (that would clobber Claude's keys, and agent-sync's whole-file
    # reconciliation would treat the pre-existing file as a conflict and never
    # apply our rules).  Instead we jq deep-merge only `.permissions.allow`
    # (union + unique), leaving every other key untouched.  Idempotent across
    # switches.
    home.activation.claude-permissions =
      mkIf (allowRules != [ ] || cfg.permissions.deny != [ ])
      (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        CLAUDE_SETTINGS="$HOME/.claude/settings.json"
        ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$CLAUDE_SETTINGS")"
        if [ ! -f "$CLAUDE_SETTINGS" ]; then
          echo '{}' > "$CLAUDE_SETTINGS"
        fi
        TMP="$(${pkgs.coreutils}/bin/mktemp)"
        if ${pkgs.jq}/bin/jq \
             --argjson add '${builtins.toJSON allowRules}' \
             --argjson deny '${builtins.toJSON cfg.permissions.deny}' \
             '.permissions = (.permissions // {})
              | .permissions.allow = (((.permissions.allow // []) + $add) | unique)
              | (if ($deny | length) > 0
                 then .permissions.deny = (((.permissions.deny // []) + $deny) | unique)
                 else . end)' \
             "$CLAUDE_SETTINGS" > "$TMP"; then
          ${pkgs.coreutils}/bin/mv "$TMP" "$CLAUDE_SETTINGS"
          echo "  [claude-permissions] Ensured ${toString (length allowRules)} allow + ${toString (length cfg.permissions.deny)} deny rule(s) in $CLAUDE_SETTINGS"
        else
          ${pkgs.coreutils}/bin/rm -f "$TMP"
          echo "  [claude-permissions] WARNING: failed to update $CLAUDE_SETTINGS (left unchanged)" >&2
        fi
      '');

    # Pin the runtime to the Nix-installed build (see `disableAutoUpdate').
    # Merged with jq for the same reason as the permissions block: Claude
    # mutates this file at runtime, so a whole-file deploy would clobber its
    # keys.  Only `.env.DISABLE_AUTOUPDATER' is touched.
    home.activation.claude-disable-autoupdate = mkIf cfg.disableAutoUpdate
      (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        CLAUDE_SETTINGS="$HOME/.claude/settings.json"
        ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$CLAUDE_SETTINGS")"
        if [ ! -f "$CLAUDE_SETTINGS" ]; then
          echo '{}' > "$CLAUDE_SETTINGS"
        fi
        TMP="$(${pkgs.coreutils}/bin/mktemp)"
        if ${pkgs.jq}/bin/jq \
             '.env = (.env // {}) | .env.DISABLE_AUTOUPDATER = "1"' \
             "$CLAUDE_SETTINGS" > "$TMP"; then
          ${pkgs.coreutils}/bin/mv "$TMP" "$CLAUDE_SETTINGS"
          echo "  [claude-disable-autoupdate] Pinned Claude to the Nix build (DISABLE_AUTOUPDATER=1)"
        else
          ${pkgs.coreutils}/bin/rm -f "$TMP"
          echo "  [claude-disable-autoupdate] WARNING: failed to update $CLAUDE_SETTINGS (left unchanged)" >&2
        fi
      '');

    # Reclaim `~/.local/bin/claude' from the native installer.
    #
    # `disableAutoUpdate' stops the CLI fetching NEW builds, but it does not
    # remove the ones already installed, and the installer's symlink still
    # shadows Nix: `~/.local/bin' is prepended to PATH (for tools with no Nix
    # equivalent), so `claude' resolved to
    # `~/.local/share/claude/versions/<v>' rather than the Nix build.
    # Measured on this machine 2026-10-01: Nix provided 2.1.220 while the
    # symlink pointed at 2.1.258, and the running session was executing
    # 2.1.257 -- three versions in play at once.
    #
    # Only a symlink INTO `~/.local/share/claude/' is removed.  A real file,
    # or a link to anywhere else, is left alone and reported: someone may
    # have put their own `claude' there deliberately, and silently deleting
    # it would be worse than the shadowing.
    #
    # PATH is deliberately NOT reordered to fix this.  `~/.local/bin' also
    # holds `nc-dos-rs' and `nc-health-kargo', which exist in Nix too, so
    # appending instead of prepending would change which of THOSE runs --
    # a much wider blast radius than the problem being solved.
    #
    # The versions directory itself is reported, not deleted: it was ~800MB
    # across four builds here, and reclaiming that much disk is the user's
    # call, not an activation script's.
    home.activation.claude-reclaim-native = mkIf cfg.disableAutoUpdate
      (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        LINK="$HOME/.local/bin/claude"
        NATIVE_DIR="$HOME/.local/share/claude"
        if [ -L "$LINK" ]; then
          TARGET="$(${pkgs.coreutils}/bin/readlink "$LINK")"
          case "$TARGET" in
            "$NATIVE_DIR"/*)
              ${pkgs.coreutils}/bin/rm -f "$LINK"
              echo "  [claude-reclaim-native] Removed $LINK -> $TARGET (Nix build now wins on PATH)"
              ;;
            *)
              echo "  [claude-reclaim-native] Left $LINK alone (points outside $NATIVE_DIR: $TARGET)"
              ;;
          esac
        elif [ -e "$LINK" ]; then
          echo "  [claude-reclaim-native] Left $LINK alone (not a symlink -- remove it yourself if unwanted)"
        fi
        if [ -d "$NATIVE_DIR/versions" ]; then
          SZ="$(${pkgs.coreutils}/bin/du -sh "$NATIVE_DIR/versions" 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1)"
          echo "  [claude-reclaim-native] $NATIVE_DIR/versions still holds $SZ of self-updated builds; remove it when convenient"
        fi
      '');

    # Merge Nix-declared MCP servers into ~/.claude.json.  Like settings.json
    # above, this file is *mutated by Claude at runtime* (skillUsage, cached*,
    # OAuth tokens, etc.), so we jq-merge only `.mcpServers` and leave every
    # other key alone.  Nix-declared entries win against runtime-added
    # entries of the same name (`* $add` — right side wins on conflict);
    # runtime-added entries with unrelated names are preserved.  Idempotent
    # across switches.
    home.activation.claude-mcp-servers = mkIf (cfg.mcpServers != {})
      (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        CLAUDE_JSON="$HOME/.claude.json"
        if [ ! -f "$CLAUDE_JSON" ]; then
          echo '{}' > "$CLAUDE_JSON"
        fi
        TMP="$(${pkgs.coreutils}/bin/mktemp)"
        if ${pkgs.jq}/bin/jq \
             --argjson add '${builtins.toJSON cfg.mcpServers}' \
             '.mcpServers = ((.mcpServers // {}) * $add)' \
             "$CLAUDE_JSON" > "$TMP"; then
          ${pkgs.coreutils}/bin/mv "$TMP" "$CLAUDE_JSON"
          echo "  [claude-mcp-servers] Merged ${toString (length (builtins.attrNames cfg.mcpServers))} managed MCP server(s) into $CLAUDE_JSON"
        else
          ${pkgs.coreutils}/bin/rm -f "$TMP"
          echo "  [claude-mcp-servers] WARNING: failed to update $CLAUDE_JSON (left unchanged)" >&2
        fi
      '');
  };
}
