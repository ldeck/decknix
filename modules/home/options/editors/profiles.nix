{ config, lib, pkgs, ... }:

with lib;

let
  # Vim profile tiers
  vimProfile = config.decknix.editors.vim.profile;

  # Emacs profile tiers
  emacsProfile = config.decknix.editors.emacs.profile;

  # Emacs tier membership
  # Each module lists the minimum tier that includes it
  emacsTiers = {
    # minimal tier — core essentials
    completion = [ "minimal" "standard" "full" ];
    editing    = [ "minimal" "standard" "full" ];
    ui         = [ "minimal" "standard" "full" ];
    undo       = [ "minimal" "standard" "full" ];
    project    = [ "minimal" "standard" "full" ];

    # standard tier — daily development
    development = [ "standard" "full" ];
    magit       = [ "standard" "full" ];
    treemacs    = [ "standard" "full" ];
    languages   = [ "standard" "full" ];
    welcome     = [ "standard" "full" ];

    # full tier — power-user features
    lsp        = [ "full" ];
    org        = [ "full" ];
    http       = [ "full" ];
    agentShell = [ "full" ];
  };

  emacsEnabled = module:
    emacsProfile != "custom" && builtins.elem emacsProfile (emacsTiers.${module} or []);

in {
  options.decknix.editors = {
    vim.profile = mkOption {
      type = types.enum [ "minimal" "standard" "custom" ];
      default = "standard";
      description = ''
        Vim editor profile tier.

        - minimal:  Base config only (set exrc, number, secure)
        - standard: Base + whitespace + skim (fuzzy finder) plugins (default)
        - custom:   User-provided configuration (disables framework vim config)
      '';
    };

    emacs.profile = mkOption {
      type = types.enum [ "minimal" "standard" "full" "custom" ];
      default = "full";
      description = ''
        Emacs editor profile tier.

        - minimal:  Core + completion + editing + ui + undo + project
        - standard: Minimal + development + magit + treemacs + languages + welcome
        - full:     Standard + lsp + org + http + agent-shell (default)
        - custom:   User-provided configuration (disables framework emacs config)
      '';
    };
  };

  config = mkMerge [
    # --- Vim tiering ---
    (mkIf (vimProfile == "minimal") {
      programs.vim.decknix.whitespace.enable = mkDefault false;
      programs.vim.decknix.skim.enable = mkDefault false;
    })
    (mkIf (vimProfile == "standard") {
      programs.vim.decknix.whitespace.enable = mkDefault true;
      programs.vim.decknix.skim.enable = mkDefault true;
    })
    (mkIf (vimProfile == "custom") {
      programs.vim.enable = mkDefault false;
      programs.vim.decknix.whitespace.enable = mkDefault false;
      programs.vim.decknix.skim.enable = mkDefault false;
    })

    # --- Emacs tiering ---
    (mkIf (emacsProfile != "custom") {
      programs.emacs.decknix.completion.enable  = mkDefault (emacsEnabled "completion");
      programs.emacs.decknix.editing.enable     = mkDefault (emacsEnabled "editing");
      programs.emacs.decknix.ui.enable          = mkDefault (emacsEnabled "ui");
      programs.emacs.decknix.undo.enable        = mkDefault (emacsEnabled "undo");
      programs.emacs.decknix.project.enable     = mkDefault (emacsEnabled "project");
      programs.emacs.decknix.development.enable = mkDefault (emacsEnabled "development");
      programs.emacs.decknix.magit.enable       = mkDefault (emacsEnabled "magit");
      programs.emacs.decknix.treemacs.enable    = mkDefault (emacsEnabled "treemacs");
      programs.emacs.decknix.languages.enable   = mkDefault (emacsEnabled "languages");
      programs.emacs.decknix.welcome.enable     = mkDefault (emacsEnabled "welcome");
      programs.emacs.decknix.lsp.enable         = mkDefault (emacsEnabled "lsp");
      programs.emacs.decknix.org.enable         = mkDefault (emacsEnabled "org");
      programs.emacs.decknix.http.enable        = mkDefault (emacsEnabled "http");
      programs.emacs.decknix.agentShell.enable  = mkDefault (emacsEnabled "agentShell");
    })
    (mkIf (emacsProfile == "custom") {
      programs.emacs.decknix.enable = mkDefault false;
    })
  ];
}

