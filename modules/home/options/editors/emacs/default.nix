{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix;
in
{
  options.programs.emacs.decknix = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Emacs with decknix defaults.";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.emacs;
      description = "The Emacs package to use.";
    };
  };

  config = mkIf cfg.enable {
    programs.emacs = {
      enable = true;
      package = cfg.package;

      extraConfig = ''
        ;; Basic Emacs configuration
        (setq inhibit-startup-message t)
        (setq initial-scratch-message nil)

        ;; Use visual bell instead of audible beep
        (setq visible-bell t)

        ;; Show line numbers
        (global-display-line-numbers-mode 1)
        
        ;; Disable line numbers for some modes
        (dolist (mode '(org-mode-hook
                       term-mode-hook
                       shell-mode-hook
                       eshell-mode-hook))
          (add-hook mode (lambda () (display-line-numbers-mode 0))))
        
        ;; Enable column number mode
        (column-number-mode 1)
        
        ;; Highlight current line
        (global-hl-line-mode 1)
        
        ;; Show matching parentheses
        (show-paren-mode 1)
        
        ;; Enable recent files
        (recentf-mode 1)
        
        ;; Save place in files
        (save-place-mode 1)
        
        ;; Better scrolling
        (setq scroll-conservatively 101)
        (setq scroll-margin 3)
        
        ;; Use spaces instead of tabs
        (setq-default indent-tabs-mode nil)
        (setq-default tab-width 2)
        
        ;; Auto-refresh buffers when files change on disk
        (global-auto-revert-mode 1)
        
        ;; Make backup files less intrusive
        (setq backup-directory-alist '(("." . "~/.emacs.d/backups")))
        (setq auto-save-file-name-transforms '((".*" "~/.emacs.d/auto-save-list/" t)))
        
        ;; Enable winner mode for window configuration undo/redo
        (winner-mode 1)
      '';
    };
  };
}

