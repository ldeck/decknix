# Generate options documentation for decknix modules.
#
# Usage:
#   nix-build docs/generate-options.nix -A markdown -o docs/src/options-generated.md
#   nix-build docs/generate-options.nix -A json     -o docs/options.json
#
{ pkgs ? import <nixpkgs> {} }:

let
  lib = pkgs.lib;

  # Evaluate home-manager modules in isolation to extract their option declarations.
  # We only need the option *declarations*, not the config values.
  homeEval = lib.evalModules {
    modules = [
      # Import all home-manager modules from the framework
      ../modules/home/options.nix
      ../modules/home/options/cli/auggie.nix
      ../modules/home/options/cli/board.nix
      ../modules/home/options/cli/extensions.nix
      ../modules/home/options/cli/nix-github-auth.nix
      ../modules/home/options/editors/profiles.nix
      ../modules/home/options/editors/vim/whitespace.nix
      ../modules/home/options/editors/vim/skim.nix
      ../modules/home/options/editors/emacs/default.nix
      ../modules/home/options/editors/emacs/agent-shell.nix
      ../modules/home/options/editors/emacs/completion.nix
      ../modules/home/options/editors/emacs/development.nix
      ../modules/home/options/editors/emacs/editing.nix
      ../modules/home/options/editors/emacs/http.nix
      ../modules/home/options/editors/emacs/languages.nix
      ../modules/home/options/editors/emacs/lsp.nix
      ../modules/home/options/editors/emacs/magit.nix
      ../modules/home/options/editors/emacs/org.nix
      ../modules/home/options/editors/emacs/project.nix
      ../modules/home/options/editors/emacs/treemacs.nix
      ../modules/home/options/editors/emacs/ui.nix
      ../modules/home/options/editors/emacs/undo.nix
      ../modules/home/options/editors/emacs/welcome.nix
      ../modules/home/options/wm/aerospace/default.nix
      ../modules/home/options/wm/hammerspoon/default.nix
      ../modules/home/options/wm/spaces.nix

      # Minimal stubs for infrastructure options that modules set but don't declare.
      # These are normally provided by home-manager / NixOS; we only need them
      # so that evalModules doesn't error when config blocks set them.
      ({ ... }: {
        options.assertions = lib.mkOption {
          type = lib.types.listOf lib.types.unspecified;
          default = [];
          internal = true;
        };
        options.warnings = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          internal = true;
        };
        options.home = lib.mkOption { type = lib.types.submodule {}; default = {}; };
        options.xdg = lib.mkOption { type = lib.types.submodule {}; default = {}; };

        # programs.emacs stubs (the decknix modules set these in their config blocks)
        options.programs.emacs.enable = lib.mkOption { type = lib.types.bool; default = false; internal = true; };
        options.programs.emacs.package = lib.mkOption { type = lib.types.package; default = pkgs.emacs; internal = true; };
        options.programs.emacs.extraPackages = lib.mkOption { type = lib.types.functionTo (lib.types.listOf lib.types.package); default = _: []; internal = true; };
        options.programs.emacs.extraConfig = lib.mkOption { type = lib.types.lines; default = ""; internal = true; };

        # programs.vim stubs
        options.programs.vim.enable = lib.mkOption { type = lib.types.bool; default = false; internal = true; };
        options.programs.vim.plugins = lib.mkOption { type = lib.types.listOf lib.types.package; default = []; internal = true; };
        options.programs.vim.extraConfig = lib.mkOption { type = lib.types.lines; default = ""; internal = true; };

        # programs.zsh stubs
        options.programs.zsh.enable = lib.mkOption { type = lib.types.bool; default = false; internal = true; };
        options.programs.zsh.shellAliases = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = {}; internal = true; };
      })
    ];
    specialArgs = { inherit pkgs; inherit (pkgs) lib; };
  };

  # Filter to only decknix-namespaced options (and programs.*.decknix.* extensions)
  isDecknixOption = name:
    lib.hasPrefix "decknix." name ||
    builtins.match "programs\\.[^.]+\\.decknix\\..*" name != null;

  optionsDoc = pkgs.nixosOptionsDoc {
    options = homeEval.options;
    transformOptions = opt: opt // {
      visible = isDecknixOption opt.name;
    };
  };

in {
  # CommonMark output for embedding in mdBook
  markdown = optionsDoc.optionsCommonMark;

  # JSON output for JS search UI
  json = optionsDoc.optionsJSON;
}

