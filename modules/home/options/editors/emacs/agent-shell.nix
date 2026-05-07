{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.agentShell;

  # == Tiered package sourcing ==
  # Priority: stable nixpkgs > unstable nixpkgs > custom derivations
  #
  # From unstable (not yet in stable, or stable version too old):
  #   shell-maker, acp, agent-shell
  # Custom derivations (not in any nixpkgs channel):
  #   agent-shell-manager, agent-shell-workspace, agent-shell-attention
  #
  # IMPORTANT: We take the source/recipe from unstable but rebuild using the
  # local emacsPackages (which uses the same Emacs as the daemon). This ensures
  # native-compiled .eln files match the running Emacs build hash, avoiding
  # JIT recompilation at startup.

  shell-maker = pkgs.emacsPackages.trivialBuild {
    pname = "shell-maker";
    version = pkgs.unstable.emacsPackages.shell-maker.version;
    src = pkgs.unstable.emacsPackages.shell-maker.src;
    packageRequires = with pkgs.emacsPackages; [ markdown-mode ];
  };

  acp = pkgs.emacsPackages.trivialBuild {
    pname = "acp";
    version = pkgs.unstable.emacsPackages.acp.version;
    src = pkgs.unstable.emacsPackages.acp.src;
  };

  agent-shell = pkgs.emacsPackages.trivialBuild {
    pname = "agent-shell";
    version = pkgs.unstable.emacsPackages.agent-shell.version;
    src = pkgs.unstable.emacsPackages.agent-shell.src;
    packageRequires = [ shell-maker acp ] ++ (with pkgs.emacsPackages; [ markdown-mode ]);
  };

  agent-shell-manager-el = pkgs.emacsPackages.trivialBuild {
    pname = "agent-shell-manager";
    version = "0-unstable-2026-03-17";
    src = pkgs.fetchFromGitHub {
      owner = "jethrokuan";
      repo = "agent-shell-manager";
      rev = "53b73f13ed1ac9d2de128465a8504a7265490ea7";
      hash = "sha256-JPB/OnOhYbM0LMirSYQhpB6hW8SAg0Ri6buU8tMP7rA=";
    };
    packageRequires = [ agent-shell ];
  };

  agent-shell-workspace-el = pkgs.emacsPackages.trivialBuild {
    pname = "agent-shell-workspace";
    version = "0-unstable-2026-03-17";
    src = pkgs.fetchFromGitHub {
      owner = "gveres";
      repo = "agent-shell-workspace";
      rev = "5d791c658b0692867c03a598ff4457599b5e20a5";
      hash = "sha256-durGK2f+Ovv5scbz4hv1k8nHeylgLNfHAR5tvQAifKI=";
    };
    packageRequires = [ agent-shell ];
  };

  agent-shell-attention-el = pkgs.emacsPackages.trivialBuild {
    pname = "agent-shell-attention";
    version = "0-unstable-2026-03-17";
    src = pkgs.fetchFromGitHub {
      owner = "ultronozm";
      repo = "agent-shell-attention.el";
      rev = "db89dc71e6e2ca5f0a6859ea9e9b183391614cea";
      hash = "sha256-bc5DjvGJnFBlsLtyYlN1hJQrcvK9khGaywtT37ACn+s=";
    };
    packageRequires = [ agent-shell ];
  };

  # == In-tree decknix Elisp packages ==
  # First-party Elisp moved out of the heredoc'd `extraConfig' below into
  # standalone files under `agent-shell/'.  Each derivation packages a
  # subdirectory whose .el files share a feature prefix; the directory
  # ends up on the daemon's `load-path' so `(require 'decknix-foo)' works.
  # External symbols defined elsewhere in this file's heredoc are forward-
  # declared inside the .el files via `declare-function' so byte-compile
  # stays warning-clean despite the split.
  #
  # Test policy: every in-tree package wires its ERT characterisation
  # suite into the build via `mkEmacsTestedPackage'.  Tests live in
  # `agent-shell/tests/' and are loaded after the package's own .el
  # files; a red test exits the byte-compile build non-zero, which
  # fails the system derivation.  No commit without a green build.
  testsDir = ./agent-shell/tests;
  mkEmacsTestedPackage = { pname, src, packageRequires ? [ ], testFiles }:
    (pkgs.emacsPackages.trivialBuild {
      inherit pname src packageRequires;
      version = "0.1";
    }).overrideAttrs (old: {
      postBuild = (old.postBuild or "") + ''
        echo "==> Running ERT characterisation tests for ${pname}"
        # Stage the test sources in a sibling tmp dir (NOT alongside
        # the package's own .el files) so they don't get picked up by
        # trivialBuild's `installPhase' and shipped into the daemon's
        # load-path or native-compiled.  The package dir stays on
        # `-L .' so the modules-under-test resolve via `require'.
        decknix_tests_dir=$(mktemp -d)
        cp ${testsDir}/decknix-test-helpers.el "$decknix_tests_dir/"
        ${lib.concatMapStringsSep "\n        "
          (f: ''cp ${testsDir}/${f} "$decknix_tests_dir/"'') testFiles}
        # Run with the same Emacs the build uses (already on $PATH via
        # nativeBuildInputs).  -Q skips user init; HOME is sandboxed by
        # the Nix builder so persistence tests can't escape.
        emacs -batch -Q \
          -L . \
          -L "$decknix_tests_dir" \
          -l ert \
          ${lib.concatMapStringsSep " \\\n          "
            (f: "-l ${lib.removeSuffix ".el" f}") testFiles} \
          -f ert-run-tests-batch-and-exit
        rm -rf "$decknix_tests_dir"
      '';
    });

  decknix-progress-el = mkEmacsTestedPackage {
    pname = "decknix-progress";
    src = ./agent-shell/progress;
    packageRequires = [ ];
    testFiles = [
      "decknix-progress-test.el"
      "decknix-progress-ui-test.el"
      "decknix-progress-sidebar-test.el"
    ];
  };

  decknix-hub-age-presets-el = mkEmacsTestedPackage {
    pname = "decknix-hub-age-presets";
    src = ./agent-shell/hub;
    packageRequires = [ ];
    testFiles = [
      "decknix-hub-age-presets-test.el"
    ];
  };

  decknix-sidebar-toggles-el = mkEmacsTestedPackage {
    pname = "decknix-sidebar-toggles";
    src = ./agent-shell/sidebar;
    # Sidebar saved-Sessions age toggle reuses the shared preset list
    # from decknix-hub-age-presets so labels stay aligned with Requests.
    packageRequires = [ decknix-hub-age-presets-el ];
    testFiles = [
      "decknix-sidebar-toggles-test.el"
    ];
  };

  decknix-sidebar-row-actions-el = mkEmacsTestedPackage {
    pname = "decknix-sidebar-row-actions";
    src = ./agent-shell/sidebar;
    # Co-resident with decknix-sidebar-toggles.el in the sidebar/ dir,
    # so trivialBuild byte-compiles both during this package's build.
    # Toggles `(require 'decknix-hub-age-presets)' at load-time, so
    # the dep must be on the load-path here too — even though
    # row-actions itself does not reference the presets.
    packageRequires = [ decknix-hub-age-presets-el ];
    testFiles = [
      "decknix-sidebar-row-actions-test.el"
    ];
  };

  # PR B.23: Previous-Sessions list + dedupe carved out of the
  # `cfg.workspace.enable' heredoc.  Pure list -> list helper plus
  # the in-memory list it operates on.  Co-resident in
  # `agent-shell/sidebar/' alongside the other sidebar primitives —
  # trivialBuild byte-compiles every sibling, so age-presets must
  # be on the load-path even though previous itself doesn't
  # reference it (sidebar-toggles requires it at load-time).
  decknix-sidebar-previous-el = mkEmacsTestedPackage {
    pname = "decknix-sidebar-previous";
    src = ./agent-shell/sidebar;
    packageRequires = [ decknix-hub-age-presets-el ];
    testFiles = [
      "decknix-sidebar-previous-test.el"
    ];
  };

  decknix-sidebar-format-el = mkEmacsTestedPackage {
    pname = "decknix-sidebar-format";
    src = ./agent-shell/sidebar;
    # Co-resident with decknix-sidebar-toggles.el — trivialBuild
    # byte-compiles every sibling, so age-presets must be on the
    # load-path even though format itself doesn't reference it.
    packageRequires = [ decknix-hub-age-presets-el ];
    testFiles = [
      "decknix-sidebar-format-test.el"
    ];
  };

  # PR B.29: sidebar tile-cycle helpers carved out of
  # `decknix-agent-shell-workspace' (workspace-bulk).  Owns the
  # desired-count defvar, the current-count reader, the one-shot
  # apply helper, the interactive `decknix-sidebar-tile-cycle'
  # command, and `decknix--sidebar-maybe-apply-tile-pref' (the
  # sidebar-refresh hook that re-engages tiling once enough live
  # buffers exist).  All four upstream symbols
  # (`agent-shell-buffers', `agent-shell-workspace--tile' /
  # `--untile', `agent-shell-workspace-sidebar-buffer-name', and
  # the buffer-local `--tiled' / `--tiled-buffers' flags) are
  # forward-declared so the module byte-compiles standalone.
  # Co-resident with the other sidebar/ modules; needs the same
  # `decknix-hub-age-presets-el' on packageRequires for the
  # trivialBuild sibling pass.
  decknix-sidebar-tile-el = mkEmacsTestedPackage {
    pname = "decknix-sidebar-tile";
    src = ./agent-shell/sidebar;
    packageRequires = [ decknix-hub-age-presets-el ];
    testFiles = [
      "decknix-sidebar-tile-test.el"
    ];
  };

  # PR B.35: sidebar width cycling carved out of
  # `decknix-agent-shell-workspace' (workspace-bulk).  Owns the
  # cycle state defvar (`decknix--sidebar-width-state'), the
  # restore-on-open helper (`decknix--sidebar-apply-width', wired
  # into the heredoc as advice on the sidebar opener), and the
  # interactive cycler (`decknix-sidebar-cycle-width', bound to
  # `W' in the toggles transient).  No external deps -- the two
  # upstream package vars `agent-shell-workspace-sidebar-buffer-
  # name' and `agent-shell-workspace-sidebar-width' are
  # forward-declared and resolved at runtime via the heredoc's
  # load order.  The persisted `width-state' value still travels
  # through `decknix--sidebar-state-file' (read/write in
  # workspace-bulk).
  decknix-sidebar-width-el = mkEmacsTestedPackage {
    pname = "decknix-sidebar-width";
    src = ./agent-shell/sidebar;
    # Sibling `decknix-sidebar-toggles.el' in the same `src' dir
    # transitively requires `decknix-hub-age-presets', so the
    # trivialBuild byte-compile pass needs that package on the
    # load-path even though `decknix-sidebar-width' itself has
    # no deps.  Mirrors `decknix-sidebar-tile-el' above.
    packageRequires = [ decknix-hub-age-presets-el ];
    testFiles = [
      "decknix-sidebar-width-test.el"
    ];
  };

  # PR B.38: sidebar nav transient item-command factory carved
  # out of `decknix-agent-shell-workspace' (workspace-bulk).  A
  # one-defun module -- `decknix--nav-make-item-cmd' -- minted as
  # its own package because it is the cleanest pure cell in the
  # workspace transient suffix machinery and serves as the seed
  # for a future `agent-shell/sidebar/nav-*' family of carved
  # transient helpers.  No external deps -- it only uses
  # `make-symbol' / `fset' / `eval'.  The four call-sites in
  # workspace-bulk (the section transients for Requests / WIP /
  # Live / Previous) reach the symbol through the heredoc's
  # `(require ...)' chain.  The same `decknix-hub-age-presets'
  # workaround as the other sidebar/ packages applies: sibling
  # `decknix-sidebar-toggles.el' transitively pulls it in during
  # the trivialBuild byte-compile pass.
  decknix-sidebar-nav-cmd-el = mkEmacsTestedPackage {
    pname = "decknix-sidebar-nav-cmd";
    src = ./agent-shell/sidebar;
    packageRequires = [ decknix-hub-age-presets-el ];
    testFiles = [
      "decknix-sidebar-nav-cmd-test.el"
    ];
  };

  # PR B.41: sidebar footer Navigate / Quick key alists carved
  # out of `decknix-agent-shell-workspace' (workspace-bulk).  Two
  # pure builders (`decknix--sidebar-footer-nav-keys' /
  # `-quick-keys') feeding the footer renderer at the single call
  # site in workspace-bulk (~line 1006).  The third footer
  # section (`-toggle-keys') stays in workspace-bulk -- it pulls
  # in ~15 hub-bulk free vars and faces, so carving it
  # cleanly needs a follow-up slice that also moves the toggle
  # state vars.  This module forward-declares
  # `decknix--sidebar-previous-sessions' (defined in
  # workspace-bulk) so the byte-compile stays warning-clean.
  # Same `decknix-hub-age-presets' workaround as the sibling
  # sidebar/ packages -- trivialBuild byte-compiles every .el in
  # the dir so the transitive requires must resolve.
  decknix-sidebar-footer-keys-el = mkEmacsTestedPackage {
    pname = "decknix-sidebar-footer-keys";
    src = ./agent-shell/sidebar;
    packageRequires = [ decknix-hub-age-presets-el ];
    testFiles = [
      "decknix-sidebar-footer-keys-test.el"
    ];
  };

  # PR B.32: xwidget-webkit page-text + window.find JS-bridge
  # primitives carved out of `decknix-agent-shell-workspace'
  # (workspace-bulk).  Co-resident in a new `agent-shell/webkit/'
  # dir so future webkit helpers (history JSON parsing, link
  # extraction, copy-as-markdown) have a topical home rather than
  # accumulating in workspace-bulk.  Owns the search history
  # defvar shared with the consult-line interactive command (still
  # in workspace-bulk per Rule 2 -- consult UI + WebKit keymap
  # binding are heredoc-side concerns).
  decknix-webkit-page-el = mkEmacsTestedPackage {
    pname = "decknix-webkit-page";
    src = ./agent-shell/webkit;
    packageRequires = [ ];
    testFiles = [
      "decknix-webkit-page-test.el"
    ];
  };

  decknix-hub-teamcity-el = mkEmacsTestedPackage {
    pname = "decknix-hub-teamcity";
    src = ./agent-shell/hub;
    # Co-resident with decknix-hub-age-presets.el in the hub/ dir,
    # so trivialBuild byte-compiles both during this package's build.
    # The dep is symmetric: building age-presets above byte-compiles
    # this file as a sibling, so its packageRequires is empty too;
    # the cross-link is only needed if one ever `require's the other.
    packageRequires = [ ];
    testFiles = [
      "decknix-hub-teamcity-test.el"
    ];
  };

  decknix-hub-org-filter-el = mkEmacsTestedPackage {
    pname = "decknix-hub-org-filter";
    src = ./agent-shell/hub;
    # Co-resident with the other hub/ modules; trivialBuild byte-compiles
    # all siblings so packageRequires can stay empty until one explicitly
    # `require's another.
    packageRequires = [ ];
    testFiles = [
      "decknix-hub-org-filter-test.el"
    ];
  };

  decknix-hub-jira-tasks-el = mkEmacsTestedPackage {
    pname = "decknix-hub-jira-tasks";
    src = ./agent-shell/hub;
    packageRequires = [ ];
    testFiles = [
      "decknix-hub-jira-tasks-test.el"
    ];
  };

  decknix-hub-ci-el = mkEmacsTestedPackage {
    pname = "decknix-hub-ci";
    src = ./agent-shell/hub;
    # Co-resident with the other hub/ modules; trivialBuild byte-compiles
    # all siblings so packageRequires can stay empty until one explicitly
    # `require's another.
    packageRequires = [ ];
    testFiles = [
      "decknix-hub-ci-test.el"
    ];
  };

  # PR B.30: CI status filter state + helpers carved out of
  # `decknix-agent-shell-hub' (hub-bulk).  Owns the visible-status
  # list, the canonical render-order alist, the predicates
  # (`status-of', `visible-p'), the propertised footer summary,
  # the per-bucket toggle commands wired to the transient suffixes
  # in hub-bulk, the `show-all' / `show-none' bulk verbs, and the
  # transient row-description builder.  Depends on
  # `decknix-hub-ci' for the classification primitive
  # (`decknix--hub-ci-classify') used by `status-of'; the transient
  # suffix / prefix forms stay in hub-bulk because they wire into
  # the broader sidebar transient cluster there.
  decknix-hub-ci-filter-el = mkEmacsTestedPackage {
    pname = "decknix-hub-ci-filter";
    src = ./agent-shell/hub;
    packageRequires = [ ];
    testFiles = [
      "decknix-hub-ci-filter-test.el"
    ];
  };

  # PR B.33: Requests + WIP attention filter cluster carved out of
  # `decknix-agent-shell-hub' (hub-bulk).  Owns the seven toggle
  # state defvars (Requests/WIP needs-reply / bot-pending / only-
  # my-replies plus Requests sort-reverse), the engine
  # (`sort-requests', the shared `attention-visible-p' predicate
  # and its Requests/WIP wrappers), the shared `toggle-and-refresh'
  # helper, and the seven per-bucket toggle commands wired to the
  # sidebar Toggles transient (`T') and footer.  The transient
  # suffix / prefix forms in hub-bulk and workspace-bulk stay
  # there per AGENTS.md Rule 2 (transient UI is heredoc-side).
  decknix-hub-attention-filter-el = mkEmacsTestedPackage {
    pname = "decknix-hub-attention-filter";
    src = ./agent-shell/hub;
    packageRequires = [ ];
    testFiles = [
      "decknix-hub-attention-filter-test.el"
    ];
  };

  # PRs B.50 + B.51: "ready for review" reader carved out of
  # `decknix-agent-shell-workspace' (workspace-bulk).  Co-resident
  # with the rest of the hub/ filter cluster.  Owns three symbols:
  # `decknix--hub-request-ready-p' (B.50, the four-clause pure
  # predicate over a single review-request alist),
  # `decknix--hub-review-ready-requests' (B.51, the reader over
  # `decknix--hub-reviews' that composes the predicate with the six
  # carved visibility filters), and `decknix--hub-review-entries'
  # (B.51, the entry builder that turns the ready subset into the
  # `(LABEL . ITEM)' cons cells the `r' picker consumes).  Depends
  # on `decknix--hub-ci-classify' from `decknix-hub-ci' for the CI
  # status step; the visibility predicates are reached via
  # `declare-function' to avoid pulling the carved filter packages
  # into the package's compile graph (they're already required by
  # the heredoc next to this one).  No side effects, no UI.

  decknix-hub-ready-filter-el = mkEmacsTestedPackage {
    pname = "decknix-hub-ready-filter";
    src = ./agent-shell/hub;
    packageRequires = [ ];
    testFiles = [
      "decknix-hub-ready-filter-test.el"
    ];
  };

  # PR B.36: repo-name cap cluster carved out of
  # `decknix-agent-shell-hub' (hub-bulk).  Decides how aggressively
  # the repo segment of an ungrouped PR line is truncated when
  # rendered in the sidebar.  Owns the cap state defvar
  # (`decknix--hub-repo-name-cap'), the pure truncator
  # (`decknix--hub-repo-name-apply'), and the interactive cycler
  # (`decknix--hub-cycle-repo-name-cap').  No external deps -- the
  # sidebar refresh callback is gated by a `get-buffer' check.
  # The transient suffix surfacing the cycler in the sidebar
  # Toggles transient (`N') stays in hub-bulk per AGENTS.md
  # Rule 2.
  decknix-hub-repo-name-el = mkEmacsTestedPackage {
    pname = "decknix-hub-repo-name";
    src = ./agent-shell/hub;
    packageRequires = [ ];
    testFiles = [
      "decknix-hub-repo-name-test.el"
    ];
  };

  # PR B.39: WIP "hide linked" toggle carved out of
  # `decknix-agent-shell-hub' (hub-bulk).  When non-nil (the
  # default), PRs that already have a live agent-shell session
  # are hidden from the WIP section so the row doesn't duplicate
  # noise the live row is already showing.  Owns the toggle
  # state defvar (`decknix--hub-wip-hide-linked', default `t')
  # and the interactive flipper (`decknix--hub-toggle-wip-hide-
  # linked').  No external deps -- the sidebar refresh callback
  # is gated by a `get-buffer' check so calling the toggle
  # before the sidebar exists is a no-op.  The transient suffix
  # surfacing the toggle in the WIP section of the sidebar
  # Toggles transient (`L') stays in hub-bulk per AGENTS.md
  # Rule 2.
  decknix-hub-wip-link-filter-el = mkEmacsTestedPackage {
    pname = "decknix-hub-wip-link-filter";
    src = ./agent-shell/hub;
    packageRequires = [ ];
    testFiles = [
      "decknix-hub-wip-link-filter-test.el"
    ];
  };

  decknix-hub-mention-bot-el = mkEmacsTestedPackage {
    pname = "decknix-hub-mention-bot";
    src = ./agent-shell/hub;
    packageRequires = [ ];
    testFiles = [
      "decknix-hub-mention-bot-test.el"
    ];
  };

  decknix-hub-worktree-parse-el = mkEmacsTestedPackage {
    pname = "decknix-hub-worktree-parse";
    src = ./agent-shell/hub;
    packageRequires = [ ];
    testFiles = [
      "decknix-hub-worktree-parse-test.el"
    ];
  };

  decknix-hub-icons-el = mkEmacsTestedPackage {
    pname = "decknix-hub-icons";
    src = ./agent-shell/hub;
    # Cross-package require: pulls in `decknix--hub-icon' from the
    # co-resident decknix-hub-ci.el (also in this src dir, so the
    # daemon resolves it via load-path without a packageRequires
    # declaration).
    packageRequires = [ ];
    testFiles = [
      "decknix-hub-icons-test.el"
    ];
  };

  # PR B.24: PR status cache + persistence carved out of
  # `decknix-agent-shell-hub' (hub-bulk).  Owns the URL -> status
  # hash, its TTL constants, and the on-disk save/restore pair.
  # Co-resident in `agent-shell/hub/' alongside the other hub
  # primitives; trivialBuild byte-compiles every sibling here so
  # packageRequires stays empty (none of the other hub/ modules
  # `require' this one at load-time).
  decknix-hub-pr-cache-el = mkEmacsTestedPackage {
    pname = "decknix-hub-pr-cache";
    src = ./agent-shell/hub;
    packageRequires = [ ];
    testFiles = [
      "decknix-hub-pr-cache-test.el"
    ];
  };

  # PR B.27: Repo HEAD status cache + persistence carved out of
  # hub-bulk, direct parallel to `decknix-hub-pr-cache' above.
  # Owns the "OWNER/REPO#BRANCH" -> status hash, its TTL constant,
  # and the on-disk save/restore pair.  The cache reader
  # (`decknix--hub-repo-cache-get') and orchestrator
  # (`decknix--hub-repo-status') stay in hub-bulk because they
  # call the async fetcher; this slice is the persistence layer
  # only.  Co-resident with the other hub/ modules; packageRequires
  # empty for the same reason as the PR-cache slice.
  decknix-hub-repo-cache-el = mkEmacsTestedPackage {
    pname = "decknix-hub-repo-cache";
    src = ./agent-shell/hub;
    packageRequires = [ ];
    testFiles = [
      "decknix-hub-repo-cache-test.el"
    ];
  };

  decknix-hub-pr-lookup-el = mkEmacsTestedPackage {
    pname = "decknix-hub-pr-lookup";
    # Isolated in its own src dir (`hub-lookup/') rather than the
    # shared `hub/' tree because it cross-`require's the agent/
    # `decknix-agent-url-parse' package.  Trivial-build byte-compiles
    # every .el in src, so dropping pr-lookup into hub/ would force
    # *every* hub package to declare agent-url-parse in their
    # packageRequires (since the shared src dir means every hub build
    # would try to compile pr-lookup as a sibling).  Keeping it apart
    # confines the dep declaration to this entry alone.
    src = ./agent-shell/hub-lookup;
    packageRequires = [ decknix-agent-url-parse-el ];
    testFiles = [
      "decknix-hub-pr-lookup-test.el"
    ];
  };

  decknix-agent-url-parse-el = mkEmacsTestedPackage {
    pname = "decknix-agent-url-parse";
    src = ./agent-shell/agent;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-url-parse-test.el"
    ];
  };

  decknix-agent-format-el = mkEmacsTestedPackage {
    pname = "decknix-agent-format";
    src = ./agent-shell/agent;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-format-test.el"
    ];
  };

  decknix-agent-parse-el = mkEmacsTestedPackage {
    pname = "decknix-agent-parse";
    src = ./agent-shell/agent;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-parse-test.el"
    ];
  };

  # PR B.22: session list cache + jq fetcher carved out of
  # `decknix-agent-shell-main' (main-bulk).  Co-resident in
  # `agent-shell/agent/' with `decknix-agent-parse' which it
  # depends on at load time.
  decknix-agent-session-cache-el = mkEmacsTestedPackage {
    pname = "decknix-agent-session-cache";
    src = ./agent-shell/agent;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-session-cache-test.el"
    ];
  };

  # PR B.52: local session JSON path builder + pure history
  # extractor carved out of `decknix-agent-shell-main' (main-bulk).
  # Co-resident with the rest of the agent/ persistence cluster.
  # Owns the path helper (`decknix--agent-session-file') and the
  # turn-grouping reader (`decknix--agent-session-extract-history')
  # that drives `decknix--agent-session-prepopulate' (still in
  # main-bulk -- side-effecting buffer write per AGENTS.md Rule 2)
  # and the timeline / jump-to-match helpers.  Both functions are
  # pure: only filesystem reads + cons cells, no global state.
  decknix-agent-session-history-el = mkEmacsTestedPackage {
    pname = "decknix-agent-session-history";
    src = ./agent-shell/agent;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-session-history-test.el"
    ];
  };

  # PR B.28: tag-store JSON persistence + cache carved out of
  # `decknix-agent-shell-main' (main-bulk).  Owns the file path
  # defvar, the four cache state vars (hash + mtime + checked-at +
  # TTL), the `read'/`write'/`conversations' triple, and the
  # v1->v2 auto-migration walk inside `read'.  Co-resident with
  # the other agent/ modules; the migration walk forward-declares
  # `decknix--agent-session-list' (sibling
  # `decknix-agent-session-cache' package, required first by the
  # heredoc) and `decknix--agent-conversation-key' (still in
  # main-bulk because it threads mergedInto-redirect resolution
  # back through this very store).  Both resolve at call time.
  decknix-agent-tags-store-el = mkEmacsTestedPackage {
    pname = "decknix-agent-tags-store";
    src = ./agent-shell/agent;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-tags-store-test.el"
    ];
  };

  decknix-agent-vcs-el = mkEmacsTestedPackage {
    pname = "decknix-agent-vcs";
    src = ./agent-shell/agent;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-vcs-test.el"
    ];
  };

  # PR B.31: per-conversation link store carved out of
  # `decknix-agent-shell-main' (main-bulk).  Owns the seven
  # mutators over the `linked_prs' record set inside the
  # conversation entry of `agent-sessions.json' (PR + repo
  # records share the same key for backward compat).  Loads
  # `decknix-agent-tags-store' for the JSON I/O and
  # `decknix-agent-url-parse' for URL validation.  Hub-side
  # post-mutation callbacks (`decknix--hub-write-linked-prs',
  # `decknix--hub-pr-fetch-async', `decknix--hub-repo-fetch-async')
  # are gated through `fboundp' so this module loads cleanly even
  # when the hub feature is disabled.
  decknix-agent-link-store-el = mkEmacsTestedPackage {
    pname = "decknix-agent-link-store";
    src = ./agent-shell/agent;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-link-store-test.el"
    ];
  };

  # PR B.34: conversation-key derivation + mergedInto resolution
  # carved out of `decknix-agent-shell-main' (main-bulk).  Owns the
  # canonical four-function cluster that bridges the raw SHA-256
  # hash from `decknix-agent-parse', the `mergedInto' redirect
  # walker that consults `decknix-agent-tags-store', and the two
  # session-aware lookups that read `decknix-agent-session-cache'.
  # Pure resolution layer -- the heredoc and the bulk modules call
  # these from ~30 sites every time a first-message is hashed to a
  # conv-key, so loading order in the heredoc places this module
  # immediately after `decknix-agent-tags-store' and
  # `decknix-agent-session-cache'.
  decknix-agent-conv-resolve-el = mkEmacsTestedPackage {
    pname = "decknix-agent-conv-resolve";
    src = ./agent-shell/agent;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-conv-resolve-test.el"
    ];
  };

  # PR B.37: per-conversation auggie model overrides carved out
  # of `decknix-agent-shell-main' (main-bulk).  Sits beside
  # `decknix-agent-tags-store' / `-link-store' / `-conv-resolve'
  # in `agent-shell/agent/' as a small persistence module
  # owning the two storage primitives that mediate the
  # `~/.config/decknix/agent-sessions.json' "model" field.  The
  # interactive command that wraps the upstream
  # `agent-shell-set-session-model' (`decknix-agent-set-session-
  # model') stays in main-bulk per AGENTS.md Rule 2 -- it is a
  # UI verb whose on-success callback simply calls into this
  # module's `save' primitive.  Loaded at the same point in the
  # heredoc as the other agent/ persistence helpers so the
  # resume-time read at main-bulk:815 resolves the symbol.
  decknix-agent-session-model-el = mkEmacsTestedPackage {
    pname = "decknix-agent-session-model";
    src = ./agent-shell/agent;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-session-model-test.el"
    ];
  };

  # PR B.49: clipboard URL DWIM helper carved out of
  # `decknix-agent-shell-main' (main-bulk).  Co-resident with the
  # rest of the agent/ cluster.  Owns the tiny kill-ring +
  # pbpaste reader used as the `read-string' default in the
  # PR-quick-action and review prompts.  Pure I/O helper -- no
  # global state.
  decknix-agent-clipboard-el = mkEmacsTestedPackage {
    pname = "decknix-agent-clipboard";
    src = ./agent-shell/agent;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-clipboard-test.el"
    ];
  };

  # PR B.48: current/require session-id + conv-key accessors
  # carved out of `decknix-agent-shell-main' (main-bulk).  Co-
  # resident with the rest of the agent/ persistence + detection
  # cluster.  Owns the read-only `-current-session-id' plus the
  # two error-raising require helpers used as the first form in
  # almost every interactive command that operates on the current
  # session.  The buffer-local `decknix--agent-auggie-session-id'
  # defvar stays in main-bulk -- it is initialised inside the
  # agent-shell startup hook (a side-effect that belongs in the
  # heredoc by Rule 2).
  decknix-agent-session-id-el = mkEmacsTestedPackage {
    pname = "decknix-agent-session-id";
    src = ./agent-shell/agent;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-session-id-test.el"
    ];
  };

  # PR B.46: custom auggie command discovery carved out of
  # `decknix-agent-shell-main' (main-bulk).  Co-resident with the
  # rest of the agent/ persistence + detection cluster.  Owns the
  # user-tunable `decknix--agent-command-dirs' defvar plus the two
  # pure scanners that back the `decknix-agent-command-{run,new,
  # edit}' commands and the inline command-files lookup in the
  # session-grep annotation path (~main-bulk:362).  Fully pure --
  # only filesystem reads via `directory-files' and `with-temp-
  # buffer' over the YAML frontmatter.
  decknix-agent-command-discover-el = mkEmacsTestedPackage {
    pname = "decknix-agent-command-discover";
    src = ./agent-shell/agent;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-command-discover-test.el"
    ];
  };

  # PR B.45: workspace + branch detection helpers carved out
  # of `decknix-agent-shell-main' (main-bulk).  Co-resident with
  # the rest of the agent/ persistence + detection cluster.
  # Owns the three pure detectors that the session-creation /
  # PR-quick-action flows use to suggest a workspace directory
  # and the current git branch, plus the user-tunable
  # `decknix-agent-workspace-roots' defvar that seeds the third
  # tier of the PR lookup heuristic.  The two cross-bulk call
  # sites in workspace-bulk (~lines 1330 / 1579, both inside
  # `fboundp' guards in the PR review quick-action picker)
  # reach `decknix--agent-pr-detect-workspace' through the
  # heredoc's `(require ...)' chain.
  decknix-agent-workspace-detect-el = mkEmacsTestedPackage {
    pname = "decknix-agent-workspace-detect";
    src = ./agent-shell/agent;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-workspace-detect-test.el"
    ];
  };

  # PR B.43: tags read accessors carved out of
  # `decknix-agent-shell-main' (main-bulk).  Co-resident in
  # `agent-shell/agent/' beside the existing
  # `decknix-agent-tags-store' (which owns load / save /
  # conversations) and the per-conversation persistence pairs.
  # Owns the two pure read accessors that resolve a session-id
  # or a conv-key to the conversation's tag list.  The many
  # call sites in main-bulk / workspace-bulk / progress / nix
  # heredoc reach the symbols through the heredoc's
  # `(require ...)' chain.
  decknix-agent-tags-read-el = mkEmacsTestedPackage {
    pname = "decknix-agent-tags-read";
    src = ./agent-shell/agent;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-tags-read-test.el"
    ];
  };

  # PR B.42: per-conversation lastAccessed stamp carved out
  # of `decknix-agent-shell-main' (main-bulk).  Sister of B.37 /
  # B.40 in the `agent-shell/agent/' persistence cluster.  Owns
  # the touch / last-accessed pair that mediates the
  # `~/.config/decknix/agent-sessions.json' "lastAccessed"
  # field, used by user-facing operations (tag, rename, resume,
  # create) to bump a conversation's recency for the
  # conversation-grouped picker's sort.  Loaded at the same point
  # in the heredoc as the other agent/ persistence helpers so
  # the two call sites in main-bulk (~lines 895 / 991-992)
  # resolve cleanly.
  decknix-agent-conv-recency-el = mkEmacsTestedPackage {
    pname = "decknix-agent-conv-recency";
    src = ./agent-shell/agent;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-conv-recency-test.el"
    ];
  };

  # PR B.40: per-conversation workspace persistence carved out
  # of `decknix-agent-shell-main' (main-bulk).  Sits beside
  # `decknix-agent-session-model' in `agent-shell/agent/' as a
  # parallel persistence module owning the three storage
  # primitives that mediate the
  # `~/.config/decknix/agent-sessions.json' "workspace" field --
  # one reader, one direct writer (CONV-KEY known) and one
  # session-id-resolved writer that hops through
  # `decknix--agent-conversation-key-for-session'.  Loaded at
  # the same point in the heredoc as the other agent/
  # persistence helpers so the resume-time reads at main-bulk
  # (lines 1016 / 1123 / 1141 / 1550 / 2023 / 4663) and the
  # workspace-bulk picker (lines 1071 / 3545) resolve cleanly.
  decknix-agent-session-workspace-el = mkEmacsTestedPackage {
    pname = "decknix-agent-session-workspace";
    src = ./agent-shell/agent;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-session-workspace-test.el"
    ];
  };

  decknix-agent-review-format-el = mkEmacsTestedPackage {
    pname = "decknix-agent-review-format";
    src = ./agent-shell/review;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-review-format-test.el"
    ];
  };

  # PR B.47: review @mention author + collaborators store carved
  # out of `decknix-agent-shell-main' (main-bulk).  Co-resident
  # with `decknix-agent-review-format' under `agent-shell/review'.
  # Owns the three user-tunable defvars (`-author', `-collaborators',
  # `-collaborators-file') plus the three accessors that back the
  # `decknix-agent-review-mode' @mention picker, the heredoc
  # yasnippet bodies (`,c' / `,a' / `,r' / `,o' / `,m' / `,f'),
  # and the `decknix-agent-review-add-collaborator' command.
  decknix-agent-review-collaborators-el = mkEmacsTestedPackage {
    pname = "decknix-agent-review-collaborators";
    src = ./agent-shell/review;
    packageRequires = [ ];
    testFiles = [
      "decknix-agent-review-collaborators-test.el"
    ];
  };

  # PR B-Bulk.1: bulk extraction of the context-panel sub-heredoc.
  # Verbatim move of 35 declarations (576 lines of forms + commentary)
  # from the four `+ optionalString cfg.context.enable ''..''` sub-heredocs
  # into a single .el file packaged via plain trivialBuild.  Tests are
  # deferred (FIXME(arch-debt)) until follow-up B.22+ PRs slice the
  # module into individually-tested feature units.  The package's
  # `(require ...)' lives back in `cfg.context.enable' so the
  # cross-feature `fboundp' guards in main/workspace stay correct
  # (`fboundp' returns nil iff the module is not loaded).
  decknix-agent-shell-context-el = pkgs.emacsPackages.trivialBuild {
    pname = "decknix-agent-shell-context";
    version = "0.1";
    src = ./agent-shell/context;
    packageRequires = [ ];
  };

  # PR B-Bulk.2: bulk extraction of the two cfg.hub.enable sub-heredocs.
  # Verbatim move of 167 declarations (162 from hub-A + 5 from hub-B,
  # roughly 2,800 lines of forms + commentary) into a single .el file
  # packaged via plain trivialBuild.  Lives in its own `hub-bulk/' src
  # dir (not `hub/') so trivialBuild does not byte-compile this 3000-line
  # file as a sibling of every individually-tested hub helper module —
  # those packages stay independently fast to rebuild.  Tests are
  # deferred (FIXME(arch-debt)); follow-up B.22+ PRs slice this into
  # tested sub-modules using `mkEmacsTestedPackage'.  The 7 helper
  # `(require 'decknix-hub-...)' calls and all top-level side-effects
  # (cache restores, watcher start, advice on
  # `agent-shell-workspace-sidebar-refresh', timers) stay in the
  # heredoc immediately after the
  # `(require 'decknix-agent-shell-hub)' line so load-order
  # semantics and the 22 cross-feature `fboundp' guards stay correct.
  decknix-agent-shell-hub-el = pkgs.emacsPackages.trivialBuild {
    pname = "decknix-agent-shell-hub";
    version = "0.1";
    src = ./agent-shell/hub-bulk;
    packageRequires = [ ];
  };

  # PR B-Bulk.3a: bulk extraction of the always-loaded core (always-1
  # + always-tail sub-heredocs).  Verbatim move of 254 declarations
  # (~4,800 lines) packaged via plain trivialBuild, isolated in its
  # own `main-bulk/' src dir to keep co-resident byte-compilation off
  # other in-tree modules.  Always loaded — there is no feature gate
  # for the agent-shell core.  Tests deferred (FIXME(arch-debt)).
  decknix-agent-shell-main-el = pkgs.emacsPackages.trivialBuild {
    pname = "decknix-agent-shell-main";
    version = "0.1";
    src = ./agent-shell/main-bulk;
    packageRequires = [ ];
  };

  # PR B-Bulk.3b: bulk extraction of the cfg.workspace.enable
  # sub-heredoc.  Verbatim move of 197 declarations (~3,500 lines)
  # including the `decknix--sb-stub' macro and its 9 placeholder
  # transient suffix expansions (which travel together).  Packaged
  # via plain trivialBuild in its own `workspace-bulk/' src dir so
  # trivialBuild doesn't byte-compile this 4,000-line file as a
  # sibling of every individually-tested workspace helper module
  # (sidebar-format, sidebar-toggles, sidebar-row-actions).  Tests
  # deferred (FIXME(arch-debt)).  The 14 cross-feature `fboundp'
  # guards on hub symbols stay correct because the hub bulk module
  # is gated independently by cfg.hub.enable.
  decknix-agent-shell-workspace-el = pkgs.emacsPackages.trivialBuild {
    pname = "decknix-agent-shell-workspace";
    version = "0.1";
    src = ./agent-shell/workspace-bulk;
    packageRequires = [ ];
  };

  # == Custom auggie commands ==
  # Deployed to ~/.augment/commands/ via home.file (as symlinks).
  # User-created commands (regular files) coexist in the same directory
  # and are not affected by Nix. On `decknix switch`, Nix-managed ones
  # are refreshed; runtime-created ones persist.
  commandDir = ".augment/commands";

  commands = {
    "start.md" = ''
      ---
      description: Create a new session and rename it, optionally from a Jira ticket key
      argument-hint: [session name or JIRA-KEY]
      ---

      Create a new Augment session and rename it in one step.

      **Instructions:**

      1. **Parse the argument:** The user provides `$ARGUMENTS` which can be:
         - A **Jira ticket key** (e.g., `ALR-4268`, `ARC-10308`) — detected by matching the pattern `[A-Z]+-\d+`
         - A **plain session name** (e.g., "proptrack pubsub fix")
         - **Empty** — prompt the user for a name

      2. **If a Jira ticket key is detected:**
         - Fetch the ticket summary from Jira using the Jira API tool: `GET /issue/{key}` with fields `summary,status,assignee,parent`
         - If the ticket has a parent, also fetch the parent summary
         - Construct the session name as: `{KEY}: {parent summary or ticket summary}`
         - Display the ticket details briefly:
           ```
           📋 {KEY}: {summary}
           📌 Status: {status} | Assignee: {assignee or "Unassigned"}
           🏷️ Session: {constructed name}
           ```

      3. **Inform the user** that `/new` and `/rename` are built-in commands that cannot be invoked programmatically from within a session. Instead, provide the exact commands to run:

         ```
         To start this session, run these commands:

         /new
         /rename {session name}
         ```

         If the session name contains special characters, wrap it in quotes.

      4. **Offer to set up context** for the new session:
         - Ask if they'd like a brief summary of the current session to carry forward
         - If yes, generate a 3-5 bullet summary of key decisions, findings, and next steps from the current conversation
    '';



    "pivot-conversation.md" = ''
      ---
      description: Hard pivot — discard current plan and re-evaluate with new context
      argument-hint: [new direction or constraint]
      ---

      **[SYSTEM OVERRIDE: HARD PIVOT INITIATED]**

      Stop your current execution path immediately. I am injecting new information, constraints, or a change in direction that supersedes your previous plan.

      Please execute the following steps strictly in order:
      1. **Halt and Discard:** Discard the immediate next steps or tool calls you were just about to execute.
      2. **Ingest New Context:** Carefully review the new information I have provided in my prompt alongside this command.
      3. **Analyze the Impact:** Briefly explain (in 1-2 sentences) how this new information changes our current approach or invalidates your previous assumptions.
      4. **State the New Plan:** Provide a concise, bulleted list of the exact next steps you will take based on this pivot.
      5. **Wait for Approval:** Do NOT write any code, modify any files, or execute any terminal commands until I explicitly approve your new plan.
    '';

    "step-back.md" = ''
      ---
      description: Stop, summarize progress, and wait for direction
      ---

      Stop your current execution path.
      1. Summarize exactly what you have modified so far.
      2. List the specific errors or roadblocks you are encountering.
      3. Wait for my explicit direction before writing any more code or executing any more terminal commands.
    '';

  };

  # == User-level augment guidelines ==
  # Deployed to ~/.augment-guidelines via home.file (as a symlink).
  # Provides default formatting/response rules for Augment agents.
  guidelinesFile = ".augment-guidelines";
  guidelinesContent = ''
    # Augment Agent Guidelines (User-level)

    These rules apply globally across ALL workspaces. Workspace-level
    AGENTS.md files may add project-specific rules but should not need
    to repeat these.

    ## Command Execution — Prefer Nix-managed Tools

    This is a Nix-managed macOS system. All tooling is installed via Nix.

    1. **Never hardcode paths** to system binaries. Do not use
       `/usr/bin/python3`, `/usr/local/bin/node`, or similar. Use bare
       command names (`python3`, `node`, `ruby`, `java`) and let the
       user's Nix-first PATH resolve them.
    2. **The PATH order is**: `~/.nix-profile/bin` →
       `/run/current-system/sw/bin` → `/nix/var/nix/profiles/default/bin`
       → `/usr/local/bin` → `/usr/bin` → `/bin` → `/usr/sbin` → `/sbin`.
       Nix paths come first deliberately.
    3. To verify which version will run: `which python3` or
       `command -v node`.
    4. In generated Nix code (scripts, launchd services), pin to a
       specific Nix package: `''${pkgs.python3}/bin/python3`.
    5. **Exception**: `#!/usr/bin/env bash` shebangs are acceptable —
       this is the standard portable idiom.

    ## Markdown Table Formatting

    When printing markdown tables in responses:

    1. **Expand columns** — pad every cell so columns are fully aligned and easy to scan. Do not use minimal-width columns.
    2. **Check terminal width** — if any row would exceed ~80 characters, do NOT use a table. Instead, use one of these readable alternatives:
       - **Definition list style** — one item per block with a bold heading and indented details:
         ```
         **#19 — Editor profile tiering**
           Category: Editors
           Effort:   Large
           Status:   Open
         ```
       - **Sectioned list style** — group items under headings:
         ```
         ### Open Issues
         - **#19** Editor profile tiering (Editors, Large)
         - **#26** Secrets management (Core, Medium)
         ```
    3. **Never let content wrap or truncate** — if a table cell contains long text (descriptions, URLs, paths), switch to a non-table format.
  '';

  # == Yasnippet prompt templates ==
  # Deployed to ~/.emacs.d/snippets/<mode>/ via home.file
  # Note: ''${ escapes Nix interpolation to produce literal ${ for yasnippet fields
  snippetDir = ".emacs.d/snippets/agent-shell-mode";
  batchSnippetDir = ".emacs.d/snippets/decknix-batch-compose-mode";
  reviewSnippetDir = ".emacs.d/snippets/decknix-agent-review-mode";

  mkSnippet = name: key: body: ''
    # -*- mode: snippet -*-
    # name: ${name}
    # key: ${key}
    # --
    ${body}
  '';

  snippets = {
    review = mkSnippet "review" "/review" ''
      Review `''${1:`(buffer-file-name (agent-shell--source-buffer))`}` for ''${2:$$$(yas-choose-value '("bugs" "performance" "readability" "security"))}.

      Focus on:
      - ''${3:specific concerns}

      ''${4:Additional context.}'';

    refactor = mkSnippet "refactor" "/refactor" ''
      Refactor ''${1:description} in `''${2:`(buffer-file-name (agent-shell--source-buffer))`}`.

      Follow the ''${3:$$$(yas-choose-value '("extract method" "rename" "move" "inline" "simplify" "DRY up"))} pattern.

      Requirements:
      - ''${4:requirements}'';

    test = mkSnippet "test" "/test" ''
      Write tests for ''${1:function/module} in `''${2:`(buffer-file-name (agent-shell--source-buffer))`}`.

      Cover:
      - ''${3:happy path}
      - ''${4:edge cases}
      - ''${5:error cases}

      Use the ''${6:existing test framework} already in the project.'';

    explain = mkSnippet "explain" "/explain" ''
      Explain how ''${1:code/concept} works in `''${2:`(buffer-file-name (agent-shell--source-buffer))`}`.

      I want to understand:
      - ''${3:specific aspects}'';

    fix = mkSnippet "fix" "/fix" ''
      Fix the ''${1:error/issue} in `''${2:`(buffer-file-name (agent-shell--source-buffer))`}`.

      Stack trace / error:
      ```
      ''${3:paste error here}
      ```

      ''${4:Additional context.}'';

    implement = mkSnippet "implement" "/implement" ''
      Implement ''${1:feature description}.

      Follow the pattern in `''${2:`(buffer-file-name (agent-shell--source-buffer))`}`.

      Requirements:
      - ''${3:requirements}

      ''${4:Additional context.}'';

    debug = mkSnippet "debug" "/debug" ''
      Debug why ''${1:symptom} is happening in `''${2:`(buffer-file-name (agent-shell--source-buffer))`}`.

      Relevant logs:
      ```
      ''${3:paste logs here}
      ```

      What I've tried:
      - ''${4:steps taken}'';

    pr-review-request = mkSnippet "pr-review-request" "/pr-review" ''
      Run \`.git-hooks/pr-request-review ''${1:$$$(yas-choose-value '("" "<PR number>" "<PR URL>"))}\` from the repo directory to post a review request to #backend-code-reviews with reviewer @-mentions.''${0}'';
  };

  # == Yasnippet templates for batch compose mode ==
  # Deployed to ~/.emacs.d/snippets/decknix-batch-compose-mode/ via home.file
  batchSnippets = {
    group = mkSnippet "group" "---" ''
      --- ''${1:group-name}''${2: : ''${3:~/Code/}}
      ''${0}'';

    pr = mkSnippet "PR URL" "pr" ''
      https://github.com/''${1:owner}/''${2:repo}/pull/''${3:number}''${0}'';
  };

  # == Yasnippet templates for the inline review buffer ==
  # Deployed to ~/.emacs.d/snippets/decknix-agent-review-mode/ via home.file.
  # Option-1 annotation patterns. Authoring identity resolves via
  # `decknix--agent-review-author', so `user-login-name' is the default
  # but can be overridden per-session with `decknix-agent-review-author'.
  reviewSnippets = {
    comment = mkSnippet "comment" ",c" ''
      > 💬 **''${1:`(decknix--agent-review-author)`}:** ''${0}'';

    approve = mkSnippet "approve" ",a" ''
      > ✅ **''${1:`(decknix--agent-review-author)`}:** approved''${0:.}'';

    reject = mkSnippet "reject" ",r" ''
      > ❌ **''${1:`(decknix--agent-review-author)`}:** reject — ''${2:reason}''${0}'';

    option = mkSnippet "option-pick" ",o" ''
      > 🔀 **''${1:`(decknix--agent-review-author)`}:** option ''${2:B}''${0: — reason}'';

    mention = mkSnippet "mention" ",m" ''
      > 💬 **''${1:$$(decknix--agent-review-read-collaborator)}:** ''${0}'';

    followup = mkSnippet "follow-up" ",f" ''
      > 🚩 **''${1:`(decknix--agent-review-author)`}:** follow-up — ''${2:title}''${0}'';

    agent = mkSnippet "agent-response" ",A" ''
      > 💬 **agent:** ''${0}'';
  };

in
{
  options.programs.emacs.decknix.agentShell = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable agent-shell.el ecosystem for auggie AI integration.";
    };

    manager.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable agent-shell-manager (tabulated session dashboard).";
    };

    workspace.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable agent-shell-workspace (dedicated tab-bar workspace).";
    };

    attention.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable agent-shell-attention (mode-line attention tracker).";
    };

    templates.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable yasnippet prompt templates for agent-shell (review, refactor, test, etc.).";
    };

    commands.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Nix-managed auggie custom commands (deployed to ~/.augment/commands/).";
    };

    context.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable the context panel for agent-shell sessions.
        Shows tracked issues, PRs, CI status, and review threads in the
        header-line. Provides C-c i sub-prefix for navigation and C-c I
        for a detailed transient panel. Requires gh CLI on PATH.
      '';
    };

    hub.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable hub integration in the workspace sidebar.
        Reads JSON files written by decknix-hub to show Requests
        (PR reviews needing attention) and WIP (my open PRs) sections
        above the Live sessions list.  Requires decknix-hub to be
        running (decknix.services.hub.enable = true).
      '';
    };
  };

  config = mkIf cfg.enable {
    # Deploy yasnippet snippets + auggie commands via home.file
    home.file =
      # Yasnippet snippet files → ~/.emacs.d/snippets/agent-shell-mode/
      (optionalAttrs cfg.templates.enable
        (mapAttrs'
          (name: text: nameValuePair "${snippetDir}/${name}" { inherit text; })
          snippets))
      //
      # Batch compose snippets → ~/.emacs.d/snippets/decknix-batch-compose-mode/
      (optionalAttrs cfg.templates.enable
        (mapAttrs'
          (name: text: nameValuePair "${batchSnippetDir}/${name}" { inherit text; })
          batchSnippets))
      //
      # Review-mode snippets → ~/.emacs.d/snippets/decknix-agent-review-mode/
      (optionalAttrs cfg.templates.enable
        (mapAttrs'
          (name: text: nameValuePair "${reviewSnippetDir}/${name}" { inherit text; })
          reviewSnippets))
      //
      # Auggie custom commands → ~/.augment/commands/
      (optionalAttrs cfg.commands.enable
        (mapAttrs'
          (name: text: nameValuePair "${commandDir}/${name}" { inherit text; })
          commands))
      //
      # User-level augment guidelines → ~/.augment-guidelines
      { "${guidelinesFile}".text = guidelinesContent; };
    programs.emacs = {
      extraPackages = _epkgs:
        # Core (from unstable): agent-shell + acp + shell-maker + markdown-mode
        [ agent-shell acp shell-maker ]
        ++ (with pkgs.emacsPackages; [ markdown-mode ])
        # Add-ons
        ++ (optional cfg.manager.enable agent-shell-manager-el)
        ++ (optional cfg.workspace.enable agent-shell-workspace-el)
        ++ (optional cfg.attention.enable agent-shell-attention-el)
        # In-tree decknix packages (gated by the same flags that gated the
        # original inline elisp).  Progress depends on hub data, so it ships
        # only when hub is enabled.  Sidebar toggles ride with workspace
        # since they exist to flip what the workspace sidebar renders.
        # URL parsing is foundational (linked PRs, quick actions, repo
        # linking, hub) so it ships whenever agent-shell is enabled at all.
        ++ [
          decknix-agent-url-parse-el
          decknix-agent-format-el
          decknix-agent-parse-el
          decknix-agent-session-cache-el
          decknix-agent-session-history-el
          decknix-agent-tags-store-el
          decknix-agent-link-store-el
          decknix-agent-conv-resolve-el
          decknix-agent-session-model-el
          decknix-agent-session-workspace-el
          decknix-agent-conv-recency-el
          decknix-agent-tags-read-el
          decknix-agent-workspace-detect-el
          decknix-agent-command-discover-el
          decknix-agent-session-id-el
          decknix-agent-clipboard-el
          decknix-agent-vcs-el
          decknix-agent-review-format-el
          decknix-agent-review-collaborators-el
        ]
        ++ (optional cfg.hub.enable decknix-progress-el)
        ++ (optional cfg.hub.enable decknix-hub-age-presets-el)
        ++ (optional cfg.hub.enable decknix-hub-teamcity-el)
        ++ (optional cfg.hub.enable decknix-hub-org-filter-el)
        ++ (optional cfg.hub.enable decknix-hub-jira-tasks-el)
        ++ (optional cfg.hub.enable decknix-hub-ci-el)
        ++ (optional cfg.hub.enable decknix-hub-ci-filter-el)
        ++ (optional cfg.hub.enable decknix-hub-attention-filter-el)
        ++ (optional cfg.hub.enable decknix-hub-ready-filter-el)
        ++ (optional cfg.hub.enable decknix-hub-repo-name-el)
        ++ (optional cfg.hub.enable decknix-hub-wip-link-filter-el)
        ++ (optional cfg.hub.enable decknix-hub-mention-bot-el)
        ++ (optional cfg.hub.enable decknix-hub-worktree-parse-el)
        ++ (optional cfg.hub.enable decknix-hub-icons-el)
        ++ (optional cfg.hub.enable decknix-hub-pr-cache-el)
        ++ (optional cfg.hub.enable decknix-hub-repo-cache-el)
        ++ (optional cfg.hub.enable decknix-hub-pr-lookup-el)
        ++ (optional cfg.workspace.enable decknix-sidebar-toggles-el)
        ++ (optional cfg.workspace.enable decknix-sidebar-row-actions-el)
        ++ (optional cfg.workspace.enable decknix-sidebar-format-el)
        ++ (optional cfg.workspace.enable decknix-sidebar-previous-el)
        ++ (optional cfg.workspace.enable decknix-sidebar-tile-el)
        ++ (optional cfg.workspace.enable decknix-sidebar-width-el)
        ++ (optional cfg.workspace.enable decknix-sidebar-nav-cmd-el)
        ++ (optional cfg.workspace.enable decknix-sidebar-footer-keys-el)
        ++ (optional cfg.workspace.enable decknix-webkit-page-el)
        ++ (optional cfg.context.enable decknix-agent-shell-context-el)
        ++ (optional cfg.hub.enable decknix-agent-shell-hub-el)
        ++ [ decknix-agent-shell-main-el ]
        ++ (optional cfg.workspace.enable decknix-agent-shell-workspace-el);

      extraConfig = ''

        ;;; Agent Shell Configuration (auggie AI integration)

        ;; == always-1: agent-shell core (always loaded) ==
        ;; The 241 declarations that build the agent-shell core
        ;; (sessions, conversation identity, compose, picker, custom
        ;; commands, link-PR/repo, review-mode, batch, history, MCP,
        ;; attention helpers, header-line, etc.) live in
        ;; `decknix-agent-shell-main-el' (PR B-Bulk.3a).  This
        ;; require also covers the `always-tail' tail block below
        ;; (header-line + agent-shell-mode-hook setup) — both
        ;; regions ship as one module since they're both always-
        ;; loaded with no feature gate.  Side-effects (define-keys,
        ;; with-eval-after-load wiring, transient setup) stay here.
        (require 'decknix-agent-shell-main)
        ;;; Agent Shell Configuration (auggie AI integration)

        ;; Suppress native-comp warnings from popping up as buffers;
        ;; they are harmless and still logged to *Warnings*
        (setq native-comp-async-report-warnings-errors 'silent)

        ;; == Core: agent-shell with auggie defaults ==
        (require 'agent-shell)
        (require 'agent-shell-auggie)

        ;; == Foundational URL parsers (extracted module) ==
        ;;
        ;; URL-parsing primitives moved out of this heredoc into
        ;; agent-shell/agent/decknix-agent-url-parse.el, packaged as
        ;; `decknix-agent-url-parse-el'.  Loaded early because every
        ;; later subsystem (linked PRs, hub, quick-actions, repo
        ;; linking) calls into them.  Forward declarations keep byte-
        ;; compile clean for the many call sites between here and the
        ;; main hygiene block at line ~6531 below.
        (require 'decknix-agent-url-parse)
        (declare-function decknix--agent-pr-parse-url "decknix-agent-url-parse")
        (declare-function decknix--agent-parse-pr-url "decknix-agent-url-parse")
        (declare-function decknix--agent-repo-parse-url "decknix-agent-url-parse")
        (declare-function decknix--agent-pr-url-accessor "decknix-agent-url-parse")
        (declare-function decknix--hub-repo-cache-key "decknix-agent-url-parse")
        (require 'decknix-agent-format)
        (declare-function decknix--agent-session-time-ago "decknix-agent-format")
        (declare-function decknix--agent-session-time-compact "decknix-agent-format")
        (declare-function decknix--prompt-truncate-for-display "decknix-agent-format")
        (require 'decknix-agent-parse)
        (declare-function decknix--agent-session-parse "decknix-agent-parse")
        (declare-function decknix--prompt-search-parse "decknix-agent-parse")
        (declare-function decknix--agent-conversation-key-raw "decknix-agent-parse")
        ;; Session list cache (PR B.22) — depends on `decknix-agent-parse'
        ;; for the parser, so loaded immediately after it.
        (require 'decknix-agent-session-cache)
        (declare-function decknix--agent-session-list "decknix-agent-session-cache")
        (declare-function decknix--agent-session-refresh-sync "decknix-agent-session-cache")
        (declare-function decknix--agent-session-refresh-async "decknix-agent-session-cache")
        (declare-function decknix--agent-session-jq-cmd "decknix-agent-session-cache")
        (declare-function decknix--agent-session-ensure-jq-filter "decknix-agent-session-cache")
        ;; Local session JSON path + history extractor (PR B.52).
        ;; Pure helpers carved from main-bulk: the path builder feeds
        ;; the resume / grep / restore-input-ring flows, and the
        ;; turn-grouping reader feeds `decknix--agent-session-
        ;; prepopulate' (still in main-bulk because the buffer write
        ;; is a side-effect per AGENTS.md Rule 2).
        (require 'decknix-agent-session-history)
        (declare-function decknix--agent-session-file
                          "decknix-agent-session-history" (session-id))
        (declare-function decknix--agent-session-extract-history
                          "decknix-agent-session-history" (session-id n))
        ;; Tag-store storage layer (PR B.28) — owns
        ;; ~/.config/decknix/agent-sessions.json: the file-path
        ;; defvar, the in-memory cache (hash + mtime + checked-at +
        ;; TTL), v1->v2 auto-migration in `read', and the
        ;; persistence pair.  Loaded after the session-cache module
        ;; because the migration walk inside `read' resolves
        ;; `decknix--agent-session-list' from there at call time.
        (require 'decknix-agent-tags-store)
        (declare-function decknix--agent-tags-read "decknix-agent-tags-store")
        (declare-function decknix--agent-tags-write "decknix-agent-tags-store" (store))
        (declare-function decknix--agent-tags-conversations "decknix-agent-tags-store" (store))

        ;; Per-conversation link records (PR B.31).  Owns the seven
        ;; mutators over the `linked_prs' record set: linked-items /
        ;; linked-prs / linked-repos accessors plus link-pr / unlink-pr
        ;; / link-repo / unlink-repo writers.  Depends on the tags-
        ;; store I/O above and `decknix-agent-url-parse' (loaded
        ;; earlier via the URL-parse require near the top of this
        ;; heredoc).  Hub callbacks fired after a successful link
        ;; (write-linked-prs to refresh the daemon's view, fetch-
        ;; async to short-circuit the cache TTL) are `fboundp'-gated
        ;; inside the module.
        (require 'decknix-agent-link-store)
        (declare-function decknix--agent-linked-items "decknix-agent-link-store" (conv-key))
        (declare-function decknix--agent-linked-prs   "decknix-agent-link-store" (conv-key))
        (declare-function decknix--agent-linked-repos "decknix-agent-link-store" (conv-key))
        (declare-function decknix--agent-link-pr      "decknix-agent-link-store"
                          (conv-key url &optional pr-type added))
        (declare-function decknix--agent-unlink-pr    "decknix-agent-link-store" (conv-key url))
        (declare-function decknix--agent-link-repo    "decknix-agent-link-store"
                          (conv-key url branch &optional added))
        (declare-function decknix--agent-unlink-repo  "decknix-agent-link-store"
                          (conv-key url branch))

        ;; Conversation-key resolution layer (PR B.34).  Bridges the
        ;; raw SHA-256 hash from `decknix-agent-parse' with the
        ;; persisted `mergedInto' redirects in
        ;; `decknix-agent-tags-store', and provides two session-aware
        ;; lookups built on `decknix-agent-session-cache'.  Loaded
        ;; here -- after all three of its dependencies -- so the
        ;; ~30 conversation-key call sites in the rest of this
        ;; heredoc and the bulk modules resolve cleanly.
        (require 'decknix-agent-conv-resolve)
        (declare-function decknix--agent-conversation-key
                          "decknix-agent-conv-resolve" (first-message))
        (declare-function decknix--agent-conv-resolve-key
                          "decknix-agent-conv-resolve" (conv-key))
        (declare-function decknix--agent-conversation-key-for-session
                          "decknix-agent-conv-resolve" (session-id))
        (declare-function decknix--agent-latest-session-id-for-conv-key
                          "decknix-agent-conv-resolve" (conv-key))

        ;; Per-conversation auggie model overrides (PR B.37) --
        ;; persistence layer for the model-id the user picks
        ;; mid-session via C-c C-v.  Owns the read accessor
        ;; (`decknix--agent-session-model-for-conv-key', called by
        ;; the resume path in main-bulk) and the write primitive
        ;; (`decknix--agent-session-save-model-for-conv-key',
        ;; called from the on-success callback of
        ;; `decknix-agent-set-session-model' which itself stays in
        ;; main-bulk per AGENTS.md Rule 2).  Loaded immediately
        ;; after `decknix-agent-conv-resolve' so the agent/
        ;; persistence cluster forms a contiguous block in load
        ;; order.
        (require 'decknix-agent-session-model)
        (declare-function decknix--agent-session-model-for-conv-key
                          "decknix-agent-session-model" (conv-key))
        (declare-function decknix--agent-session-save-model-for-conv-key
                          "decknix-agent-session-model" (conv-key model-id))

        ;; Per-conversation workspace persistence (PR B.40) --
        ;; reader + two writers that share the same agent-
        ;; sessions.json store as tags / linked PRs / per-session
        ;; model overrides.  Loaded immediately after
        ;; `decknix-agent-session-model' to keep the agent/
        ;; persistence cluster contiguous in load order.
        (require 'decknix-agent-session-workspace)
        (declare-function decknix--agent-workspace-for-conv-key
                          "decknix-agent-session-workspace" (conv-key))
        (declare-function decknix--agent-session-save-workspace
                          "decknix-agent-session-workspace" (session-id workspace))
        (declare-function decknix--agent-session-save-workspace-for-conv-key
                          "decknix-agent-session-workspace" (conv-key workspace))

        ;; Per-conversation lastAccessed stamp (PR B.42) -- the
        ;; touch / last-accessed pair that mediates the same
        ;; agent-sessions.json store as the rest of this cluster.
        ;; Used by tag / rename / resume / create flows to bump
        ;; conversation recency, and by the conversation-grouped
        ;; picker's sort comparator.
        (require 'decknix-agent-conv-recency)
        (declare-function decknix--agent-conv-touch
                          "decknix-agent-conv-recency" (conv-key))
        (declare-function decknix--agent-conv-last-accessed
                          "decknix-agent-conv-recency" (conv-key))

        ;; Tags read accessors (PR B.43) -- pure readers that
        ;; resolve session-id or conv-key to the conversation's
        ;; tag list.  Tag *writers* (interactive verbs) stay in
        ;; main-bulk per AGENTS.md Rule 2.
        (require 'decknix-agent-tags-read)
        (declare-function decknix--agent-tags-for-session
                          "decknix-agent-tags-read" (session-id))
        (declare-function decknix--agent-tags-for-conv-key
                          "decknix-agent-tags-read" (conv-key))
        (declare-function decknix--agent-tags-all
                          "decknix-agent-tags-read")

        ;; Workspace + branch detection (PR B.45) -- pure helpers
        ;; consumed by session-creation / PR-quick-action flows.
        ;; Owns the user-tunable `decknix-agent-workspace-roots'
        ;; defvar that seeds the third tier of the PR lookup
        ;; heuristic.
        (require 'decknix-agent-workspace-detect)
        (declare-function decknix--agent-detect-workspace
                          "decknix-agent-workspace-detect")
        (declare-function decknix--agent-pr-detect-workspace
                          "decknix-agent-workspace-detect" (owner repo))
        (declare-function decknix--agent-detect-branch
                          "decknix-agent-workspace-detect" (dir))
        (defvar decknix-agent-workspace-roots)

        ;; Custom auggie command discovery (PR B.46) -- pure
        ;; filesystem scanners + a user-tunable dirs defvar.
        ;; Consumed by the `decknix-agent-command-{run,new,edit}'
        ;; commands and the inline annotation lookup in the
        ;; session-grep code path.
        (require 'decknix-agent-command-discover)
        (declare-function decknix--agent-command-files
                          "decknix-agent-command-discover")
        (declare-function decknix--agent-command-description
                          "decknix-agent-command-discover" (file))
        (defvar decknix--agent-command-dirs)

        ;; Session-id + conv-key accessors (PR B.48) -- the
        ;; current-session-id read plus the two require helpers
        ;; that gate every interactive command operating on the
        ;; current session.
        (require 'decknix-agent-session-id)
        (declare-function decknix--agent-current-session-id
                          "decknix-agent-session-id")
        (declare-function decknix--agent-require-session-id
                          "decknix-agent-session-id")
        (declare-function decknix--agent-require-conv-key
                          "decknix-agent-session-id")

        ;; Clipboard URL DWIM (PR B.49) -- kill-ring + pbpaste
        ;; reader used as the `read-string' default in the
        ;; PR-quick-action and review prompts.
        (require 'decknix-agent-clipboard)
        (declare-function decknix--agent-clipboard-url
                          "decknix-agent-clipboard")

        (require 'decknix-agent-vcs)
        (declare-function decknix--vcs-kind "decknix-agent-vcs")
        (declare-function decknix--git-remote-url "decknix-agent-vcs")
        (declare-function decknix--detect-default-branch "decknix-agent-vcs")
        (require 'decknix-agent-review-format)
        (declare-function decknix--agent-review-quote "decknix-agent-review-format")
        (declare-function decknix--agent-review-format-exchanges "decknix-agent-review-format")
        (declare-function decknix--agent-review-strip-meta "decknix-agent-review-format")

        ;; Review @mention author + collaborators store (PR B.47)
        ;; -- persistence + identity for the inline review buffer.
        ;; Owns the three user-tunable defvars consumed by the
        ;; heredoc yasnippet bodies and `-add-collaborator'.
        (require 'decknix-agent-review-collaborators)
        (declare-function decknix--agent-review-author
                          "decknix-agent-review-collaborators")
        (declare-function decknix--agent-review-load-collaborators
                          "decknix-agent-review-collaborators")
        (declare-function decknix--agent-review-save-collaborators
                          "decknix-agent-review-collaborators")
        (defvar decknix-agent-review-author)
        (defvar decknix-agent-review-collaborators)
        (defvar decknix-agent-review-collaborators-file)

        ;; Use auggie as the default agent (skip agent selection prompt)
        (setq agent-shell-preferred-agent-config 'auggie)

        ;; Session strategy: always start new (no built-in session prompt).
        ;; All session management (new/resume/switch) goes through our
        ;; custom picker at C-c A s instead.
        (setq agent-shell-session-strategy 'new)

        ;; Show model and mode in the mode-line (bottom bar) instead of
        ;; the graphical header, so it's always visible
        (setq agent-shell-header-style 'text)

        ;; Show session ID in header and session selection prompt
        (setq agent-shell-show-session-id t)

        ;; Swap the :welcome-function in the agent config to use our
        ;; enhanced version.  We advise make-agent-config because the
        ;; welcome function is stored as a direct function reference
        ;; in the config alist (not called by symbol), so symbol-level
        ;; advice on agent-shell-auggie--welcome-message has no effect.
        (advice-add 'agent-shell-auggie-make-agent-config
                    :filter-return
                    (lambda (config)
                      (let ((cell (assq :welcome-function config)))
                        (when cell
                          (setcdr cell #'decknix--agent-welcome-message)))
                      config))

        ;; == Help prefix map: C-c ? → sub-keys ==
        (define-prefix-command 'decknix-agent-help-map)

        ;; == Named prefix map: C-c A → "Agent" ==
        ;; Gives which-key / minibuffer a descriptive label instead of "+prefix"
        (define-prefix-command 'decknix-agent-prefix-map)
        (global-set-key (kbd "C-c A") 'decknix-agent-prefix-map)
        ;; Register all C-c A sub-key descriptions with which-key.
        ;; Single consolidated block so which-key can display the full menu.
        (with-eval-after-load 'which-key
          (which-key-add-key-based-replacements
            "C-c A"   "Agent"
            "C-c A ?" "Help"
            "C-c A a" "start/switch"
            "C-c A b" "buffer switch"
            "C-c A n" "new session"
            "C-c A s" "session picker"
            "C-c A g" "grep sessions"
            "C-c A h" "history"
            "C-c A e" "compose"
            "C-c A T" "Tags (global)"
            "C-c A c" "Commands"
            "C-c A c r" "review PR"
            "C-c A c B" "batch process"
            "C-c A c l" "link PR"
            "C-c A c L" "link repo+branch"
            "C-c A c u" "unlink PR / repo"
            "C-c A c c" "run command"
            "C-c A c n" "new command"
            "C-c A c e" "edit command"
            "C-c A t" "Templates"
            "C-c A i" "Context"
            "C-c A S" "MCP servers"
            "C-c A m" "manager"
            "C-c A w" "workspace"
            "C-c A j" "attention jump"
            "C-c A q" "quit session"
            "C-c A R" "rename session"
            "C-c A r" "recent sessions"
            "C-c A P" "Progress (conv-key)"))

        ;; Global keybindings under C-c A prefix
        ;; Only actions that make sense from OUTSIDE an agent-shell buffer.
        ;; Buffer-local bindings (C-c ...) handle in-buffer actions — no duplicates.
        (define-key decknix-agent-prefix-map (kbd "a") 'agent-shell)                      ; Start/switch to agent
        (define-key decknix-agent-prefix-map (kbd "n") 'decknix-agent-session-new)          ; New session (guided)
        (define-key decknix-agent-prefix-map (kbd "q") 'decknix-agent-session-quit)         ; Quit/close session
        (define-key decknix-agent-prefix-map (kbd "?") 'decknix-agent-help-map)           ; Help sub-prefix
        (define-key decknix-agent-help-map (kbd "k") 'decknix-agent-help-keys)            ; Keybindings
        (define-key decknix-agent-help-map (kbd "t") 'decknix-agent-help-tutorial)        ; Tutorial
        (define-key decknix-agent-help-map (kbd "f") 'decknix-agent-help-functions)

        ;; Pre-fetch session list shortly after daemon starts
        (run-at-time 3 nil #'decknix--agent-session-refresh-async)

        ;; Wire C-c A r globally
        (define-key decknix-agent-prefix-map (kbd "r") 'decknix-agent-session-recent)

        (define-key decknix-agent-prefix-map (kbd "s") 'decknix-agent-session-picker)        ; Session picker
        (define-key decknix-agent-prefix-map (kbd "b") 'decknix-agent-switch-buffer)         ; Buffer switch (live only)
        (define-key decknix-agent-prefix-map (kbd "g") 'decknix-agent-session-grep)          ; Grep all session content
        (define-key decknix-agent-prefix-map (kbd "h") 'decknix-agent-session-history)

        ;; Wire C-c A R globally
        (define-key decknix-agent-prefix-map (kbd "R") 'decknix-agent-session-rename)

        ;; Advise sidebar R to handle saved (non-live) sessions:
        ;; For saved sessions, resume first then rename.
        (advice-add 'agent-shell-workspace-sidebar-rename :around
          (lambda (orig-fn)
            "Handle rename for both live and saved sessions in sidebar."
            (let ((saved (get-text-property
                           (line-beginning-position)
                           'decknix-sidebar-saved-session)))
              (if saved
                  ;; Saved session: prompt for new name, update tags directly
                  (let* ((conv-key (get-text-property
                                     (line-beginning-position)
                                     'decknix-sidebar-saved-conv-key))
                         (current-tags (when conv-key
                                         (decknix--agent-tags-for-conv-key conv-key)))
                         (default (string-join (or current-tags '()) "/"))
                         (new-name (read-string
                                    (format "Rename '%s' to: " default)
                                    default)))
                    (when (string-empty-p (string-trim new-name))
                      (user-error "Name cannot be empty"))
                    (let* ((store (decknix--agent-tags-read))
                           (convs (decknix--agent-tags-conversations store))
                           (entry (gethash conv-key convs))
                           (new-tags (seq-remove
                                      #'string-empty-p
                                      (mapcar #'string-trim
                                              (split-string new-name "[/,]" t)))))
                      (when entry
                        (puthash "tags" new-tags entry)
                        (decknix--agent-tags-write store)
                        (agent-shell-workspace-sidebar-refresh)
                        (message "Renamed saved conversation → %s"
                                 (string-join new-tags "/")))))
                ;; Live session: use upstream rename, then persist to tags
                (funcall orig-fn)
                ;; After upstream rename, sync the new name to tags
                (when-let* ((buf (agent-shell-workspace-sidebar--buffer-at-point))
                            ((buffer-live-p buf)))
                  (with-current-buffer buf
                    (when (derived-mode-p 'agent-shell-mode)
                      (ignore-errors
                        (let* ((conv-key (decknix--agent-require-conv-key))
                               (short (agent-shell-workspace--short-name buf))
                               (new-tags (seq-remove
                                           #'string-empty-p
                                           (mapcar #'string-trim
                                                   (split-string short "[/,]" t))))
                               (store (decknix--agent-tags-read))
                               (convs (decknix--agent-tags-conversations store))
                               (entry (or (gethash conv-key convs)
                                          (let ((h (make-hash-table :test 'equal)))
                                            (puthash "tags" nil h)
                                            (puthash "sessions" nil h)
                                            h))))
                          (puthash "tags" new-tags entry)
                          (puthash conv-key entry convs)
                          (decknix--agent-tags-write store))))))))))

        ;; C-c A T — global tags sub-prefix ("Tags (global)")
        ;; Operations that affect tags across all sessions.
        (define-prefix-command 'decknix-agent-tags-global-map)
        (define-key decknix-agent-prefix-map (kbd "T") 'decknix-agent-tags-global-map)
        (define-key decknix-agent-tags-global-map (kbd "l") 'decknix-agent-tag-list)      ; List/filter sessions by tag
        (define-key decknix-agent-tags-global-map (kbd "e") 'decknix-agent-tag-edit)      ; Rename tag globally
        (define-key decknix-agent-tags-global-map (kbd "d") 'decknix-agent-tag-delete)    ; Delete tag globally
        (define-key decknix-agent-tags-global-map (kbd "c") 'decknix-agent-tag-cleanup)

        (advice-add 'agent-shell--session-id-indicator
                    :filter-return
                    (lambda (result)
                      "Truncate the session ID to 8 chars unless full display is toggled on."
                      (if (and result (stringp result)
                               (not decknix--agent-show-full-session-id)
                               (> (length result) 8))
                          (propertize (substring (substring-no-properties result) 0 8)
                                     'font-lock-face 'font-lock-constant-face)
                        result)))

        ;; Pre-fetch prompt search cache on daemon start
        (run-at-time 5 nil #'decknix--prompt-search-refresh-async)

        ;; which-key labels for compose mode keybindings
        (with-eval-after-load 'which-key
          (which-key-add-keymap-based-replacements decknix-agent-compose-mode-map
            "C-c C-c" "submit"
            "C-c C-k" "clear/cancel"
            "C-c C-q" "close"
            "C-c C-s" "toggle sticky"
            "C-c k"   "interrupt…"
            "C-c j"   "jump pending"
            "C-c w"   "workspace"
            "C-c s"   "sessions"
            "C-c i"   "context"
            "C-c T"   "tags")
          (which-key-add-keymap-based-replacements decknix-agent-compose-interrupt-map
            "k"   "interrupt agent"
            "C-c" "interrupt+submit"))

        (define-key decknix-agent-prefix-map (kbd "e") 'decknix-agent-compose)               ; Compose prompt
        (define-key decknix-agent-prefix-map (kbd "E") 'decknix-agent-compose-interrupt)

        (define-key decknix-agent-prefix-map (kbd "v") 'decknix-agent-review)

        ;; C-c A c — commands sub-prefix ("Commands")
        (define-prefix-command 'decknix-agent-command-map)
        (define-key decknix-agent-prefix-map (kbd "c") 'decknix-agent-command-map)
        (define-key decknix-agent-command-map (kbd "c") 'decknix-agent-command-run)    ; Pick & insert
        (define-key decknix-agent-command-map (kbd "n") 'decknix-agent-command-new)    ; New
        (define-key decknix-agent-command-map (kbd "e") 'decknix-agent-command-edit)   ; Edit
        (define-key decknix-agent-command-map (kbd "r") 'decknix-agent-review-pr)      ; PR review
        (define-key decknix-agent-command-map (kbd "B") 'decknix-agent-batch-process)  ; Batch
        (define-key decknix-agent-command-map (kbd "l") 'decknix-agent-link-pr)        ; Link PR
        (define-key decknix-agent-command-map (kbd "L") 'decknix-agent-link-repo)      ; Link Repo
        (define-key decknix-agent-command-map (kbd "u") 'decknix-agent-unlink-pr)

        (define-key decknix-agent-prefix-map (kbd "S") 'decknix-agent-mcp-list)           ; MCP servers
      ''
      + optionalString cfg.manager.enable ''

        ;; == Manager: tabulated session dashboard ==
        (require 'agent-shell-manager)
        (define-key decknix-agent-prefix-map (kbd "m") 'agent-shell-manager-toggle)
        ;; Show manager at the bottom of the frame
        (setq agent-shell-manager-side 'bottom)
      ''
      + optionalString cfg.workspace.enable ''

        ;; == Workspace: dedicated tab-bar tab with sidebar ==
        ;; The 197 declarations that build the workspace tab,
        ;; sidebar render, row-action menus, worktree submenu,
        ;; transient toggles, and the `decknix--sb-stub' macro live
        ;; in `decknix-agent-shell-workspace-el' (PR B-Bulk.3b).
        ;; Side-effects that depend on heredoc-resident runtime
        ;; state (define-key on agent-shell-workspace-sidebar-mode-
        ;; map, with-eval-after-load wiring, hook + advice) stay
        ;; here, immediately after the require.
        (require 'decknix-agent-shell-workspace)

        ;; == Workspace: dedicated tab-bar tab with sidebar ==
        (require 'agent-shell-workspace)
        (define-key decknix-agent-prefix-map (kbd "w") 'agent-shell-workspace-toggle)

        ;; xwidget-webkit JS-bridge primitives (PR B.32) -- the
        ;; `page-text' and `find-in-page' helpers feed both the
        ;; `decknix-webkit-consult-line' command in workspace-bulk
        ;; and any future webkit-side find-in-page entry points.
        ;; Loaded before the keymap setup below so the consult-line
        ;; binding resolves cleanly at file-notify-watch start.
        (require 'decknix-webkit-page)
        (declare-function decknix--webkit-page-text    "decknix-webkit-page")
        (declare-function decknix--webkit-find-in-page "decknix-webkit-page" (needle))

        ;; -- xwidget-webkit: enhanced keybindings --
        ;; Two principles:
        ;;   1. Motion is universal Emacs (C-n / C-p / C-v / M-v / M-< / M->
        ;;      / SPC / DEL) so users don't relearn keys for the WebKit view.
        ;;   2. Mode-local commands live on `C-c C-<letter>` (Emacs major-mode
        ;;      convention), matching agent-shell-mode and review-mode.
        ;; Single-letter EWW-aligned shortcuts (g/l/r/&/w) are kept as a
        ;; secondary tier for users with EWW muscle memory.
        (with-eval-after-load 'xwidget
          ;; --- Search (in-page) -------------------------------------------------
          ;; Two layers:
          ;;   * `C-c C-s' / `s' → consult-line over the page innerText
          ;;     (vertical candidate list, live preview, narrowing).
          ;;   * `C-s' / `C-r'  → JS-bridged isearch shim, kept for users
          ;;     who prefer incremental search.
          (define-key xwidget-webkit-mode-map (kbd "C-s") #'xwidget-webkit-isearch-mode)
          (define-key xwidget-webkit-mode-map (kbd "C-r") #'xwidget-webkit-isearch-mode)
          (define-key xwidget-webkit-mode-map (kbd "s")   #'decknix-webkit-consult-line)

          ;; --- Motion (Emacs-standard) -----------------------------------------
          (define-key xwidget-webkit-mode-map (kbd "C-n") #'xwidget-webkit-scroll-up-line)
          (define-key xwidget-webkit-mode-map (kbd "C-p") #'xwidget-webkit-scroll-down-line)
          (define-key xwidget-webkit-mode-map (kbd "C-v") #'xwidget-webkit-scroll-up)
          (define-key xwidget-webkit-mode-map (kbd "M-v") #'xwidget-webkit-scroll-down)
          (define-key xwidget-webkit-mode-map (kbd "M->") #'xwidget-webkit-scroll-bottom)
          (define-key xwidget-webkit-mode-map (kbd "M-<")
            (lambda () (interactive)
              (xwidget-webkit-scroll-top (xwidget-webkit-current-session))))
          ;; SPC/DEL — view-mode/EWW/Info convention for page forward/back.
          (define-key xwidget-webkit-mode-map (kbd "SPC") #'xwidget-webkit-scroll-up)
          (define-key xwidget-webkit-mode-map (kbd "DEL") #'xwidget-webkit-scroll-down)
          (define-key xwidget-webkit-mode-map (kbd "S-SPC") #'xwidget-webkit-scroll-down)

          ;; --- EWW-aligned single-letter secondary tier ------------------------
          (define-key xwidget-webkit-mode-map (kbd "q") #'quit-window)
          (define-key xwidget-webkit-mode-map (kbd "g") #'xwidget-webkit-reload)
          (define-key xwidget-webkit-mode-map (kbd "l") #'xwidget-webkit-back)
          (define-key xwidget-webkit-mode-map (kbd "r") #'xwidget-webkit-forward)
          (define-key xwidget-webkit-mode-map (kbd "&") #'decknix--webkit-open-external)
          (define-key xwidget-webkit-mode-map (kbd "w") #'decknix--webkit-copy-url)
          (define-key xwidget-webkit-mode-map (kbd "+") #'xwidget-webkit-zoom-in)
          (define-key xwidget-webkit-mode-map (kbd "-") #'xwidget-webkit-zoom-out)
          (define-key xwidget-webkit-mode-map (kbd "TAB") #'decknix--webkit-next-focusable)
          (define-key xwidget-webkit-mode-map (kbd "<backtab>") #'decknix--webkit-prev-focusable)

          ;; --- Major-mode commands (C-c C-<letter>, primary tier) --------------
          (define-key xwidget-webkit-mode-map (kbd "C-c C-r") #'xwidget-webkit-reload)
          (define-key xwidget-webkit-mode-map (kbd "C-c C-b") #'xwidget-webkit-back)
          (define-key xwidget-webkit-mode-map (kbd "C-c C-f") #'xwidget-webkit-forward)
          (define-key xwidget-webkit-mode-map (kbd "C-c C-o") #'decknix--webkit-open-external)
          (define-key xwidget-webkit-mode-map (kbd "C-c C-u") #'xwidget-webkit-browse-url)
          (define-key xwidget-webkit-mode-map (kbd "C-c C-y") #'decknix--webkit-copy-url)
          (define-key xwidget-webkit-mode-map (kbd "C-c C-w") #'decknix--webkit-copy-as-markdown)
          (define-key xwidget-webkit-mode-map (kbd "C-c C-e") #'decknix--webkit-switch-to-eww)
          (define-key xwidget-webkit-mode-map (kbd "C-c C-i") #'decknix--webkit-focus-input)
          (define-key xwidget-webkit-mode-map (kbd "C-c C-s") #'decknix-webkit-consult-line)

          ;; --- which-key labels for the C-c C- prefix --------------------------
          (when (fboundp 'which-key-add-keymap-based-replacements)
            (which-key-add-keymap-based-replacements xwidget-webkit-mode-map
              "C-c C-r" "reload"
              "C-c C-b" "back"
              "C-c C-f" "forward"
              "C-c C-o" "open-external"
              "C-c C-s" "consult-line"
              "C-c C-u" "open-url…"
              "C-c C-y" "copy-url"
              "C-c C-w" "copy-as-markdown"
              "C-c C-e" "switch-to-eww"
              "C-c C-i" "focus-input"))

          ;; --- Display rule: keep WebKit buffers in the main area --------------
          ;; Hub items opened from the sidebar should land in the main window,
          ;; never inside the side window.  display-buffer-alist matches both
          ;; the upstream `*xwidget-webkit*' and our legacy `*WebKit:` names.
          (add-to-list 'display-buffer-alist
            '("\\`\\*\\(xwidget-webkit\\|WebKit\\)"
              (display-buffer-reuse-window
               display-buffer-use-some-window)
              (inhibit-same-window . nil)
              (reusable-frames . visible)
              (some-window . mru)
              (body-function . select-window)))

          ;; --- Header-line with navigation hints -------------------------------
          (add-hook 'xwidget-webkit-mode-hook
            (lambda ()
              (setq header-line-format
                    '(:eval
                      (let ((url (condition-case nil
                                     (xwidget-webkit-uri
                                      (xwidget-webkit-current-session))
                                   (error ""))))
                        (concat
                         (propertize " WebKit " 'face '(:background "#3d5a80" :foreground "white"))
                         " "
                         (propertize
                          (if (> (length url) 60)
                              (concat (substring url 0 57) "…")
                            url)
                          'face 'font-lock-comment-face)
                         "  "
                         (propertize "C-n/C-p" 'face 'font-lock-keyword-face) " line  "
                         (propertize "SPC/DEL" 'face 'font-lock-keyword-face) " page  "
                         (propertize "s" 'face 'font-lock-keyword-face) " find  "
                         (propertize "g" 'face 'font-lock-keyword-face) " reload  "
                         (propertize "l/r" 'face 'font-lock-keyword-face) " back/fwd  "
                         (propertize "&" 'face 'font-lock-keyword-face) " browser  "
                         (propertize "w" 'face 'font-lock-keyword-face) " copy-url  "
                         (propertize "q" 'face 'font-lock-keyword-face) " quit")))))))

        ;; Don't auto-create a session when opening the Agents tab for the
        ;; first time.  The upstream --setup-layout calls (agent-shell) when
        ;; no live sessions exist; override to just show the current buffer
        ;; (welcome screen, *scratch*, etc.) so the user can decide via
        ;; sidebar commands (c, s, p, etc.).
        (advice-add 'agent-shell-workspace--setup-layout :override
          (lambda ()
            "Set up Agents tab without auto-creating a session."
            (delete-other-windows)
            (let ((agent-buffers (seq-filter #'buffer-live-p (agent-shell-buffers))))
              (when agent-buffers
                (switch-to-buffer (car agent-buffers))))
            ;; If no agent buffers, just keep whatever buffer is current
            (agent-shell-workspace-sidebar-open)))

        ;; Focus the sidebar when entering the Agents tab via C-c w.
        ;; The upstream toggle opens/shows the sidebar but leaves focus
        ;; in the main area; we want the sidebar to receive focus so
        ;; the user can immediately navigate with single keys.
        (advice-add 'agent-shell-workspace-toggle :after
          (lambda (&rest _)
            (when (agent-shell-workspace--in-agents-tab-p)
              (let ((sidebar-win (get-buffer-window
                                   agent-shell-workspace-sidebar-buffer-name)))
                (when (and sidebar-win (window-live-p sidebar-win))
                  (select-window sidebar-win))))))

        ;; -- Buffer isolation: teach workspace that compose/batch buffers
        ;; belong in the Agents tab.  Without this, opening compose
        ;; triggers the redirect rule which switches away from the Agents
        ;; tab and collapses the sidebar.
        (advice-add 'agent-shell-workspace--agent-buffer-p :around
          (lambda (orig-fn buffer)
            (or (funcall orig-fn buffer)
                (when (and buffer (buffer-live-p buffer))
                  (with-current-buffer buffer
                    (or (bound-and-true-p decknix-agent-compose-mode)
                        (bound-and-true-p decknix-batch-compose-mode)
                        (string-match-p "\\*Compose:.*\\*\\|\\*Batch" (buffer-name buffer))))))))

        ;; -- Agent kind & config: the upstream functions parse buffer names
        ;; expecting "<Kind> Agent @ <workspace>" but ours are "*Auggie: <name>*".
        ;; Advise to extract agent kind from agent-shell--state instead.
        (advice-add 'agent-shell-workspace--agent-kind :around
          (lambda (orig-fn buffer)
            (let ((result (funcall orig-fn buffer)))
              (if (not (string= result "-"))
                  result
                ;; Fallback: get from agent-shell state
                (or (when (buffer-live-p buffer)
                      (with-current-buffer buffer
                        (when (boundp 'agent-shell--state)
                          (map-nested-elt agent-shell--state
                                          '(:agent-config :buffer-name)))))
                    "-")))))

        (advice-add 'agent-shell-workspace--buffer-config :around
          (lambda (orig-fn buffer)
            (or (funcall orig-fn buffer)
                ;; Fallback: get config from agent-shell state
                (when (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (when (and (derived-mode-p 'agent-shell-mode)
                               (boundp 'agent-shell--state))
                      (map-elt agent-shell--state :agent-config)))))))

        ;; -- Short-name: handle *Auggie: <name>* naming convention.
        ;; The default looks for " @ " which our buffers don't use.
        ;; Extract the part after "*Auggie: " and show tags when available.
        (advice-add 'agent-shell-workspace--short-name :around
          (lambda (orig-fn buffer)
            (let* ((name (buffer-name buffer))
                   ;; Match *Auggie: <name>* or *<Type>: <name>*
                   (short (if (string-match "\\*[^:]+: \\(.+\\)\\*" name)
                              (match-string 1 name)
                            (funcall orig-fn buffer)))
                   ;; Append tags if we have them
                   (tags (when (and (boundp 'decknix--sessions-data)
                                    decknix--sessions-data
                                    (fboundp 'decknix--session-conv-id))
                           (with-current-buffer buffer
                             (when-let ((cid (ignore-errors (decknix--session-conv-id)))
                                        (entry (assoc cid decknix--sessions-data)))
                               (cdr (assoc 'tags (cdr entry))))))))
              (if (and tags (> (length tags) 0))
                  (format "%s %s" short
                          (mapconcat (lambda (tag) (concat "#" tag)) tags " "))
                short))))

        ;; Sidebar width cycling state + commands (PR B.35) -- owns
        ;; the cycle state defvar (`decknix--sidebar-width-state'),
        ;; the restore-on-open helper (`decknix--sidebar-apply-width',
        ;; wired below as advice on the sidebar opener), and the
        ;; interactive cycler (`decknix-sidebar-cycle-width', bound
        ;; in workspace-bulk's toggles transient).  Loaded here so
        ;; the immediately-following advice-add resolves cleanly.
        (require 'decknix-sidebar-width)
        (defvar decknix--sidebar-width-state)
        (declare-function decknix--sidebar-apply-width "decknix-sidebar-width")
        (declare-function decknix-sidebar-cycle-width "decknix-sidebar-width")

        ;; Sidebar nav transient item-command factory (PR B.38) --
        ;; one-defun module providing `decknix--nav-make-item-cmd'
        ;; for the Requests / WIP / Live / Previous section
        ;; transients in workspace-bulk.  No state, no side-effects;
        ;; the four call-sites in workspace-bulk reach the symbol
        ;; through this require.
        (require 'decknix-sidebar-nav-cmd)
        (declare-function decknix--nav-make-item-cmd
                          "decknix-sidebar-nav-cmd" (item-data action-fn))

        ;; Sidebar footer Navigate / Quick key alists (PR B.41) --
        ;; pure builders consumed by the footer renderer in
        ;; workspace-bulk.  The third footer section (Toggles) is
        ;; still in workspace-bulk because it pulls in many hub-
        ;; bulk free vars and faces.
        (require 'decknix-sidebar-footer-keys)
        (declare-function decknix--sidebar-footer-nav-keys
                          "decknix-sidebar-footer-keys")
        (declare-function decknix--sidebar-footer-quick-keys
                          "decknix-sidebar-footer-keys")

        ;; Apply saved width after the sidebar opens
        (advice-add 'agent-shell-workspace-sidebar-open :after
          (lambda (&rest _) (decknix--sidebar-apply-width)))
        (declare-function decknix--hub-age-filter-label "decknix-hub-age-presets")
        (declare-function decknix--hub-cycle-age-filter "decknix-hub-age-presets")
        (declare-function decknix--hub-age-visible-p "decknix-hub-age-presets")
        (declare-function decknix--hub-tc-build-for-branch "decknix-hub-teamcity")
        (declare-function decknix--hub-tc-icon "decknix-hub-teamcity")
        (declare-function decknix--hub-deploy-indicator "decknix-hub-teamcity")
        (declare-function decknix--hub-discover-orgs "decknix-hub-org-filter")
        (declare-function decknix--hub-org-visible-p "decknix-hub-org-filter")
        (declare-function decknix--hub-org-filter-summary "decknix-hub-org-filter")
        (declare-function decknix--hub-task-status-icon "decknix-hub-jira-tasks")
        (declare-function decknix--hub-icon "decknix-hub-ci")
        (declare-function decknix--hub-ci-icon "decknix-hub-ci")
        (declare-function decknix--hub-ci-classify "decknix-hub-ci")
        (declare-function decknix--hub-mention-filter-normalize "decknix-hub-mention-bot")
        (declare-function decknix--hub-mention-filter-label "decknix-hub-mention-bot")
        (declare-function decknix--hub-item-author-p "decknix-hub-mention-bot")
        (declare-function decknix--hub-item-mentioned-p "decknix-hub-mention-bot")
        (declare-function decknix--hub-item-team-requested-p "decknix-hub-mention-bot")
        (declare-function decknix--hub-mention-visible-p "decknix-hub-mention-bot")
        (declare-function decknix--hub-bot-author-p "decknix-hub-mention-bot")
        (declare-function decknix--hub-bot-visible-p "decknix-hub-mention-bot")
        (declare-function decknix--hub-worktree-canonical-repo "decknix-hub-worktree-parse")
        (declare-function decknix--hub-worktree-repo-from-url "decknix-hub-worktree-parse")
        (declare-function decknix--hub-worktree-normalize-path "decknix-hub-worktree-parse")
        (declare-function decknix--hub-worktree-parse-porcelain "decknix-hub-worktree-parse")
        (declare-function decknix--hub-format-age "decknix-hub-icons")
        (declare-function decknix--hub-review-icon "decknix-hub-icons")
        (declare-function decknix--hub-wip-review-icon "decknix-hub-icons")
        (declare-function decknix--hub-activity-icons "decknix-hub-icons")
        (declare-function decknix--hub-wip-reply-icon "decknix-hub-icons")
        (declare-function decknix--hub-pr-status-from-hub "decknix-hub-pr-lookup")
        (declare-function decknix--hub-pr-cache-get "decknix-hub-pr-lookup")

        ;; -- Sidebar transient menu (magit-style ? popup) --
        (require 'transient)

        ;; == Sidebar visibility/filter toggles ==
        ;;
        ;; Source moved out of this heredoc into
        ;; agent-shell/sidebar/decknix-sidebar-toggles.el, packaged as
        ;; `decknix-sidebar-toggles-el' (see the `let' block at the top
        ;; of this module).  The `(require ...)' stays HERE so that
        ;; downstream call sites further down the workspace block
        ;; (sidebar render, transient menus, key bindings) see the
        ;; defvars and toggle commands as soon as they're needed.
        (require 'decknix-sidebar-toggles)

        ;; == Sidebar row-level actions (`-at-point' commands) ==
        ;;
        ;; Source moved out of this heredoc into
        ;; agent-shell/sidebar/decknix-sidebar-row-actions.el, packaged
        ;; as `decknix-sidebar-row-actions-el' (see the `let' block at
        ;; the top of this module).  The `(require ...)' stays HERE
        ;; alongside the toggles require so downstream key bindings
        ;; (`a h' / `a u' in the row-action transient) see the commands
        ;; as soon as they're needed.
        (require 'decknix-sidebar-row-actions)

        ;; Pure display helpers extracted from the heredoc:
        ;;   decknix--sidebar-abbreviate-workspace
        ;;   decknix--sidebar-session-age-visible-p
        ;; The age-visible predicate references the heredoc-resident
        ;; `decknix--sidebar-sessions-age-filter' via dynamic resolution.
        ;; PR B.26 also folded the four sidebar render primitives
        ;; (section header + three key-group renderers) into this
        ;; package — they are pure `insert' formatters used by both
        ;; the heredoc and `hub-bulk' to compose the sidebar buffer.
        (require 'decknix-sidebar-format)
        (declare-function decknix--sidebar-abbreviate-workspace "decknix-sidebar-format")
        (declare-function decknix--sidebar-session-age-visible-p "decknix-sidebar-format")
        (declare-function decknix--sidebar-render-section-header "decknix-sidebar-format")
        (declare-function decknix--sidebar-render-key-group "decknix-sidebar-format")
        (declare-function decknix--sidebar-render-key-group-inline "decknix-sidebar-format")
        (declare-function decknix--sidebar-render-key-groups-side-by-side "decknix-sidebar-format")

        ;; Previous-Sessions list + dedupe (PR B.23) — carries the
        ;; in-memory list mutated by sidebar-state restore and the
        ;; pure dedupe used everywhere a Previous-Sessions list is
        ;; rendered or restored.
        (require 'decknix-sidebar-previous)
        (declare-function decknix--sidebar-previous-dedupe "decknix-sidebar-previous")

        ;; Sidebar tile-cycle helpers (PR B.29) -- moved out of
        ;; the workspace heredoc.  Owns the desired-count defvar,
        ;; the current-count reader, the one-shot apply, the
        ;; interactive cycle command, and the sidebar-refresh
        ;; auto-engage hook.  Persistence (read/write tile-count
        ;; into `decknix--sidebar-state-file') stays in workspace-
        ;; bulk's broader sidebar-state save/restore cluster.
        (require 'decknix-sidebar-tile)
        (declare-function decknix--sidebar-tile-current-count "decknix-sidebar-tile")
        (declare-function decknix--sidebar-tile-apply "decknix-sidebar-tile" (n))
        (declare-function decknix-sidebar-tile-cycle "decknix-sidebar-tile")
        (declare-function decknix--sidebar-maybe-apply-tile-pref "decknix-sidebar-tile")

        (advice-add 'agent-shell-workspace-sidebar--render :override
          (lambda ()
            "Render sidebar with hub data, live sessions, saved sessions, and key footer."
            (let* ((buffers (sort (copy-sequence
                                   (seq-filter #'buffer-live-p (agent-shell-buffers)))
                                  (lambda (a b)
                                    (string< (agent-shell-workspace--short-name a)
                                             (agent-shell-workspace--short-name b)))))
                   (selected agent-shell-workspace-sidebar--selected-buffer)
                   (tiled agent-shell-workspace--tiled-buffers)
                   (inhibit-read-only t)
                   (target-line nil)
                   (max-name-width (when buffers
                                     (apply #'max
                                            (mapcar (lambda (buf)
                                                      (length
                                                       (agent-shell-workspace--short-name buf)))
                                                    buffers))))
                   ;; Skip the (potentially expensive) saved-sessions
                   ;; aggregation entirely when the user has hidden the
                   ;; section via the `h' toggle.
                   (saved (when decknix--hub-show-saved-sessions
                            (decknix--sidebar-saved-sessions)))
                   (line-num 0))
              (erase-buffer)

              ;; ── Hub: Requests (PR reviews) ──
              (when (fboundp 'decknix--hub-render-requests)
                (setq line-num (decknix--hub-render-requests line-num)))

              ;; ── Hub: WIP (my open PRs) ──
              (when (fboundp 'decknix--hub-render-wip)
                (setq line-num (decknix--hub-render-wip line-num)))

              ;; ── Hub: status hint when no data ──
              (when (fboundp 'decknix--hub-render-status-hint)
                (setq line-num (decknix--hub-render-status-hint line-num)))

              ;; ── Hub: Tasks (Jira) ──
              (when (fboundp 'decknix--hub-render-tasks)
                (setq line-num (decknix--hub-render-tasks line-num)))

              ;; Pre-warm: kick off async fetches for all linked PRs
              ;; before rendering so they run concurrently rather than
              ;; being triggered sequentially as render encounters each PR.
              (when (and (boundp 'decknix--hub-expand-prs)
                         decknix--hub-expand-prs
                         (fboundp 'decknix--hub-pr-fetch-async))
                (dolist (buf buffers)
                  (when (buffer-live-p buf)
                    (let ((ck (with-current-buffer buf
                                (decknix--agent-current-conv-key))))
                      (when ck
                        (dolist (pr (decknix--agent-linked-prs ck))
                          (let ((url (decknix--agent-pr-url-accessor pr "url")))
                            (when url
                              ;; Only fetch if not already in hub data or cache
                              (unless (or (decknix--hub-pr-status-from-hub url)
                                          (decknix--hub-pr-cache-get url))
                                (decknix--hub-pr-fetch-async url))))))))))

              ;; Write linked-prs.json so the hub daemon can poll
              ;; deploy status for linked PR branches (not just WIP).
              (when (fboundp 'decknix--hub-write-linked-prs)
                (decknix--hub-write-linked-prs))

              ;; ── Live Sessions ──
              (decknix--sidebar-render-section-header
               (format "Live (%d)" (length buffers))
               'live)
              (setq line-num (1+ line-num)) ;; section header line
              (if (null buffers)
                  (progn
                    (insert (propertize "  (none)" 'face 'font-lock-comment-face) "\n")
                    (setq line-num (1+ line-num)))
                (dolist (buf buffers)
                  (let* ((agent-icon (agent-shell-workspace--agent-icon buf))
                         (status (agent-shell-workspace--track-status
                                  buf (agent-shell-workspace--buffer-status buf)))
                         (status-face (agent-shell-workspace--status-face status))
                         (short-name (agent-shell-workspace--short-name buf))
                         (tile-indicator (if (memq buf tiled) " ▫" ""))
                         (display-face (if (string= status "finished") "cyan" status-face))
                         (logo-box (agent-shell-workspace--make-logo-box
                                    agent-icon display-face))
                         (name-box (agent-shell-workspace--make-name-box
                                    short-name display-face max-name-width))
                         (name-box-styled
                          (if (string= status "waiting")
                              (propertize name-box 'face '(:background "#3a1515"))
                            name-box))
                         (selection-indicator (if (eq buf selected) ">" " "))
                         ;; PR badge (collapsed) — get conv-key for this buffer
                         (buf-conv-key
                          (with-current-buffer buf
                            (decknix--agent-current-conv-key)))
                         (pr-badge (if buf-conv-key
                                       (decknix--hub-pr-badge buf-conv-key)
                                     ""))
                         (attention-icons
                          (if buf-conv-key
                              (decknix--hub-session-attention-icons buf-conv-key)
                            ""))
                         (progress-badge
                          (if (and decknix--sidebar-show-progress
                                   buf-conv-key
                                   (fboundp 'decknix-progress--sidebar-badge))
                              (decknix-progress--sidebar-badge buf-conv-key)
                            ""))
                         (line (concat selection-indicator " "
                                      logo-box name-box-styled tile-indicator
                                      pr-badge attention-icons progress-badge)))
                    (setq line-num (1+ line-num))
                    (when (eq buf selected)
                      (setq target-line line-num))
                    (setq line (propertize line
                                          'agent-shell-workspace-buffer buf))
                    (insert line "\n")
                    ;; Expanded PR lines when toggle is on — grouped by repo
                    (when (and decknix--hub-expand-prs buf-conv-key)
                      (setq line-num
                            (+ line-num
                               (decknix--hub-render-session-prs
                                buf-conv-key decknix--hub-expand-prs)))))))

              ;; ── Previous sessions (greyed-out, from last exit) ──
              (when (fboundp 'decknix--sidebar-render-previous-sessions)
                (setq line-num
                      (decknix--sidebar-render-previous-sessions line-num)))

              ;; ── Saved Sessions (grouped by workspace, merged by display name) ──
              (when saved
                (insert "\n")
                (setq line-num (1+ line-num)) ;; blank line
                (let* ((age-label (decknix--sidebar-sessions-age-label))
                       (age-active (and decknix--sidebar-sessions-age-filter
                                        (not (string= age-label "all"))))
                       (title (concat
                               (format "Sessions (%d)" (length saved))
                               (when age-active
                                 (propertize (format "  [age: %s]" age-label)
                                             'face 'font-lock-constant-face)))))
                  (decknix--sidebar-render-section-header title 'sessions))
                (setq line-num (1+ line-num)) ;; section header
                ;; Group by ABBREVIATED workspace name so differently-stored
                ;; paths (~/Code/foo vs /Users/x/Code/foo) merge under one heading
                (let ((by-ws (make-hash-table :test 'equal))
                      (ws-order nil))
                  (dolist (entry saved)
                    (let* ((raw-ws (nth 1 entry))
                           (ws-label (if raw-ws
                                         (decknix--sidebar-abbreviate-workspace raw-ws)
                                       "unknown"))
                           (existing (gethash ws-label by-ws)))
                      (unless existing
                        (push ws-label ws-order))
                      (puthash ws-label (append existing (list entry)) by-ws)))
                  ;; Render each workspace group (order preserved from data, newest first)
                  (dolist (ws-label (nreverse ws-order))
                    ;; Workspace sub-header — propertized with the workspace
                    ;; name so the unified dispatcher (specs/sidebar-ret.md
                    ;; §3.2.4) can offer the workspace transient on RET.
                    (insert (propertize (format "  %s" ws-label)
                                       'face 'font-lock-type-face
                                       'decknix-sidebar-workspace ws-label)
                            "\n")
                    (setq line-num (1+ line-num))
                    ;; Sessions under this workspace
                    (dolist (entry (gethash ws-label by-ws))
                      (let* ((name (nth 0 entry))
                             (conv-key (nth 2 entry))
                             (session (nth 3 entry))
                             (modified (nth 4 entry))
                             (live-p (nth 5 entry))
                             (hidden-p (and conv-key
                                            (decknix--agent-conversation-hidden-p
                                             conv-key)))
                             (tags (when conv-key
                                     (decknix--agent-tags-for-conv-key conv-key)))
                             (time-str (if modified
                                           (decknix--agent-session-time-compact modified)
                                         ""))
                             ;; Build display string based on mode
                             (label (pcase decknix--sidebar-display-mode
                                      ('tags
                                       (if tags
                                           (string-join tags "/")
                                         (or name "?")))
                                      ('both
                                       (if tags
                                           (format "%s %s"
                                                   (string-join tags "/")
                                                   (propertize
                                                    (format "(%s)" (or name ""))
                                                    'face 'font-lock-comment-face))
                                         (or name "?")))
                                      (_ (or name "?"))))  ;; 'name mode
                             ;; Dim hidden sessions with 👻 prefix
                             (label (if hidden-p
                                        (propertize (format "👻 %s" label)
                                                    'face 'shadow)
                                      label))
                             (progress-badge
                              (if (and decknix--sidebar-show-progress
                                       conv-key
                                       (fboundp 'decknix-progress--sidebar-badge))
                                  (decknix-progress--sidebar-badge conv-key)
                                ""))
                             (display (format "  %4s %s%s"
                                              (propertize time-str
                                                          'face 'font-lock-comment-face)
                                              label
                                              progress-badge))
                             (with-props
                              (propertize display
                                          'decknix-sidebar-saved-session session
                                          'decknix-sidebar-saved-conv-key conv-key
                                          'decknix-sidebar-saved-workspace (nth 1 entry)
                                          'decknix-sidebar-saved-live live-p)))
                        ;; Dim the whole row when the conversation is already
                        ;; live elsewhere — the Live section above owns the
                        ;; actionable signal; this row is just recent-context.
                        (insert (if live-p
                                    (propertize with-props 'face 'shadow)
                                  with-props)
                                "\n")
                        (setq line-num (1+ line-num)))))))

              ;; ── Key help footer ──
              (decknix--sidebar-render-footer)

              ;; Restore cursor
              (goto-char (point-min))
              (when target-line
                (forward-line (1- target-line))))))

        ;; -- Sidebar goto: handle hub items, live, and saved sessions --
        (advice-add 'agent-shell-workspace-sidebar-goto :around
          (lambda (orig-fn)
            "Open hub URL, live buffer, or resume saved session at point."
            (let ((hub-url (get-text-property
                            (line-beginning-position)
                            'decknix-hub-url))
                  (hub-type (get-text-property
                              (line-beginning-position)
                              'decknix-hub-type))
                  (hub-repo (get-text-property
                              (line-beginning-position)
                              'decknix-hub-repo))
                  (hub-number (get-text-property
                                (line-beginning-position)
                                'decknix-hub-number))
                  (prev (get-text-property
                          (line-beginning-position)
                          'decknix-previous-session))
                  (saved (get-text-property
                          (line-beginning-position)
                          'decknix-sidebar-saved-session)))
              (cond
               ;; Any hub item: open URL in xwidget-webkit or browser
               ;; (primary action).  The action menu now lives behind RET
               ;; via `decknix-sidebar-ret' (#123); this advice path runs
               ;; for M-RET / mouse-click / picker primary-action callers
               ;; and is intentionally menu-free so the primary action is
               ;; always a single open.  hub-type/-repo/-number are kept
               ;; in the binding above so future advice consumers retain
               ;; the row context without re-fetching properties.
               (hub-url
                (ignore hub-type hub-repo hub-number)
                (decknix--open-url hub-url))
               ;; Previous session: restore it and focus
               (prev
                (decknix--sidebar-restore-previous-session prev t))
               ;; Saved session
               (saved
                  ;; Resume saved session
                  (let* ((conv-key (get-text-property
                                    (line-beginning-position)
                                    'decknix-sidebar-saved-conv-key))
                         (workspace (get-text-property
                                     (line-beginning-position)
                                     'decknix-sidebar-saved-workspace))
                         (session-id (alist-get 'sessionId saved))
                         (name (decknix--agent-session-display-name saved)))
                    (when session-id
                      ;; If no workspace, prompt
                      (unless workspace
                        (setq workspace
                              (read-directory-name "Workspace: " nil nil t)))
                      ;; Select main window so resume captures it as target
                      (let ((main (window-main-window (selected-frame))))
                        (when (and main (window-live-p main))
                          (select-window main)))
                      (let ((conv-key (decknix--agent-conversation-key
                                       (alist-get 'firstUserMessage
                                                  saved ""))))
                        (decknix--agent-session-resume
                         session-id
                         decknix-agent-session-history-count
                         name workspace conv-key)))))
               ;; Default: live buffer
               (t (funcall orig-fn))))))

        (add-hook 'agent-shell-workspace-sidebar-mode-hook
          (lambda ()
            (setq header-line-format
                  '(:eval
                    (let* ((live (length (seq-filter #'buffer-live-p
                                                     (agent-shell-buffers))))
                           (saved-count (decknix--sidebar-saved-count)))
                      (let* ((reviews (when (boundp 'decknix--hub-reviews)
                                        (length (alist-get 'items
                                                           decknix--hub-reviews))))
                             (hub-str (if (and reviews (> reviews 0))
                                         (format "  ⚡%d review%s"
                                                 reviews
                                                 (if (= reviews 1) "" "s"))
                                       "")))
                        (propertize
                         (format " ● %d live  ◦ %d saved%s"
                                 live saved-count hub-str)
                         'face 'font-lock-keyword-face)))))))

        ;; -- Robust sidebar buffer-at-point lookup ---------------------------
        ;; Upstream `--buffer-at-point' reads the text property at
        ;; `line-beginning-position' in `(current-buffer)'.  That assumes the
        ;; sidebar window is selected when the function runs.  Our action
        ;; transients (a, T, RET menus) are launched via
        ;; `decknix--sidebar-call-transient', which deliberately switches to
        ;; the main window first so transient menus and any windows their
        ;; suffixes spawn render in the main area instead of trying to split
        ;; the dedicated sidebar window.  After that switch, every suffix
        ;; that calls `--buffer-at-point' would look up the property in the
        ;; main window's buffer (scratch / agent buffer) and find none —
        ;; surfacing as "No live agent buffer at point" on `a a', `a k',
        ;; `a r', etc.  Override to always read from the sidebar buffer
        ;; itself; buffer-local point is preserved per-buffer regardless of
        ;; which window is currently selected, so the lookup still hits the
        ;; row the user navigated to before invoking the transient.
        (advice-add 'agent-shell-workspace-sidebar--buffer-at-point :override
          (lambda ()
            "Return the agent buffer for the sidebar row at point.
        Robust to being called from outside the sidebar window."
            (let ((sidebar-buf
                   (get-buffer agent-shell-workspace-sidebar-buffer-name)))
              (when (buffer-live-p sidebar-buf)
                (with-current-buffer sidebar-buf
                  (get-text-property (line-beginning-position)
                                     'agent-shell-workspace-buffer))))))

        ;; -- Fix sidebar kill: upstream uses comint-send-eof which calls
        ;; comint-send-input, searching for the prompt regexp.  If the prompt
        ;; isn't at point (process dead, mid-output, duplicate buffer), the
        ;; search fails with "Search failed: Auggie> ".
        ;; Use process-send-eof directly (bypasses comint's prompt search)
        ;; and fall back to kill-process if that also fails.
        (advice-add 'agent-shell-workspace-sidebar-kill :override
          (lambda ()
            "Kill the agent-shell process at point (robust, no prompt search)."
            (interactive)
            (let ((buffer (agent-shell-workspace-sidebar--buffer-at-point)))
              (unless (and buffer (buffer-live-p buffer))
                (user-error "No live agent buffer at point"))
              (when (yes-or-no-p
                     (format "Kill agent-shell process in %s? "
                             (buffer-name buffer)))
                (let ((proc (get-buffer-process buffer)))
                  (when (and proc (process-live-p proc))
                    (condition-case nil
                        (process-send-eof proc)
                      (error
                       ;; process-send-eof can fail if pipe is broken
                       (ignore-errors (kill-process proc)))))
                  (message "Killed agent-shell process in %s"
                           (buffer-name buffer)))
                (run-with-timer 0.1 nil
                                #'agent-shell-workspace-sidebar-refresh)))))

        ;; -- Buffer isolation fix: allow transient buffers in the Agents tab --
        ;; The upstream agent-shell-workspace has buffer isolation that
        ;; redirects non-agent buffers out of the Agents tab (switches to
        ;; the previous tab).  Transient's ` *transient*' buffer fails the
        ;; agent-buffer-p check, causing the tab to switch away — which
        ;; looks like the sidebar "collapsing".  Fix: extend the predicate
        ;; to recognize transient and completion buffers as legitimate.
        (advice-add 'agent-shell-workspace--agent-buffer-p :around
          (lambda (orig-fn buffer)
            "Also recognize transient/completion buffers as agent-tab-safe."
            (or (funcall orig-fn buffer)
                (when (and buffer (buffer-live-p buffer))
                  (let ((name (buffer-name buffer)))
                    (or (string-match-p "\\` \\*transient\\*" name)
                        (string-match-p "\\` \\*Transient" name)
                        (string-match-p "\\*Completions\\*" name)))))))



        ;; -- Bind keys in sidebar mode --
        ;; Override upstream keys: r, w, a now serve section navigation
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "r") #'decknix-sidebar-goto-requests)
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "w") #'decknix-sidebar-goto-wip)
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "l") #'decknix-sidebar-goto-live)
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "p") #'decknix-sidebar-goto-previous)
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "a") (lambda () (interactive)
                      (decknix--sidebar-call-transient #'decknix-sidebar-actions)))

        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "?") (lambda () (interactive)
                      (decknix--sidebar-call-transient #'decknix-sidebar-transient)))
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "h") (lambda () (interactive)
                      (decknix--sidebar-call-transient #'decknix-sidebar-transient)))
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "K") #'decknix-sidebar-toggle-keys)

        ;; T = toggles transient (sectioned: Global, Requests, Live, WIP)
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "T") (lambda () (interactive)
                      (decknix--sidebar-call-transient
                       #'decknix-sidebar-toggles-transient)))
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "s") (lambda () (interactive)
                      (decknix--sidebar-call-transient #'decknix-sidebar-sessions)))

        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "v") #'decknix-sidebar-review-at-point)

        ;; RET = action menu transient for the row at point (#123).
        ;; M-RET (and C-u RET) = primary action — opens the row's URL in
        ;; xwidget/EWW for hub rows, or defers to the existing handler for
        ;; sessions and headers.  Both <return> and RET are bound because
        ;; tty-style RET and GUI-style <return> are distinct events.
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "RET") #'decknix-sidebar-ret)
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "<return>") #'decknix-sidebar-ret)
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "M-RET") #'decknix-sidebar-primary-action)
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "M-<return>") #'decknix-sidebar-primary-action)

        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "R") #'decknix-sidebar-open-review-menu)
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "W") #'decknix-sidebar-open-worktree-menu)
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "S") #'decknix-sidebar-open-session-menu)

        ;; Save on exit, restore after all modules are loaded.
        ;; The restore must run AFTER all defvars — hub variables like
        ;; decknix--hub-age-filter and upstream agent-shell-workspace vars
        ;; are defined later in the config.  Using emacs-startup-hook
        ;; ensures everything is bound before we try to set values.
        (add-hook 'kill-emacs-hook #'decknix--sidebar-state-save)
        (add-hook 'emacs-startup-hook #'decknix--sidebar-state-restore)

        ;; Periodic idle-timer save so toggle state and previous-sessions
        ;; survive force-quit / daemon crashes.  `kill-emacs-hook' alone
        ;; loses everything when the daemon locks up and is force-killed,
        ;; which means user-set toggles like `decknix--hub-expand-prs'
        ;; silently revert on next start.  The 30 s idle threshold keeps
        ;; this out of the hot path during active use; repeat=t fires once
        ;; per idle period, not every 30 s of idleness.
        (run-with-idle-timer 30 t #'decknix--sidebar-state-save)

        ;; Bind 'P' to restore all previous sessions
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "P") #'decknix--sidebar-restore-all-previous)
      ''
      + optionalString cfg.hub.enable ''

        ;; == Hub: surface decknix-hub data in the sidebar ==
        ;; Reads per-adapter JSON files from ~/.config/decknix/hub/ and
        ;; renders Requests (PR reviews) and WIP (my PRs) sections above
        ;; Live sessions.  A file-notify watcher triggers sidebar refresh
        ;; automatically when any hub file changes — zero polling from Emacs.
        ;;
        ;; The 167 declarations that build this surface (data layer, JSON
        ;; readers, refresh + watcher, transients, render functions for
        ;; Requests / WIP / Linked PRs / Linked Repos / Tasks / Sessions,
        ;; row-action menu transients, etc.) live in the in-tree package
        ;; `decknix-agent-shell-hub-el' (PR B-Bulk.2).  Side-effects that
        ;; depend on heredoc-resident runtime state (cache restores, the
        ;; file-notify watcher start, advice on
        ;; `agent-shell-workspace-sidebar-refresh', and the seven
        ;; `(require 'decknix-hub-...)' calls for already-extracted helper
        ;; modules whose load-order matters) stay HERE, immediately after
        ;; the bulk require so symbols resolve at byte-compile time and
        ;; the original load-order semantics are preserved.
        (require 'decknix-agent-shell-hub)



        ;; Load initial data and start watching
        (decknix--hub-refresh-all)
        (decknix--hub-start-watcher)

        (with-eval-after-load 'agent-shell-workspace
          (advice-add 'agent-shell-workspace-sidebar-refresh :around
            (lambda (orig-fn &rest args)
              "Skip refresh when a picker has suspended sidebar updates."
              (unless decknix--sidebar-refresh-suspended
                (apply orig-fn args))))
          ;; Auto-apply the tile-count preference whenever the sidebar
          ;; refreshes.  Idempotent — only re-tiles when the current
          ;; layout doesn't match the desired count, so resuming a
          ;; Previous session naturally engages the saved preference
          ;; without churning windows on every 2 s timer tick.
          (advice-add 'agent-shell-workspace-sidebar-refresh :after
            (lambda (&rest _)
              "Engage `decknix--sidebar-tile-count' once enough buffers exist."
              (unless decknix--sidebar-refresh-suspended
                (ignore-errors (decknix--sidebar-maybe-apply-tile-pref))))))

        ;; Add Hub group to the sidebar transient
        ;; -- Hub: org filter (multi-select transient) --
        ;; Tracks which GitHub orgs are visible using a hash-table.
        ;; nil = show all (default). When the table has entries,
        ;; only orgs with t value are shown. O opens a transient
        ;; with per-org toggles, show all / show none.
        ;;
        ;; The pure helpers (defvar `decknix--hub-org-visibility',
        ;; `decknix--hub-discover-orgs', `decknix--hub-org-visible-p',
        ;; and `decknix--hub-org-filter-summary' further down) moved
        ;; out of this heredoc into agent-shell/hub/decknix-hub-org-filter.el,
        ;; packaged as `decknix-hub-org-filter-el' (see the `let'
        ;; block at the top of this module).  The mutating commands
        ;; (`-toggle-org', `-show-all', `-show-none', the `-make-org-toggle-cmd'
        ;; factory, the transient prefix / suffix wrappers) stay
        ;; here — they refresh the sidebar and bind transient slots,
        ;; which are heredoc-side concerns.
        (require 'decknix-hub-org-filter)

        ;; -- Hub: age filter --
        ;; Cycles through preset age thresholds.  Items older than the
        ;; threshold are hidden from both Requests and WIP sections.
        ;; nil = show all (no age filter).
        ;;
        ;; Source moved out of this heredoc into
        ;; agent-shell/hub/decknix-hub-age-presets.el, packaged as
        ;; `decknix-hub-age-presets-el' (see the `let' block at the top
        ;; of this module).  The `(require ...)' stays HERE so that the
        ;; downstream `decknix--hub-age-visible-p' call sites further
        ;; down the workspace block (Requests / WIP / sessions render)
        ;; and the Toggles transient see the defvars + helpers as soon
        ;; as they're needed.  Sidebar-toggles also `(require ...)' it
        ;; so the saved-Sessions age toggle shares the same preset list.
        (require 'decknix-hub-age-presets)

        ;; -- Hub: direct-mention filter + bot filter (visibility predicates) --
        ;;
        ;; Pure source moved out of this heredoc into
        ;; agent-shell/hub/decknix-hub-mention-bot.el, packaged as
        ;; `decknix-hub-mention-bot-el' (see the `let' block at the
        ;; top of this module).  Two co-resident clusters in one file:
        ;;
        ;;   mention-filter:
        ;;     `decknix--hub-mention-filter'         (defvar, state)
        ;;     `decknix--hub-mention-filter-cycle'   (defvar, cycle order)
        ;;     `decknix--hub-mention-filter-normalize'  (legacy migration)
        ;;     `decknix--hub-mention-filter-label'   (state -> label)
        ;;     `decknix--hub-item-author-p'          (viewer match)
        ;;     `decknix--hub-item-mentioned-p'       (alist gate)
        ;;     `decknix--hub-item-team-requested-p'  (alist gate)
        ;;     `decknix--hub-mention-visible-p'      (combined predicate)
        ;;
        ;;   bot:
        ;;     `decknix--hub-show-bots'              (defvar, override)
        ;;     `decknix--hub-bot-patterns'           (defvar, regexps)
        ;;     `decknix--hub-bot-author-p'           (regexp predicate)
        ;;     `decknix--hub-bot-visible-p'          (item visibility)
        ;;
        ;; The two interactive sidebar mutators below stay in the
        ;; heredoc — they refresh the sidebar buffer (a heredoc-side
        ;; concern) and the `M-' transient suffixes still target them
        ;; by symbol.
        (require 'decknix-hub-mention-bot)

        ;; PR status cache + persistence (PR B.24) — owns the URL ->
        ;; status hash, its TTL constants, and save/restore to disk.
        ;; Required before `decknix-hub-pr-lookup' which reads the
        ;; cache via forward `defvar' declarations.
        (require 'decknix-hub-pr-cache)
        (declare-function decknix--hub-pr-cache-save "decknix-hub-pr-cache")
        (declare-function decknix--hub-pr-cache-restore "decknix-hub-pr-cache")

        ;; Save cache periodically (every 2 min) and on kill
        (run-with-timer 120 120 #'decknix--hub-pr-cache-save)
        (add-hook 'kill-emacs-hook #'decknix--hub-pr-cache-save)
        ;; Restore on startup
        (decknix--hub-pr-cache-restore)

        ;; -- Hub: PR status lookup from cached WIP + Reviews data --
        ;;
        ;; Sources moved out of this heredoc into
        ;; agent-shell/hub-lookup/decknix-hub-pr-lookup.el, packaged
        ;; as `decknix-hub-pr-lookup-el':
        ;;
        ;;   decknix--hub-pr-status-from-hub  — walks `decknix--hub-wip'
        ;;     and `decknix--hub-reviews' (heredoc-resident globals,
        ;;     dynamically resolved by the module's forward defvars).
        ;;   decknix--hub-pr-cache-get        — TTL-gated read of the
        ;;     `decknix--hub-pr-cache' hash table; appends
        ;;     `(stale . t)' on TTL miss instead of returning nil so
        ;;     callers can show old data with a refresh indicator.
        (require 'decknix-hub-pr-lookup)

        ;; Repo HEAD status cache + persistence (PR B.27) — owns the
        ;; "OWNER/REPO#BRANCH" -> status hash, its TTL constant, and
        ;; save/restore to disk.  Direct parallel to
        ;; `decknix-hub-pr-cache' above; the cache reader and status
        ;; orchestrator stay in hub-bulk because they call the async
        ;; fetcher.
        (require 'decknix-hub-repo-cache)
        (declare-function decknix--hub-repo-cache-save "decknix-hub-repo-cache")
        (declare-function decknix--hub-repo-cache-restore "decknix-hub-repo-cache")

        (run-with-timer 120 120 #'decknix--hub-repo-cache-save)
        (add-hook 'kill-emacs-hook #'decknix--hub-repo-cache-save)
        (decknix--hub-repo-cache-restore)

        ;; -- Hub: worktree parser + canonical helpers --
        ;;
        ;; Pure source moved out of this heredoc into
        ;; agent-shell/hub/decknix-hub-worktree-parse.el, packaged as
        ;; `decknix-hub-worktree-parse-el' (see the `let' block at the
        ;; top of this module).  Four leaf primitives consumed by the
        ;; surrounding registry layer (which still lives in this
        ;; heredoc, pending its own follow-up extraction):
        ;;
        ;;   `decknix--hub-worktree-canonical-repo'   (string normalize)
        ;;   `decknix--hub-worktree-repo-from-url'    (URL -> "owner/repo")
        ;;   `decknix--hub-worktree-normalize-path'   (~-expansion)
        ;;   `decknix--hub-worktree-parse-porcelain'  (porcelain parser)
        (require 'decknix-hub-worktree-parse)

        (run-with-timer 120 120 #'decknix--hub-worktree-cache-save)
        (add-hook 'kill-emacs-hook #'decknix--hub-worktree-cache-save)
        (decknix--hub-worktree-cache-restore)

        (when decknix-hub-eager-clone-probe
          (run-with-idle-timer 5 nil #'decknix--hub-worktree-eager-pass))

        ;; -- Hub: age formatter + sidebar icon helpers --
        ;;
        ;; Source moved out of this heredoc into
        ;; agent-shell/hub/decknix-hub-icons.el, packaged as
        ;; `decknix-hub-icons-el' (see the `let' block at the top of
        ;; this module).  Provides:
        ;;
        ;;   `decknix--hub-format-age'         (ISO -> "Nd"/"Nh"/etc.)
        ;;   `decknix--hub-review-icon'        (review state glyph)
        ;;   `decknix--hub-wip-review-icon'    (review-decision glyph)
        ;;   `decknix--hub-activity-icons'     (🤖/💬/↩ stack)
        ;;   `decknix--hub-wip-reply-icon'     (legacy alias)
        ;;
        ;; -- Hub: CI classification + sidebar icon helpers --
        ;;
        ;; Source moved out of this heredoc into
        ;; agent-shell/hub/decknix-hub-ci.el, packaged as
        ;; `decknix-hub-ci-el'.  Provides:
        ;;
        ;;   `decknix--hub-ci-soft-patterns'  (defvar)
        ;;   `decknix--hub-ci-check-soft-p'   (single-check predicate)
        ;;   `decknix--hub-ci-classify'       (alist -> refined status)
        ;;   `decknix--hub-icon'              (emoji-vs-text propertize)
        ;;   `decknix--hub-ci-icon'           (status -> glyph + face,
        ;;                                     plus optional CONFLICTING)
        ;;
        ;; decknix-hub-icons.el internally `(require 'decknix-hub-ci)`
        ;; for `decknix--hub-icon' so the require below covers both.
        (require 'decknix-hub-ci)
        (require 'decknix-hub-icons)

        ;; CI status filter (PR B.30) -- owns the visible-status
        ;; list, the render-order alist, the visibility predicate
        ;; consumed by sidebar Requests/WIP, the propertised footer
        ;; summary, and the per-bucket toggle commands wired to the
        ;; transient suffixes in hub-bulk.  Depends on
        ;; `decknix-hub-ci' for `decknix--hub-ci-classify'.
        (require 'decknix-hub-ci-filter)
        (declare-function decknix--hub-ci-status-of "decknix-hub-ci-filter" (item))
        (declare-function decknix--hub-ci-visible-p "decknix-hub-ci-filter" (item))
        (declare-function decknix--hub-ci-filter-summary "decknix-hub-ci-filter")
        (declare-function decknix--hub-ci-toggle-status "decknix-hub-ci-filter" (status))
        (declare-function decknix--hub-ci-filter-refresh "decknix-hub-ci-filter")
        (declare-function decknix--hub-ci-filter-toggle-pass "decknix-hub-ci-filter")
        (declare-function decknix--hub-ci-filter-toggle-soft "decknix-hub-ci-filter")
        (declare-function decknix--hub-ci-filter-toggle-running "decknix-hub-ci-filter")
        (declare-function decknix--hub-ci-filter-toggle-unknown "decknix-hub-ci-filter")
        (declare-function decknix--hub-ci-filter-toggle-fail "decknix-hub-ci-filter")
        (declare-function decknix--hub-ci-filter-show-all "decknix-hub-ci-filter")
        (declare-function decknix--hub-ci-filter-show-none "decknix-hub-ci-filter")
        (declare-function decknix--hub-ci-filter-status-desc
                          "decknix-hub-ci-filter" (status icon label))

        ;; Attention filter cluster (PR B.33) -- owns the seven
        ;; toggle state defvars (Requests/WIP needs-reply / bot-
        ;; pending / only-my-replies plus the Requests sort-reverse
        ;; flag), the engine (`sort-requests', the shared
        ;; `attention-visible-p' predicate, and the Requests/WIP
        ;; flavoured wrappers), the shared `toggle-and-refresh'
        ;; helper, and the seven per-bucket toggle commands wired
        ;; to the sidebar Toggles transient (`T') in workspace-
        ;; bulk and the transient suffixes still living in
        ;; hub-bulk.  No external deps -- the sidebar refresh
        ;; side-effect is `fboundp'-gated inside
        ;; `toggle-and-refresh'.
        (require 'decknix-hub-attention-filter)
        (declare-function decknix--hub-sort-requests "decknix-hub-attention-filter" (items))
        (declare-function decknix--hub-attention-visible-p
                          "decknix-hub-attention-filter"
                          (item hide-reply hide-bot only-my))
        (declare-function decknix--hub-requests-attention-visible-p
                          "decknix-hub-attention-filter" (item))
        (declare-function decknix--hub-wip-attention-visible-p
                          "decknix-hub-attention-filter" (pr))
        (declare-function decknix--hub-toggle-and-refresh
                          "decknix-hub-attention-filter" (sym message-fmt))
        (declare-function decknix--hub-toggle-requests-hide-needs-reply
                          "decknix-hub-attention-filter")
        (declare-function decknix--hub-toggle-requests-hide-bot-pending
                          "decknix-hub-attention-filter")
        (declare-function decknix--hub-toggle-requests-only-my-replies
                          "decknix-hub-attention-filter")
        (declare-function decknix--hub-toggle-requests-sort-reverse
                          "decknix-hub-attention-filter")
        (declare-function decknix--hub-toggle-wip-hide-needs-reply
                          "decknix-hub-attention-filter")
        (declare-function decknix--hub-toggle-wip-hide-bot-pending
                          "decknix-hub-attention-filter")
        (declare-function decknix--hub-toggle-wip-only-my-replies
                          "decknix-hub-attention-filter")

        ;; "Ready for review" reader (PRs B.50 + B.51) -- carved
        ;; out of `decknix-agent-shell-workspace' (workspace-bulk).
        ;; Owns the four-clause pure predicate
        ;; (`decknix--hub-request-ready-p') plus the two readers
        ;; that compose it with the visibility / sort / icon
        ;; helpers: `decknix--hub-review-ready-requests' returns
        ;; the ready subset of `decknix--hub-reviews'; and
        ;; `decknix--hub-review-entries' turns that subset into
        ;; the `(LABEL . ITEM)' cons cells the `r' picker
        ;; consumes.  Depends on `decknix--hub-ci-classify' from
        ;; `decknix-hub-ci', the visibility predicates already
        ;; carved into `decknix-hub-{age-presets,ci-filter,
        ;; mention-bot,attention-filter}', the icons in
        ;; `decknix-hub-{icons,ci}', and two helpers still in
        ;; hub-bulk (`request-has-live-session-p',
        ;; `request-tint-active') reached via `declare-function'.
        ;; No side effects, no UI.
        (require 'decknix-hub-ready-filter)
        (declare-function decknix--hub-request-ready-p
                          "decknix-hub-ready-filter" (item))
        (declare-function decknix--hub-review-ready-requests
                          "decknix-hub-ready-filter")
        (declare-function decknix--hub-review-entries
                          "decknix-hub-ready-filter"
                          (&optional mention-only))

        ;; Repo-name cap cluster (PR B.36) -- decides how
        ;; aggressively the repo segment of an ungrouped PR line is
        ;; truncated.  Owns the cap state defvar
        ;; (`decknix--hub-repo-name-cap'), the pure truncator
        ;; (`decknix--hub-repo-name-apply') called from the
        ;; columnar PR row renderers in hub-bulk and the footer
        ;; toggle label in workspace-bulk, and the interactive
        ;; cycler (`decknix--hub-cycle-repo-name-cap') wired to
        ;; the `N' suffix in the sidebar Toggles transient.  No
        ;; external deps -- the sidebar refresh callback is
        ;; gated by a `get-buffer' check.
        (require 'decknix-hub-repo-name)
        (defvar decknix--hub-repo-name-cap)
        (declare-function decknix--hub-repo-name-apply
                          "decknix-hub-repo-name" (repo))
        (declare-function decknix--hub-cycle-repo-name-cap
                          "decknix-hub-repo-name")

        ;; WIP "hide linked" toggle (PR B.39) -- when non-nil
        ;; (the default), PRs that are already live as agent-
        ;; shell sessions are dropped from the WIP section so
        ;; the row doesn't duplicate noise the live row already
        ;; carries.  Owns the toggle state defvar and the
        ;; interactive flipper bound to the `L' suffix in the
        ;; WIP section of the sidebar Toggles transient (the
        ;; transient suffix itself stays in hub-bulk per Rule
        ;; 2).  No external deps -- the sidebar refresh callback
        ;; is gated by a `get-buffer' check.
        (require 'decknix-hub-wip-link-filter)
        (defvar decknix--hub-wip-hide-linked)
        (declare-function decknix--hub-toggle-wip-hide-linked
                          "decknix-hub-wip-link-filter")



        ;; -- TeamCity build status + deploy pipeline indicator --
        ;;
        ;; Source moved out of this heredoc into
        ;; agent-shell/hub/decknix-hub-teamcity.el, packaged as
        ;; `decknix-hub-teamcity-el' (see the `let' block at the top
        ;; of this module).  By this point in the heredoc the hub
        ;; data defvars (`decknix--hub-teamcity-builds',
        ;; `decknix--hub-deploys', `decknix--hub-show-deploys') have
        ;; already been declared above (~line 10595), so the module's
        ;; forward-decl + load-time `(require ...)' resolves cleanly.
        ;; The `decknix--hub-toggle-deploy-indicator' command stays
        ;; here for now — it mutates the UI flag and triggers a
        ;; sidebar refresh, both of which are heredoc-side concerns.
        (require 'decknix-hub-teamcity)

        ;; -- Jira task status icon --
        ;;
        ;; Source moved out of this heredoc into
        ;; agent-shell/hub/decknix-hub-jira-tasks.el, packaged as
        ;; `decknix-hub-jira-tasks-el' (see the `let' block at the top
        ;; of this module).  The renderer immediately below
        ;; (`decknix--hub-render-tasks') stays here — it inserts text
        ;; into the sidebar buffer, which is a heredoc-side concern.
        (require 'decknix-hub-jira-tasks)

        ;; == Progress (data layer + UI buffer + sidebar badges) ==
        ;;
        ;; Source moved out of this heredoc into standalone .el files under
        ;; agent-shell/progress/, packaged as `decknix-progress-el' (see the
        ;; `let' block at the top of this module).  The `(require ...)' calls
        ;; stay HERE — load order matters: by this point in the heredoc the
        ;; surrounding `default.el' has already established
        ;; `decknix-agent-prefix-map' (the UI binds `P' on it) and the hub
        ;; data variables (`decknix--hub-wip', `decknix--hub-jira-tasks').
        ;;
        ;; The trailing key-binding and watch-start are *here*, not in the
        ;; .el files: when `default.el' is byte-compiled at Nix-build time,
        ;; `(require ...)' triggers loading of those files; if they touched
        ;; `decknix-agent-prefix-map' or fired file-notify hooks at top
        ;; level, the byte-compiler step would crash because the prefix-map
        ;; defun above has not yet been *evaluated* (only seen).  Keeping
        ;; the side-effects here makes them runtime-only.
        (require 'decknix-progress)
        (require 'decknix-progress-ui)
        (require 'decknix-progress-sidebar)
        (define-key decknix-agent-prefix-map (kbd "P") 'decknix-progress)
        (decknix-progress--sidebar-start-watch)
      ''
      + optionalString cfg.context.enable ''

        ;; == Context Panel: issues, PRs, CI status, reviews ==
        ;; Surfaces work context in the header-line with C-c i navigation.
        ;; The 35 declarations that build the panel (data model, GitHub
        ;; fetchers, header rendering, full-refresh + commands) live in
        ;; the in-tree package `decknix-agent-shell-context-el' (PR
        ;; B-Bulk.1).  Only side-effects that depend on heredoc-resident
        ;; runtime state (the kill-buffer hook for autosave; the keymap
        ;; mounted on `decknix-agent-prefix-map') stay here, immediately
        ;; after the require so symbols resolve at byte-compile time.
        (require 'decknix-agent-shell-context)

        ;; Auto-save context when killing agent-shell buffers
        (add-hook 'kill-buffer-hook
                  (lambda ()
                    (when (derived-mode-p 'agent-shell-mode)
                      (decknix--context-save))))

        ;; -- Global keybindings: C-c A i prefix --
        (define-prefix-command 'decknix-agent-context-map)
        (define-key decknix-agent-prefix-map (kbd "i") 'decknix-agent-context-map)
        (define-key decknix-agent-context-map (kbd "i") 'decknix-context-list-issues)
        (define-key decknix-agent-context-map (kbd "p") 'decknix-context-list-prs)
        (define-key decknix-agent-context-map (kbd "c") 'decknix-context-show-ci)
        (define-key decknix-agent-context-map (kbd "r") 'decknix-context-show-reviews)
        (define-key decknix-agent-context-map (kbd "a") 'decknix-context-pin)
        (define-key decknix-agent-context-map (kbd "d") 'decknix-context-unpin)
        (define-key decknix-agent-context-map (kbd "g") 'decknix-context-browse)
        (define-key decknix-agent-context-map (kbd "f") 'decknix-context-forge-visit)
      ''
      + optionalString cfg.attention.enable ''

        ;; == Attention: mode-line indicator + jump-to-pending ==
        (require 'agent-shell-attention)
        (agent-shell-attention-mode 1)

        ;; Show both pending and busy counts: AS:n/m
        (setq agent-shell-attention-render-function
              #'agent-shell-attention-render-active)

        ;; Jump to session needing attention
        (define-key decknix-agent-prefix-map (kbd "j") 'agent-shell-attention-jump)
      ''
      + optionalString cfg.templates.enable ''

        ;; == Yasnippet prompt templates ==
        ;; Register snippet directories for agent-shell and batch-compose modes
        (with-eval-after-load 'yasnippet
          (dolist (dir (list (expand-file-name "~/${snippetDir}")
                             (expand-file-name "~/${batchSnippetDir}")))
            (unless (member dir yas-snippet-dirs)
              (push dir yas-snippet-dirs))
            (when (file-directory-p dir)
              (yas-load-directory dir))))

        ;; C-c A t — template sub-prefix ("Templates")
        (define-prefix-command 'decknix-agent-template-map)
        (define-key decknix-agent-prefix-map (kbd "t") 'decknix-agent-template-map)
        (define-key decknix-agent-template-map (kbd "t") 'yas-insert-snippet)       ; Insert
        (define-key decknix-agent-template-map (kbd "n") 'yas-new-snippet)          ; New
        (define-key decknix-agent-template-map (kbd "e") 'yas-visit-snippet-file)   ; Edit
      ''
      + ''

        ;; == always-tail: header-line + per-buffer setup ==
        ;; The 13 helpers that build the unified header-line and
        ;; the buffer-local setup hook live in
        ;; `decknix-agent-shell-main-el' (PR B-Bulk.3a).  Side-
        ;; effects (advice on agent-shell internals, agent-shell-
        ;; mode-hook with its giant per-buffer keymap setup) stay
        ;; here because they bind heredoc-resident symbols.


        ;; Prevent agent-shell's built-in header from overwriting ours.
        ;; agent-shell--update-header-and-mode-line is called from many
        ;; places (mode changes, session updates, busy indicator, etc.)
        ;; and sets header-line-format to its own value.  We override it
        ;; to use our unified header instead, which already incorporates
        ;; status, tags, workspace, and context panel data.
        (advice-add 'agent-shell--update-header-and-mode-line :override
          (lambda (&rest _args)
            "Use the unified decknix header instead of agent-shell's default."
            (when (derived-mode-p 'agent-shell-mode)
              (decknix--header-update)
              (force-mode-line-update))))

        ;; Guard all submit paths against a dead/missing process or config.
        ;; shell-maker-submit is the single entry point for sending input
        ;; (used by RET in the shell buffer, compose C-c C-c, and programmatic calls).
        ;; Without this, submitting before the process has started or after it
        ;; has exited produces: "Wrong type argument: processp, nil" or
        ;; "Wrong type argument: shell-maker-config, nil".
        ;; Uses :around advice so we can block the call entirely.
        (advice-add 'shell-maker-submit :around
                    (lambda (orig-fn &rest args)
                      (if (or (not (boundp 'shell-maker--config))
                              (null shell-maker--config)
                              (not (get-buffer-process (current-buffer)))
                              (not (process-live-p (get-buffer-process (current-buffer)))))
                          (user-error "Agent process not ready — wait for it to start or restart with C-c A a")
                        (apply orig-fn args))))

        ;; -- Auto-scroll: keep windows showing agent output at the bottom --
        ;; shell-maker's output filter uses `with-current-buffer' + `goto-char
        ;; (point-max)' which only sets the buffer's point, not the window's
        ;; point when the buffer is displayed in a non-selected window.
        ;; This advice scrolls all windows showing the buffer to the bottom,
        ;; but ONLY if their point was already at or near the end (i.e., the
        ;; user hadn't scrolled up to read earlier output).
        (advice-add 'shell-maker--output-filter :after
                    (lambda (_process _string)
                      (when (derived-mode-p 'agent-shell-shell-mode)
                        (let ((buf (current-buffer)))
                          (dolist (win (get-buffer-window-list buf nil t))
                            ;; If the window's point was at the end before
                            ;; the insert, scroll it to the new end.
                            ;; We check if window-point is within a few chars
                            ;; of point-max (the insert moved point-max forward,
                            ;; but the window's old point is now "behind").
                            (let ((wp (window-point win))
                                  (pm (point-max)))
                              (when (>= wp (- pm (length (or _string ""))))
                                (set-window-point win pm))))))))

        ;; Disable line numbers in agent-shell buffers
        ;; TAB dispatches between snippet field navigation and expansion
        ;; In-buffer shortcuts: C-c x (no A prefix needed inside agent-shell)
        (add-hook 'agent-shell-mode-hook
                  (lambda ()
                    (display-line-numbers-mode 0)
                    ;; Auto-persist workspace on first exchange — safety net
                    ;; for sessions created via any path (upstream c, resume,
                    ;; quickaction, etc.) so they never show as "unknown".
                    (decknix--agent-auto-persist-workspace)
                    ;; Disable cape-file in agent-shell buffers — synchronous
                    ;; filesystem scans freeze the cursor during typing.
                    (setq-local completion-at-point-functions
                                (remove #'cape-file completion-at-point-functions))
                    ;; Keep prompt pinned to the bottom of the window
                    (setq-local comint-scroll-to-bottom-on-input t)
                    (setq-local comint-scroll-to-bottom-on-output t)
                    (setq-local comint-scroll-show-maximum-output t)
                    (local-set-key (kbd "TAB") 'decknix--agent-tab-dwim)
                    (local-set-key (kbd "<tab>") 'decknix--agent-tab-dwim)
                    ;; Buffer-local bindings — no C-c A prefix needed inside agent-shell.
                    ;; Native bindings: C-c C-c (interrupt), C-c C-v (model), C-c C-m (mode)
                    ;; Override C-c C-v so model changes are persisted to
                    ;; agent-sessions.json and survive session resume.
                    (local-set-key (kbd "C-c C-v") 'decknix-agent-set-session-model)
                    (local-set-key (kbd "C-c b") 'decknix-agent-switch-buffer)
                    (local-set-key (kbd "C-c e") 'decknix-agent-compose)
                    (local-set-key (kbd "C-c E") 'decknix-agent-compose-interrupt)
                    (local-set-key (kbd "C-c ?") decknix-agent-help-map)
                    (local-set-key (kbd "C-c r") 'agent-shell-rename-buffer)
                    ;; C-c s — session sub-prefix
                    (let ((map (make-sparse-keymap)))
                      (define-key map (kbd "s") 'decknix-agent-session-picker)
                      (define-key map (kbd "n") 'decknix-agent-session-new)
                      (define-key map (kbd "q") 'decknix-agent-session-quit)
                      (define-key map (kbd "g") 'decknix-agent-session-grep)
                      (define-key map (kbd "h") 'decknix-agent-session-history)
                      (define-key map (kbd "c") 'decknix--agent-context-toggle)
                      (define-key map (kbd "y") 'decknix-agent-session-copy-id)
                      (define-key map (kbd "d") 'decknix-agent-session-toggle-id-display)
                      (define-key map (kbd "l") 'decknix-agent-link-pr)
                      (define-key map (kbd "L") 'decknix-agent-link-repo)
                      (define-key map (kbd "u") 'decknix-agent-unlink-pr)
                      (local-set-key (kbd "C-c s") map))
                    ;; which-key labels for C-c s session sub-prefix
                    (when (fboundp 'which-key-add-key-based-replacements)
                      (which-key-add-key-based-replacements
                        "C-c s"   "session…"
                        "C-c s s" "picker (live+saved)"
                        "C-c s n" "new session"
                        "C-c s q" "quit session"
                        "C-c s g" "grep all sessions"
                        "C-c s h" "history"
                        "C-c s c" "toggle context history"
                        "C-c s y" "copy session ID"
                        "C-c s d" "toggle ID display"
                        "C-c s l" "link PR"
                        "C-c s L" "link repo+branch"
                        "C-c s u" "unlink PR / repo"))
                    ;; Conditional bindings (may not be loaded)
                    (when (fboundp 'agent-shell-manager-toggle)
                      (local-set-key (kbd "C-c m") 'agent-shell-manager-toggle))
                    (when (fboundp 'agent-shell-workspace-toggle)
                      (local-set-key (kbd "C-c w") 'agent-shell-workspace-toggle))
                    (when (fboundp 'agent-shell-attention-jump)
                      (local-set-key (kbd "C-c j") 'agent-shell-attention-jump))
                    ;; C-c i — context sub-prefix in-buffer
                    (when (fboundp 'decknix-context-panel)
                      (let ((map (make-sparse-keymap)))
                        (define-key map (kbd "i") 'decknix-context-list-issues)
                        (define-key map (kbd "p") 'decknix-context-list-prs)
                        (define-key map (kbd "c") 'decknix-context-show-ci)
                        (define-key map (kbd "r") 'decknix-context-show-reviews)
                        (define-key map (kbd "a") 'decknix-context-pin)
                        (define-key map (kbd "d") 'decknix-context-unpin)
                        (define-key map (kbd "g") 'decknix-context-browse)
                        (define-key map (kbd "f") 'decknix-context-forge-visit)
                        (local-set-key (kbd "C-c i") map))
                      (local-set-key (kbd "C-c I") 'decknix-context-toggle-or-panel)
                      ;; Restore pinned items from previous session, then refresh
                      (decknix--context-restore)
                      (decknix--context-full-refresh)
                      (decknix--context-start-ci-polling))
                    ;; C-c t — template sub-prefix in-buffer
                    (when (fboundp 'yas-insert-snippet)
                      (let ((map (make-sparse-keymap)))
                        (define-key map (kbd "t") 'yas-insert-snippet)
                        (define-key map (kbd "n") 'yas-new-snippet)
                        (define-key map (kbd "e") 'yas-visit-snippet-file)
                        (local-set-key (kbd "C-c t") map)))
                    ;; C-c c — commands sub-prefix in-buffer
                    (let ((map (make-sparse-keymap)))
                      (define-key map (kbd "c") 'decknix-agent-command-run)
                      (define-key map (kbd "n") 'decknix-agent-command-new)
                      (define-key map (kbd "e") 'decknix-agent-command-edit)
                      (local-set-key (kbd "C-c c") map))
                    ;; C-c T — session-scoped tags sub-prefix in-buffer
                    (let ((map (make-sparse-keymap)))
                      (define-key map (kbd "l") 'decknix-agent-tag-show)      ; List this session's tags
                      (define-key map (kbd "a") 'decknix-agent-tag-add)       ; Add tag (create or select)
                      (define-key map (kbd "r") 'decknix-agent-tag-remove)    ; Remove tag
                      (local-set-key (kbd "C-c T") map))
                    ;; Unified header-line: status + tags + workspace + context
                    (decknix--header-update)
                    (decknix--header-start-timer)
                    (add-hook 'kill-buffer-hook #'decknix--header-stop-timer nil t)))
      '';
    };
  };
}
