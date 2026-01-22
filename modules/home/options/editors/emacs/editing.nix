{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.editing;
in
{
  options.programs.emacs.decknix.editing = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable editing enhancements (smartparens, editorconfig, crux).";
    };
  };

  config = mkIf cfg.enable {
    programs.emacs = {
      extraPackages = epkgs: with epkgs; [
        smartparens        # Structured editing for pairs
        editorconfig       # Respect .editorconfig files
        crux               # Useful interactive commands
        move-text          # Move lines/regions up/down
      ];

      extraConfig = ''
        ;;; Editing Enhancements

        ;; == Smartparens: Structured pair editing ==
        (require 'smartparens-config)
        (smartparens-global-mode 1)
        (show-smartparens-global-mode 1)

        ;; Smartparens keybindings for navigation
        (with-eval-after-load 'smartparens
          (define-key smartparens-mode-map (kbd "C-M-f") 'sp-forward-sexp)
          (define-key smartparens-mode-map (kbd "C-M-b") 'sp-backward-sexp)
          (define-key smartparens-mode-map (kbd "C-M-u") 'sp-backward-up-sexp)
          (define-key smartparens-mode-map (kbd "C-M-d") 'sp-down-sexp)
          (define-key smartparens-mode-map (kbd "C-M-k") 'sp-kill-sexp)
          (define-key smartparens-mode-map (kbd "C-M-w") 'sp-copy-sexp)
          (define-key smartparens-mode-map (kbd "C-M-t") 'sp-transpose-sexp)

          ;; Wrapping
          (define-key smartparens-mode-map (kbd "C-c (") 'sp-wrap-round)
          (define-key smartparens-mode-map (kbd "C-c [") 'sp-wrap-square)
          (define-key smartparens-mode-map (kbd "C-c {") 'sp-wrap-curly)

          ;; Unwrapping and slurping/barfing
          (define-key smartparens-mode-map (kbd "C-c )") 'sp-unwrap-sexp)
          (define-key smartparens-mode-map (kbd "C-<right>") 'sp-forward-slurp-sexp)
          (define-key smartparens-mode-map (kbd "C-<left>") 'sp-forward-barf-sexp)
          (define-key smartparens-mode-map (kbd "C-M-<right>") 'sp-backward-slurp-sexp)
          (define-key smartparens-mode-map (kbd "C-M-<left>") 'sp-backward-barf-sexp))

        ;; Enable strict mode in Lisp modes
        (add-hook 'emacs-lisp-mode-hook #'smartparens-strict-mode)
        (add-hook 'lisp-mode-hook #'smartparens-strict-mode)
        (add-hook 'scheme-mode-hook #'smartparens-strict-mode)

        ;; == Editorconfig: Respect project settings ==
        (editorconfig-mode 1)

        ;; == Crux: Useful commands ==
        ;; Smart beginning of line (toggle between indentation and column 0)
        (global-set-key (kbd "C-a") 'crux-move-beginning-of-line)

        ;; Smart kill line (kill to indentation if before non-whitespace)
        (global-set-key (kbd "C-S-k") 'crux-smart-kill-line)
        (global-set-key (kbd "C-k") 'crux-smart-kill-line)

        ;; Duplicate line or region
        (global-set-key (kbd "C-c d") 'crux-duplicate-current-line-or-region)
        (global-set-key (kbd "C-S-d") 'crux-duplicate-current-line-or-region)

        ;; Delete file and buffer
        (global-set-key (kbd "C-c D") 'crux-delete-file-and-buffer)

        ;; Rename file and buffer
        (global-set-key (kbd "C-c r") 'crux-rename-file-and-buffer)

        ;; Open recently edited files
        (global-set-key (kbd "C-c f") 'crux-recentf-find-file)

        ;; Cleanup buffer (indent, untabify, delete trailing whitespace)
        (global-set-key (kbd "C-c n") 'crux-cleanup-buffer-or-region)

        ;; Open line above/below
        (global-set-key (kbd "C-o") 'crux-smart-open-line)
        (global-set-key (kbd "C-S-o") 'crux-smart-open-line-above)

        ;; Join lines
        (global-set-key (kbd "C-^") 'crux-top-join-line)

        ;; Kill other buffers
        (global-set-key (kbd "C-c k") 'crux-kill-other-buffers)

        ;; == Move-text: Move lines/regions ==
        (global-set-key (kbd "M-<up>") 'move-text-up)
        (global-set-key (kbd "M-<down>") 'move-text-down)
        (global-set-key (kbd "M-p") 'move-text-up)
        (global-set-key (kbd "M-n") 'move-text-down)

        ;; == Additional editing conveniences ==
        ;; Delete selection when typing
        (delete-selection-mode 1)

        ;; Auto-insert closing pairs (backup if smartparens is disabled)
        ;; (electric-pair-mode 1)

        ;; Cleanup trailing whitespace on save
        (add-hook 'before-save-hook 'whitespace-cleanup)

        ;; Highlight trailing whitespace in programming modes
        (add-hook 'prog-mode-hook
                  (lambda () (setq show-trailing-whitespace t)))

        ;; Disable trailing whitespace in some modes
        (dolist (mode '(term-mode-hook
                        shell-mode-hook
                        eshell-mode-hook
                        vterm-mode-hook))
          (add-hook mode (lambda () (setq show-trailing-whitespace nil))))
      '';
    };
  };
}

