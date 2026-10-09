# Gortex — code-intelligence graph served to every agent over MCP.
#
# Gortex indexes repositories into a knowledge graph so an agent answers a
# question with one graph query instead of a dozen file reads.  A single
# long-living daemon holds the graph for every tracked repo, and each agent
# connects to it through a thin `gortex mcp` stdio proxy (~5 MB per client) —
# so memory scales with the size of the workspace, not with how many agent
# sessions are open.  That property is what makes it viable here: this machine
# routinely has a dozen-plus agent-shell sessions live at once.
#
# Two deliberate departures from upstream's recommended setup, both to keep a
# single writer per file (see `AGENTS.md`, "Creating new tooling"):
#
#   1. We never run `gortex init` in a repository.  It generates CLAUDE.md,
#      .claude/skills/generated/, .claude/settings.json hooks and .mcp.json —
#      every one of which is already owned by `decknix.cli.agentSync`'s 3-way
#      reconciliation or by the workspace AGENTS.md.  Instead this module
#      contributes a `gortex` MCP server entry to each agent's own declarative
#      settings surface, which is the seam those modules already own.
#
#   2. Workspace slugs are recorded globally (`gortex workspace set --global`,
#      landing in ~/.gortex/config.yaml) rather than in a per-repo
#      `.gortex.yaml`.  The repos under this workspace are shared team repos;
#      a slug is a local indexing concern and has no business arriving in
#      someone else's checkout as an untracked file.  A repo that genuinely
#      wants an in-tree `.gortex.yaml` can still commit one — gortex's
#      precedence chain prefers it — but that is an explicit per-repo call,
#      not something this module does on your behalf.
#
# ~/.gortex/config.yaml is owned by GORTEX, not by Nix: `track`, `untrack` and
# `workspace set` all mutate it, and the daemon re-reads it on `reload`.  We
# therefore drive it through the CLI from an activation script rather than
# generating the file, which would fight the daemon for ownership.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix.ai.gortex;

  home = config.home.homeDirectory;

  expandTilde = p:
    if hasPrefix "~/" p then "${home}/${removePrefix "~/" p}" else p;

  roots = map expandTilde cfg.roster.roots;
  explicitRepos = map expandTilde cfg.roster.repos;

  gortexBin = "${cfg.package}/bin/gortex";

  orphanCleanup = pkgs.writeShellScript "gortex-orphan-cleanup" ''
    export PATH=${makeBinPath [ pkgs.coreutils pkgs.gawk ]}:$PATH
    ${builtins.readFile ./gortex-orphan-cleanup.sh}
  '';

  # The MCP client every agent spawns.  `--proxy` makes the absence of a
  # daemon a hard error rather than a silent fall back to an embedded,
  # single-repo graph that reports itself as DEGRADED: a quietly worse answer
  # is harder to notice than a missing one.
  mcpServerEntry = {
    type = "stdio";
    command = gortexBin;
    args = [ "mcp" "--proxy" ];
    env = { };
  };

  # Roster reconciliation.  Discovers the primary checkout of every git repo
  # under the configured roots and brings the daemon's tracked set in line
  # with it — tracking what is new, untracking what has gone.
  #
  # Worktrees are the interesting case.  decknix's workflow puts one worktree
  # per ticket under `{repo}-worktrees/{ticket}-{slug}`, so a busy week can
  # produce dozens of checkouts of the same repository.  Gortex resolves a
  # linked worktree back to its canonical repo (it reads the `commondir` file
  # that a worktree's gitdir carries and a submodule's does not), so tracking
  # the main checkout alone already covers them without N copies of the graph.
  # `worktrees = "independent"` opts into the other behaviour — one graph
  # instance per worktree, each indexed from its own branch — which is right
  # only when you genuinely need to query two branches side by side.
  rosterScript = pkgs.writeShellScript "gortex-roster-sync" ''
    set -uo pipefail
    export PATH=${makeBinPath [ pkgs.git pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.jq ]}:$PATH

    GORTEX=${gortexBin}

    # Indexer/control RPCs can wait on daemon checkout admission even for
    # `untrack' (observed >20 minutes on a removed checkout).  A graph is
    # optional; a switch must never wait indefinitely for its roster.
    reconcile() {
      if ! timeout --kill-after=2s 8s "$GORTEX" "$@"; then
        echo "gortex: $1 did not complete within 8s; retry on next switch" >&2
      fi
    }

    # A repo is "primary" when .git is a directory; a linked worktree carries
    # a .git *file*.  -prune stops the descent so we never walk node_modules
    # or a repo's own worktrees looking for nested checkouts.
    discover() {
      local root="$1"
      [ -d "$root" ] || return 0
      find "$root" -maxdepth ${toString cfg.roster.depth} -type d -name .git -prune 2>/dev/null \
        | while read -r gitdir; do dirname "$gitdir"; done
    }

    want=""
    for root in ${escapeShellArgs roots}; do
      want="$want$(discover "$root")"$'\n'
    done
    for repo in ${escapeShellArgs explicitRepos}; do
      [ -d "$repo" ] && want="$want$repo"$'\n'
    done
    ${optionalString (cfg.roster.excludeRegex != null) ''
      # -e, not a bare pattern: the natural exclude here is "-worktrees/",
      # and a pattern starting with "-" is otherwise parsed as a flag bundle
      # (BSD grep reads -w -o -r -k... and dies on "invalid option -- k").
      want=$(printf '%s' "$want" | grep -Ev -e ${escapeShellArg cfg.roster.excludeRegex} || true)
    ''}
    want=$(printf '%s' "$want" | grep -v '^$' | sort -u)

    # `repos` reports the tracked set as JSON (`[]` when nothing is tracked or
    # no daemon is up, rather than an error) — so a first run reconciles from
    # empty and `track` simply writes config for the daemon's next start.
    # Do not mistake an unresponsive daemon for an empty roster and try to
    # re-track every repo.  The outer activation deadline is a final guard.
    if ! have_json=$(timeout --kill-after=2s 8s "$GORTEX" repos --json 2>/dev/null); then
      echo "gortex: roster read timed out; leaving tracking unchanged" >&2
      exit 0
    fi
    if ! printf '%s' "$have_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
      echo "gortex: invalid roster response; leaving tracking unchanged" >&2
      exit 0
    fi
    have=$(printf '%s' "$have_json" | jq -r '.[].path' | sort -u)

    for repo in $want; do
      if ! printf '%s\n' "$have" | grep -qxF -e "$repo"; then
        echo "gortex: track $repo"
        reconcile track "$repo" ${optionalString (cfg.roster.worktrees == "independent") "--as-worktree"}
      fi
    done

    ${optionalString cfg.roster.prune ''
      for repo in $have; do
        if ! printf '%s\n' "$want" | grep -qxF -e "$repo"; then
          echo "gortex: untrack $repo (no longer under a configured root)"
          reconcile untrack "$repo"
        fi
      done
    ''}

    ${optionalString (cfg.workspaceSlugs != { }) ''
      # `workspace set` consults the daemon's current tracked-set, so we must
      # reload after any new `track`/`untrack` changes before assigning slugs.
      # Otherwise a freshly tracked repo can still look unknown until the next
      # daemon refresh and the activation emits noisy but harmless errors.
      timeout --kill-after=2s 8s "$GORTEX" daemon reload >/dev/null 2>&1 || true

      # Slugs recorded globally so no `.gortex.yaml` lands in a shared repo.
      # Normalize repo keys to absolute paths first; gortex matches against the
      # tracked absolute path, not the user-facing `~/...` spelling.
      ${concatStringsSep "\n" (mapAttrsToList (repo: slug: ''
        reconcile workspace set ${escapeShellArg (expandTilde repo)} ${escapeShellArg slug} --global
      '') cfg.workspaceSlugs)}
    ''}

    timeout --kill-after=2s 8s "$GORTEX" daemon reload >/dev/null 2>&1 || true
  '';
in
{
  options.decknix.ai.gortex = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Index tracked repositories into a Gortex knowledge graph and serve it
        to every configured agent over MCP.  On by default: one shared
        daemon, but initial and watched indexing consume CPU and disk even
        if agents do not issue queries.
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.gortex;
      defaultText = literalExpression "pkgs.gortex";
      description = "The gortex package to use.";
    };

    daemon = {
      enable = mkOption {
        type = types.bool;
        default = cfg.roster.roots != [ ] || cfg.roster.repos != [ ];
        defaultText = literalExpression "the roster is non-empty";
        description = ''
          Supervise the Gortex daemon with launchd so it starts at login and
          restarts on crash.

          Defaults on only once something is actually tracked.  A daemon
          holding an empty graph is a resident process answering no questions,
          so an install that has not declared a roster yet gets the package
          and the CLI without a service.

          Declared here rather than via `gortex daemon install-service` — that
          command writes ~/Library/LaunchAgents/com.zzet.gortex.plist itself,
          which would be an unmanaged file this config could neither reproduce
          on a fresh machine nor reason about.  Same rule as every other
          decknix service.
        '';
      };

      httpAddr = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "127.0.0.1:7411";
        description = ''
          Also expose the MCP Streamable-HTTP surface (`/mcp` + `/v1/*`) on
          this address, for editor plugins or dashboards that speak HTTP
          rather than stdio.  Null keeps the daemon on its Unix socket only.

          A loopback bind is reachable from any page the browser visits, so
          set `httpAuthTokenEnv` alongside it if you enable this.
        '';
      };

      httpAuthTokenEnv = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "GORTEX_DAEMON_HTTP_TOKEN";
        description = ''
          Name of the environment variable holding the bearer token required
          on every Streamable-HTTP request.  The token is read from the
          environment at run time and never written into the Nix store — the
          same rule the workspace applies to every other secret.
        '';
      };

      tools = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "core,-edit_file";
        description = ''
          Restrict the published MCP tool surface to a preset
          (`core` | `full` | `readonly` | `edit` | `nav`), optionally with
          `,+tool` / `,-tool` deltas.  Null takes gortex's own default
          (`core`).  Every published tool costs tokens in each agent's
          tool-list, so a narrower surface is not only a safety control.
        '';
      };

      logLevel = mkOption {
        type = types.enum [ "debug" "info" "warn" "error" ];
        default = "warn";
        description = ''
          Daemon log level.  Defaults to `warn` rather than gortex's `info`:
          at `info` the indexer emits a JSON line per phase per repo, which
          on a workspace this size buries anything worth seeing.
        '';
      };
    };

    roster = {
      roots = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "~/Code/nurturecloud" ];
        description = ''
          Directories to scan for git repositories to track.  Every primary
          checkout found under a root is tracked; linked worktrees are folded
          into their canonical repo (see `worktrees`).

          Note that an agent does not need the root itself tracked: opening an
          agent at a directory *above* the repos binds the session to the
          repos rooted under it, and to nothing else.
        '';
      };

      repos = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "~/tools/decknix" ];
        description = "Individual repository paths to track, in addition to anything found under `roots`.";
      };

      depth = mkOption {
        type = types.int;
        default = 3;
        description = ''
          How deep under a root to look for a `.git` directory.  The default
          reaches an org-workspace layout (`root/repo/.git`) and the
          worktree layout (`root/repo-worktrees/branch/.git`) without
          descending into vendored trees.
        '';
      };

      worktrees = mkOption {
        type = types.enum [ "canonical" "independent" ];
        default = "canonical";
        description = ''
          How to treat linked git worktrees.

          `canonical` (default) folds a worktree into the repository it shares
          a .git directory with, so one graph covers every checkout.  With one
          worktree per ticket, the alternative would mean indexing the same
          repository many times over for branches that differ by a handful of
          files.

          `independent` tracks each worktree as its own instance, indexed from
          its own branch — worth it only when you need to query two branches
          side by side, and priced accordingly in memory and index time.
        '';
      };

      excludeRegex = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "-worktrees/|/vendor/";
        description = "Extended-regex of discovered repository paths to skip.";
      };

      prune = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Untrack repositories the daemon still holds that no longer sit under
          any configured root — so a deleted clone stops consuming graph
          memory and stops appearing in query results.
        '';
      };
    };

    workspaceSlugs = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = literalExpression ''
        {
          "~/Code/nurturecloud/nct-public-api" = "nurturecloud";
          "~/Code/nurturecloud/upside" = "nurturecloud";
        }
      '';
      description = ''
        Pin repositories to a shared workspace slug so cross-repo analysis
        (contract matching, `find_usages` across a service boundary) sees them
        as one project.  By default each tracked repo is its own isolated
        workspace, which makes a producer and its consumer look like orphans.

        Recorded globally in ~/.gortex/config.yaml — no `.gortex.yaml` is
        written into a shared repository.
      '';
    };

    agents = {
      claude = mkOption {
        type = types.bool;
        default = true;
        description = "Wire the gortex MCP server into Claude Code (~/.claude.json).";
      };
      augment = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Wire the gortex MCP server into Augment (~/.augment/settings.json).

          Gortex ships no Augment adapter — it is not among the 20 registered
          ones — so unlike the other agents this is a hand-written MCP entry.
          Augment speaks MCP perfectly well, so the tool surface is identical;
          what is missing is the generated per-community skill files an
          official adapter would also write.
        '';
      };
      pi = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Wire gortex into Pi.

          Unlike the others this is NOT an MCP entry: Pi does not speak MCP at
          all (its help mentions it nowhere, and its settings carry no
          `mcpServers` key) — it loads *extensions*.  So gortex's Pi adapter
          installs `~/.pi/agent/extensions/gortex/index.ts` instead, which we
          drive with a tightly-scoped `gortex install --agents=pi`.

          `--no-claude-md --no-hooks` keep that invocation to the single Pi
          file; without them the same command would also merge a rule block
          into ~/.claude/CLAUDE.md and install user-level hooks, both of which
          are agentSync's to own.
        '';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      home.packages = [ cfg.package ];

      # Bounded best-effort reconciliation: never strand a system switch
      # behind an optional graph daemon.  A failed run retries next switch.
      home.activation.gortexRoster =
        config.lib.dag.entryAfter [ "writeBoundary" ] ''
          if ! $DRY_RUN_CMD ${pkgs.coreutils}/bin/timeout --kill-after=3s 60s ${rosterScript}; then
            echo "gortex: roster sync exceeded 60s; continuing activation" >&2
          fi
        '';
    }

    (mkIf cfg.daemon.enable {
      home.activation.gortexOrphanCleanup =
        config.lib.dag.entryAfter [ "gortexRoster" "setupLaunchAgents" ] ''
          if ! $DRY_RUN_CMD ${pkgs.coreutils}/bin/timeout --kill-after=2s 12s \
            ${orphanCleanup} ${escapeShellArg gortexBin} "$(${pkgs.coreutils}/bin/id -u)"; then
            echo "gortex: orphan cleanup failed or timed out; check old daemons" >&2
          fi
        '';

      launchd.agents.gortex = {
        enable = true;
        config = {
          ProgramArguments = [
            gortexBin
            "daemon"
            "start"
            "--log-level"
            cfg.daemon.logLevel
          ]
          # No --detach: launchd supervises the process itself, and a daemon
          # that forks away from its supervisor is one launchd will cheerfully
          # restart forever.
          ++ optionals (cfg.daemon.httpAddr != null) [ "--http-addr" cfg.daemon.httpAddr ]
          ++ optionals (cfg.daemon.tools != null) [ "--tools" cfg.daemon.tools ];

          RunAtLoad = true;
          KeepAlive = true;
          ProcessType = "Background";
          StandardOutPath = "${home}/.gortex/launchd.out.log";
          StandardErrorPath = "${home}/.gortex/launchd.err.log";
          EnvironmentVariables = {
            # A service supervisor starts with a near-empty environment; the
            # daemon otherwise resolves a different config/store root than the
            # shell does and would silently index into the wrong place.
            HOME = home;
            XDG_CONFIG_HOME = "${home}/.config";
            XDG_DATA_HOME = "${home}/.local/share";
            XDG_CACHE_HOME = "${home}/.cache";
          } // optionalAttrs (cfg.daemon.httpAuthTokenEnv != null) {
            # Named indirection only: the variable is resolved from the
            # daemon's environment at run time, so no token reaches the store.
            GORTEX_DAEMON_HTTP_TOKEN = "$\{${cfg.daemon.httpAuthTokenEnv}}";
          };
        };
      };
    })

    # --- MCP wiring: contribute to each agent's own settings surface --------
    # `mcpServers`, not `settings`: ~/.claude.json is mutated by Claude at
    # runtime (OAuth tokens, skillUsage, caches), and that option jq-merges
    # only the `.mcpServers` key while leaving every other one alone.  Going
    # through `settings` would hand the whole file to a second writer.
    (mkIf cfg.agents.claude {
      decknix.ai.claude.mcpServers.gortex = mcpServerEntry;
    })

    (mkIf cfg.agents.augment {
      decknix.cli.auggie.mcpServers.gortex = mcpServerEntry;
    })

    (mkIf cfg.agents.pi {
      home.activation.gortexPiExtension =
        config.lib.dag.entryAfter [ "writeBoundary" ] ''
          $DRY_RUN_CMD ${gortexBin} install --agents=pi \
            --no-claude-md --no-hooks >/dev/null 2>&1 || true
        '';
    })
  ]);
}
