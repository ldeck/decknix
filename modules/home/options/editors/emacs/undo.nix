{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.undo;
in
{
  options.programs.emacs.decknix.undo = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable improved undo/redo with undo-fu and vundo.";
    };
  };

  config = mkIf cfg.enable {
    programs.emacs = {
      extraPackages = epkgs: with epkgs; [
        undo-fu          # Linear undo/redo
        undo-fu-session  # Persist undo history across sessions
        vundo            # Visual undo tree
      ];

      extraConfig = ''
        ;;; Undo Configuration

        ;; == Undo-fu: Simple linear undo/redo ==
        ;; Replace default undo with undo-fu
        (global-set-key [remap undo] 'undo-fu-only-undo)
        (global-set-key (kbd "C-/") 'undo-fu-only-undo)
        (global-set-key (kbd "C-?") 'undo-fu-only-redo)
        (global-set-key (kbd "C-S-/") 'undo-fu-only-redo)
        (global-set-key (kbd "C-M-/") 'undo-fu-only-redo)

        ;; For macOS
        (global-set-key (kbd "s-z") 'undo-fu-only-undo)
        (global-set-key (kbd "s-Z") 'undo-fu-only-redo)

        ;; == Undo-fu-session: Persist undo across sessions ==
        (undo-fu-session-global-mode 1)
        (setq undo-fu-session-incompatible-files
              '("/COMMIT_EDITMSG\\'" "/git-rebase-todo\\'"))
        (setq undo-fu-session-directory
              (expand-file-name "undo-fu-session" user-emacs-directory))

        ;; == Vundo: Visual undo tree ==
        ;; Use C-x u to visualize undo history as a tree
        (global-set-key (kbd "C-x u") 'vundo)

        (with-eval-after-load 'vundo
          ;; Use Unicode characters for prettier tree
          (setq vundo-glyph-alist vundo-unicode-symbols)

          ;; Vundo window settings
          (setq vundo-compact-display nil
                vundo-window-max-height 6)

          ;; Keybindings within vundo buffer
          (define-key vundo-mode-map (kbd "l") #'vundo-forward)
          (define-key vundo-mode-map (kbd "h") #'vundo-backward)
          (define-key vundo-mode-map (kbd "j") #'vundo-next)
          (define-key vundo-mode-map (kbd "k") #'vundo-previous)
          (define-key vundo-mode-map (kbd "q") #'vundo-quit)
          (define-key vundo-mode-map (kbd "RET") #'vundo-confirm))

        ;; Increase undo limits for better history
        (setq undo-limit 400000           ; 400kb (default 160kb)
              undo-strong-limit 3000000   ; 3mb (default 240kb)
              undo-outer-limit 48000000)  ; 48mb (default 24mb)
      '';
    };
  };
}

