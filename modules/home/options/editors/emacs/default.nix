{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix;
  isDarwin = pkgs.stdenv.isDarwin;
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
      # Use emacs-macport on Darwin for better macOS integration
      # (Stage Manager shortcuts, system shortcuts passthrough, etc.)
      default = if isDarwin then pkgs.emacs-macport else pkgs.emacs;
      defaultText = literalExpression "pkgs.emacs-macport (Darwin) or pkgs.emacs (Linux)";
      description = ''
        The Emacs package to use.

        On macOS, defaults to emacs-macport which provides:
        - Proper macOS system shortcut passthrough (Stage Manager, etc.)
        - Native macOS features (pixel scrolling, etc.)
        - Better integration with macOS input methods

        Set to pkgs.emacs for standard GNU Emacs if preferred.
      '';
    };
  };

  config = mkIf cfg.enable {
    programs.emacs = {
      enable = true;
      package = cfg.package;

      extraPackages = epkgs: with epkgs; [
        modus-themes           # High-contrast accessible themes
        exec-path-from-shell   # Inherit PATH from shell (critical for tools like rg, git, etc.)
      ];

      extraConfig = ''
        ;;; Decknix Core Emacs Configuration

        ;; == PATH from shell ==
        ;; Critical: Inherit PATH from shell so tools like rg, git, etc. are found
        ;; This is especially important for GUI Emacs and the Emacs daemon
        (use-package exec-path-from-shell
          :config
          (when (or (daemonp) (memq window-system '(mac ns x)))
            (exec-path-from-shell-initialize)))

        ;; == Startup ==
        (setq inhibit-startup-message t
              initial-scratch-message nil
              initial-major-mode 'fundamental-mode)

        ;; Disable all bells (audible and visual) - no beeps or flashes
        ;; Visual feedback is provided by UI elements instead
        (setq ring-bell-function 'ignore)

        ;; Don't blink the cursor
        (blink-cursor-mode -1)

        ;; == Theme ==
        ;; Load modus-vivendi (high-contrast dark theme)
        (load-theme 'modus-vivendi t)

        ;; Fix face attribute warnings (nil should be 'unspecified)
        (with-eval-after-load 'modus-themes
          (when (facep 'modus-themes-button)
            (set-face-attribute 'modus-themes-button nil
                                :background 'unspecified
                                :foreground 'unspecified)))
        (when (facep 'widget-inactive)
          (set-face-attribute 'widget-inactive nil
                              :background 'unspecified
                              :foreground 'unspecified))

        ;; == Line numbers ==
        (global-display-line-numbers-mode 1)

        ;; Disable line numbers in specific modes
        (dolist (mode '(org-mode-hook
                        term-mode-hook
                        vterm-mode-hook
                        shell-mode-hook
                        eshell-mode-hook
                        treemacs-mode-hook))
          (add-hook mode (lambda () (display-line-numbers-mode 0))))

        ;; == Mode line ==
        (line-number-mode 1)
        (column-number-mode 1)

        ;; == Visual feedback ==
        (global-hl-line-mode 1)
        (show-paren-mode 1)
        (setq show-paren-delay 0
              show-paren-style 'parenthesis)

        ;; == Recent files ==
        (recentf-mode 1)
        (setq recentf-max-menu-items 25
              recentf-max-saved-items 100
              recentf-exclude '("COMMIT_EDITMSG" "COMMIT_MSG" "\\.git"))

        ;; == Save place ==
        (save-place-mode 1)

        ;; == Scrolling ==
        (setq scroll-conservatively 101
              scroll-margin 3
              scroll-preserve-screen-position t)

        ;; == Indentation ==
        (setq-default indent-tabs-mode nil
                      tab-width 2)

        ;; == Auto-revert ==
        (global-auto-revert-mode 1)
        (setq global-auto-revert-non-file-buffers t)

        ;; == Backups and autosave ==
        (let ((backup-dir (expand-file-name "backups" user-emacs-directory))
              (autosave-dir (expand-file-name "auto-save-list" user-emacs-directory)))
          (unless (file-exists-p backup-dir) (make-directory backup-dir t))
          (unless (file-exists-p autosave-dir) (make-directory autosave-dir t))
          (setq backup-directory-alist `(("." . ,backup-dir))
                auto-save-file-name-transforms `((".*" ,autosave-dir t))))

        ;; Don't create lock files
        (setq create-lockfiles nil)

        ;; == Window management ==
        (winner-mode 1)

        ;; == Yes/No prompts ==
        (setq use-short-answers t)  ; 'y' or 'n' instead of 'yes' or 'no'

        ;; == Clipboard ==
        (setq select-enable-clipboard t
              select-enable-primary nil
              save-interprogram-paste-before-kill t
              mouse-yank-at-point t)

        ;; == Performance ==
        ;; Increase garbage collection threshold
        (setq gc-cons-threshold (* 100 1024 1024)  ; 100MB
              gc-cons-percentage 0.2)

        ;; Increase process output buffer (important for LSP)
        (setq read-process-output-max (* 1024 1024))  ; 1MB

        ;; == Misc ==
        (setq uniquify-buffer-name-style 'forward)  ; Better buffer naming
        (setq-default fill-column 80)               ; Default fill column
      '';
    };
  };
}

