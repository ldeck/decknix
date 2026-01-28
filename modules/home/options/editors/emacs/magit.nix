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

      accounts = mkOption {
        type = types.listOf (types.submodule {
          options = {
            host = mkOption {
              type = types.str;
              default = "github.com";
              description = "Git forge host (e.g., github.com, gitlab.com).";
            };
            username = mkOption {
              type = types.str;
              description = "Username for this account.";
            };
            remote = mkOption {
              type = types.str;
              default = "origin";
              description = "Git remote to use for this account.";
            };
          };
        });
        default = [ ];
        example = [
          { host = "github.com"; username = "personal-user"; }
          { host = "github.com"; username = "work-user"; remote = "origin"; }
        ];
        description = ''
          GitHub/GitLab accounts for Forge. Each account needs a corresponding
          entry in ~/.authinfo.gpg or ~/.authinfo:

            machine api.github.com login USERNAME^forge password TOKEN

          For multiple accounts on the same host, Forge uses the repository's
          remote URL to determine which account to use.
        '';
      };
    };

    codeReview = {
      enable = mkOption {
        type = types.bool;
        default = false;  # Disabled: code-review is incompatible with current emacsql
        description = ''
          Enable code-review for reviewing PRs with inline comments.
          Provides a diff-based PR review interface.

          NOTE: Currently disabled by default because code-review uses an
          outdated emacsql API (expects emacsql-sqlite-connection to be a class,
          but it's now a function). This causes "parent class is not a class" errors.
          Use Forge's built-in PR review features instead.
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

        ;; Load magit-extras for project.el integration
        ;; This provides magit-project-status for C-x p m (project-switch magit)
        ;; Must be loaded before project.el tries to use it
        (with-eval-after-load 'project
          (require 'magit-extras))

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
        ;;
        ;; IMPORTANT: Forge must be loaded WITH magit, not just after.
        ;; We use with-eval-after-load to ensure forge loads when magit loads,
        ;; which sets up the '@' keybinding prefix in magit-mode-map.
        (with-eval-after-load 'magit
          (require 'forge)

          ;; Ensure forge bindings are added to magit
          (setq forge-add-default-bindings t)

          ;; Configure auth sources (uses ~/.authinfo.gpg or auth-source)
          ;; For multi-account support, add multiple entries to ~/.authinfo.gpg:
          ;;
          ;;   machine api.github.com login PERSONAL_USER^forge password ghp_xxxxx
          ;;   machine api.github.com login WORK_USER^forge password ghp_yyyyy
          ;;
          ;; Forge automatically selects the correct account based on the repository's
          ;; remote URL and the owner field in ghub's configuration.
          (setq auth-sources '("~/.authinfo.gpg" "~/.authinfo" "~/.netrc"))

          ;; Enable commit author email in topic views
          (setq forge-topic-list-columns
                '(("#" 5 t (:right-align t) number nil)
                  ("Title" 50 t nil title nil)
                  ("Author" 15 t nil author nil)
                  ("State" 8 t nil state nil)
                  ("Updated" 10 t nil updated nil)))

          ;; Enable notifications fetching
          (setq forge-pull-notifications t))

        ;; ============================================================
        ;; == Multi-Account GitHub Configuration ==
        ;; ============================================================
        ;;
        ;; Forge uses ghub for API authentication. For multiple GitHub accounts,
        ;; the workflow is:
        ;;
        ;; 1. SETUP AUTHINFO (do once):
        ;;    Create ~/.authinfo.gpg with entries for each account:
        ;;
        ;;    machine api.github.com login ldeck^forge password ghp_personal_token
        ;;    machine api.github.com login lachlan-work^forge password ghp_work_token
        ;;
        ;; 2. FIRST TIME PER-REPO:
        ;;    When you first use Forge in a repo, it will prompt for username.
        ;;    Enter the appropriate username for that repo's organization.
        ;;    This is stored in .git/config as:
        ;;      [github "user"]
        ;;        username = lachlan-work
        ;;
        ;; 3. AUTOMATIC THEREAFTER:
        ;;    Forge uses the stored username to select the correct token.
        ;;
        ;; TIP: Use git conditional includes for automatic email switching:
        ;;   [includeIf "gitdir:~/Code/work/"]
        ;;     path = ~/.gitconfig-work

        ;; ============================================================
        ;; == PR Review Workflow ==
        ;; ============================================================

        ;; Custom function to start PR review on current topic
        (defun decknix-forge-review-pr ()
          "Review the pull request at point or in current buffer.
        Opens the PR diff and allows adding review comments."
          (interactive)
          (if (derived-mode-p 'forge-topic-mode)
              ;; In a PR buffer, show the diff
              (forge-visit-pullreq-diff)
            ;; In list or magit status, visit the PR at point first
            (when-let ((pullreq (forge-pullreq-at-point)))
              (forge-visit-topic pullreq))))

        ;; Custom function to view PR diff with full context
        (defun decknix-forge-pr-diff-full ()
          "Show the full diff for the PR at point with maximum context."
          (interactive)
          (let ((magit-diff-refine-hunk 'all))
            (forge-visit-pullreq-diff)))

        ;; Add review keybindings to forge topic mode
        ;; (forge is already loaded via with-eval-after-load 'magit above)
        (with-eval-after-load 'forge
          (define-key forge-topic-mode-map (kbd "C-c C-r") 'decknix-forge-review-pr)
          (define-key forge-topic-mode-map (kbd "C-c C-d") 'decknix-forge-pr-diff-full))

        ;; ============================================================
        ;; == Forge Keybindings Reference ==
        ;; ============================================================
        ;;
        ;; IN MAGIT STATUS (C-x g):
        ;;   ' or N    Open Forge dispatch menu, then:
        ;;     f f     Fetch forge topics (PRs/issues)
        ;;     f n     Fetch notifications
        ;;     c p     Create pull request
        ;;     l p     List pull requests
        ;;     l i     List issues
        ;;
        ;; ON A PR/ISSUE:
        ;;   RET       View topic details
        ;;   C-c C-v   Visit topic at point
        ;;   C-c C-r   Review PR (view diff) [decknix]
        ;;   C-c C-d   Show full PR diff [decknix]
        ;;
        ;; IN PR TOPIC BUFFER:
        ;;   C-c C-e   Edit title/description
        ;;   C-c C-k   Close PR
        ;;   C-c C-o   Reopen PR
        ;;   C-c C-m   Merge PR
        ;;   w         Copy PR URL
        ;;   b         Browse PR in browser
        ;;
        ;; IN PR DIFF (reviewing):
        ;;   C-c C-c   Add review comment at point
        ;;   C-c C-a   Approve PR
        ;;   C-c C-r   Request changes
        ;;   C-c C-s   Submit review
        ;;
        ;; ADDING COMMENTS:
        ;;   Navigate to the line in the diff, then:
        ;;   C-c C-c   Start a review comment
        ;;   (Write your comment, then C-c C-c to save)
        ;;
        ;; TIP: Use ' (apostrophe) to open Forge menu, then f f to fetch PRs.
        ;;      Then ' l p to list them. RET on a PR shows details.

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

