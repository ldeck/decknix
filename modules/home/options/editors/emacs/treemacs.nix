{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.treemacs;
  uiCfg = config.programs.emacs.decknix.ui;
in
{
  options.programs.emacs.decknix.treemacs = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Treemacs for project file tree navigation.";
    };

    width = mkOption {
      type = types.int;
      default = 35;
      description = "Width of the treemacs window in characters.";
    };

    followMode = mkOption {
      type = types.bool;
      default = true;
      description = "Auto-follow the current file in the tree.";
    };

    fileWatch = mkOption {
      type = types.bool;
      default = true;
      description = "Watch for file system changes and auto-refresh.";
    };

    gitMode = mkOption {
      type = types.bool;
      default = true;
      description = "Show git status indicators in the tree.";
    };
  };

  config = mkIf cfg.enable {
    programs.emacs = {
      extraPackages = epkgs: with epkgs; [
        treemacs                    # Core file tree
        treemacs-magit              # Magit integration
      ] ++ optionals uiCfg.icons.enable [
        treemacs-all-the-icons      # Icons integration
      ];

      extraConfig = ''
        ;;; Treemacs - Project File Tree

        ;; == Core Treemacs Configuration ==
        (use-package treemacs
          :defer t
          :init
          ;; Keybindings for quick access
          (global-set-key (kbd "C-x t t") 'treemacs)              ; Toggle treemacs
          (global-set-key (kbd "C-x t 1") 'treemacs-delete-other-windows) ; Treemacs only
          (global-set-key (kbd "C-x t d") 'treemacs-select-directory)     ; Open directory
          (global-set-key (kbd "C-x t B") 'treemacs-bookmark)             ; Treemacs bookmark
          (global-set-key (kbd "C-x t f") 'treemacs-find-file)            ; Find current file
          (global-set-key (kbd "C-x t M-t") 'treemacs-find-tag)           ; Find tag

          :config
          ;; Window width
          (setq treemacs-width ${toString cfg.width})

          ;; Display settings
          (setq treemacs-show-hidden-files t
                treemacs-hide-gitignored-files-mode nil
                treemacs-silent-refresh t
                treemacs-silent-filewatch t
                treemacs-is-never-other-window nil
                treemacs-indentation 2
                treemacs-indentation-string " ")

          ;; Behavior settings
          (setq treemacs-collapse-dirs (if treemacs-python-executable 3 0)
                treemacs-deferred-git-apply-delay 0.5
                treemacs-directory-name-transformer #'identity
                treemacs-file-name-transformer #'identity
                treemacs-missing-project-action 'ask
                treemacs-move-forward-on-expand nil
                treemacs-no-png-images nil
                treemacs-no-delete-other-windows t
                treemacs-recenter-after-file-follow nil
                treemacs-recenter-after-tag-follow nil
                treemacs-show-cursor nil
                treemacs-sorting 'alphabetic-asc
                treemacs-select-when-already-in-treemacs 'move-back
                treemacs-space-between-root-nodes t
                treemacs-tag-follow-cleanup t
                treemacs-tag-follow-delay 1.5
                treemacs-user-mode-line-format nil
                treemacs-user-header-line-format nil
                treemacs-wide-toggle-width 70
                treemacs-workspace-switch-cleanup nil)

          ;; Persistence
          (setq treemacs-persist-file (expand-file-name "treemacs-persist" user-emacs-directory)
                treemacs-last-error-persist-file (expand-file-name "treemacs-persist-errors" user-emacs-directory))

          ${optionalString cfg.followMode ''
          ;; Follow mode - auto-select current file in tree
          (treemacs-follow-mode t)
          ''}

          ${optionalString cfg.fileWatch ''
          ;; File watch mode - auto-refresh on file system changes
          (treemacs-filewatch-mode t)
          ''}

          ${optionalString cfg.gitMode ''
          ;; Git mode - show git status in tree
          (treemacs-git-mode 'deferred)
          (treemacs-git-commit-diff-mode t)
          ''}

          ;; Fringe indicators for git status
          (treemacs-fringe-indicator-mode 'always)

          ;; Hide treemacs when selecting a file (tuck away behavior)
          (treemacs-project-follow-mode t))

        ;; == Magit Integration ==
        (use-package treemacs-magit
          :after (treemacs magit))

        ${optionalString uiCfg.icons.enable ''
        ;; == Icons Integration ==
        (use-package treemacs-all-the-icons
          :after treemacs
          :config
          (treemacs-load-theme "all-the-icons"))
        ''}

        ;; == Project.el Integration ==
        ;; Add treemacs to project-switch-commands
        (with-eval-after-load 'project
          (defun decknix-project-treemacs ()
            "Open treemacs for the current project."
            (interactive)
            (let ((project-root (project-root (project-current t))))
              (treemacs-add-and-display-current-project-exclusively)))

          ;; Add to project switch commands if not already present
          (unless (assq 'decknix-project-treemacs project-switch-commands)
            (add-to-list 'project-switch-commands
                         '(decknix-project-treemacs "Treemacs" ?t) t)))
      '';
    };
  };
}

