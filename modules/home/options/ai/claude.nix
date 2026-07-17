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
    # via the Agent Client Protocol.  Managed by Nix; no manual npm install needed.
    home.packages = [ pkgs.claude-agent-acp ];

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
