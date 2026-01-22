{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.development;
in
{
  options.programs.emacs.decknix.development = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable development tools (Flycheck, Yasnippet).";
    };

    flycheck.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Flycheck for on-the-fly syntax checking.";
    };

    yasnippet.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Yasnippet for snippet expansion.";
    };
  };

  config = mkIf cfg.enable {
    programs.emacs = {
      extraPackages = epkgs: with epkgs;
        (optionals cfg.flycheck.enable [
          flycheck
          consult-flycheck  # Consult integration for flycheck errors
        ])
        ++ (optionals cfg.yasnippet.enable [
          yasnippet
          yasnippet-snippets  # Collection of common snippets
        ]);

      extraConfig = ''
        ;;; Development Tools Configuration
      ''
      + optionalString cfg.flycheck.enable ''

        ;; == Flycheck: On-the-fly syntax checking ==
        (global-flycheck-mode 1)

        ;; Only check on save and mode-enable (not while typing)
        (setq flycheck-check-syntax-automatically '(mode-enabled save idle-buffer-switch))

        ;; Delay before checking (when idle checking is enabled)
        (setq flycheck-idle-change-delay 1.0)

        ;; Display errors in echo area
        (setq flycheck-display-errors-delay 0.5)

        ;; Flycheck keybindings
        (global-set-key (kbd "M-n") 'flycheck-next-error)
        (global-set-key (kbd "M-p") 'flycheck-previous-error)
        (global-set-key (kbd "C-c ! l") 'flycheck-list-errors)
        (global-set-key (kbd "C-c ! c") 'flycheck-buffer)
        (global-set-key (kbd "C-c ! n") 'flycheck-next-error)
        (global-set-key (kbd "C-c ! p") 'flycheck-previous-error)

        ;; Consult integration for flycheck
        (global-set-key (kbd "C-c ! a") 'consult-flycheck)

        ;; Use icons in fringe for errors (if available)
        (setq flycheck-indication-mode 'left-fringe)

        ;; Disable flycheck for some modes
        (setq flycheck-global-modes '(not org-mode text-mode))
      ''
      + optionalString cfg.yasnippet.enable ''

        ;; == Yasnippet: Snippet expansion ==
        (yas-global-mode 1)

        ;; Don't use TAB for yasnippet expansion (avoid conflicts with completion)
        ;; Use C-c y to expand instead
        (define-key yas-minor-mode-map (kbd "TAB") nil)
        (define-key yas-minor-mode-map (kbd "<tab>") nil)

        ;; Alternative expansion key
        (define-key yas-minor-mode-map (kbd "C-c y") 'yas-expand)

        ;; Keybindings for snippet management
        (global-set-key (kbd "C-c Y n") 'yas-new-snippet)
        (global-set-key (kbd "C-c Y v") 'yas-visit-snippet-file)
        (global-set-key (kbd "C-c Y i") 'yas-insert-snippet)

        ;; Disable yasnippet in terminal modes
        (add-hook 'term-mode-hook (lambda () (yas-minor-mode -1)))
        (add-hook 'vterm-mode-hook (lambda () (yas-minor-mode -1)))

        ;; Wrap around selected region
        (setq yas-wrap-around-region t)

        ;; Prompt using completing-read (works with Vertico)
        (setq yas-prompt-functions '(yas-completing-prompt))
      '';
    };
  };
}

