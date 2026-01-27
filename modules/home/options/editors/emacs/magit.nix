{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.magit;
in
{
  options.programs.emacs.decknix.magit = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Magit for Git integration in Emacs.";
    };

    forge = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Enable Forge for GitHub/GitLab PR and issue management.
          Provides: create/review PRs, manage issues, browse topics.
        '';
      };
    };

    codeReview = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Enable code-review for reviewing PRs with inline comments.
          Provides a diff-based PR review interface.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    # Ensure sqlite3 is available for emacsql-sqlite
    home.packages = mkIf cfg.forge.enable [ pkgs.sqlite ];

    programs.emacs = {
      extraPackages = epkgs: with epkgs;
        [ magit ]
        ++ optionals cfg.forge.enable [
          emacsql        # Must be first - database abstraction
          closql         # Must be before forge - SQL object-relational mapping
          forge
        ]
        ++ optionals cfg.codeReview.enable [
          emacsql        # code-review also needs emacsql
          closql         # code-review also needs closql
          code-review
        ];

      extraConfig = ''
        ;; Magit configuration
        ;; Autoload magit-status so it's available when called
        (autoload 'magit-status "magit" "Open Magit status buffer" t)

        ;; Set default magit keybinding
        (global-set-key (kbd "C-x g") 'magit-status)

        ;; Configure magit settings when it loads
        (with-eval-after-load 'magit
          ;; Show word-granularity differences within diff hunks
          (setq magit-diff-refine-hunk 'all))

      '' + optionalString cfg.forge.enable ''
        ;; == EmacSQL/Closql - Database for Forge ==
        ;; Load emacsql and closql BEFORE forge to ensure EIEIO classes are defined
        ;; This prevents "parent class X is not a class" errors
        (require 'emacsql)
        (require 'closql)

        ;; == Forge - GitHub/GitLab Integration ==
        ;; Provides PR creation, review, issue management within Magit
        (use-package forge
          :after magit
          :config
          ;; Pull forge data when entering magit-status
          (setq forge-add-default-bindings t)

          ;; Configure GitHub token auth (uses ~/.authinfo.gpg or auth-source)
          ;; Format: machine api.github.com login YOUR_USERNAME^forge password YOUR_TOKEN
          (setq auth-sources '("~/.authinfo.gpg" "~/.authinfo" "~/.netrc")))

        ;; Keybindings in magit-status:
        ;; @ f f - fetch topics (PRs/issues)
        ;; @ c p - create pull request
        ;; @ l p - list pull requests
        ;; @ l i - list issues
        ;; RET on PR - view PR details

      '' + optionalString cfg.codeReview.enable ''
        ;; == Code Review - PR Review Interface ==
        ;; Ensure emacsql/closql classes are defined before code-review loads
        (require 'emacsql)
        (require 'closql)

        (use-package code-review
          :after forge
          :config
          ;; Use forge's authentication
          (setq code-review-auth-login-marker 'forge))

        ;; From a PR in forge, use: M-x code-review-start
        ;; Or bind it: (define-key forge-topic-mode-map (kbd "C-c r") 'code-review-start)
      '';
    };
  };
}

