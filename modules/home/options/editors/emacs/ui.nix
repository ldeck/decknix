{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.ui;
in
{
  options.programs.emacs.decknix.ui = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable UI enhancements (which-key, helpful, nerd-icons).";
    };

    icons.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable nerd-icons for file icons in completion and dired.";
    };

    frame = {
      centerOnStartup = mkOption {
        type = types.bool;
        default = true;
        description = "Center the Emacs frame on screen at startup.";
      };

      width = mkOption {
        type = types.int;
        default = 120;
        description = "Default frame width in columns.";
      };

      height = mkOption {
        type = types.int;
        default = 50;
        description = "Default frame height in lines.";
      };

      maxWidthPercent = mkOption {
        type = types.int;
        default = 85;
        description = "Maximum frame width as percentage of screen width.";
      };

      maxHeightPercent = mkOption {
        type = types.int;
        default = 85;
        description = "Maximum frame height as percentage of screen height.";
      };
    };
  };

  config = mkIf cfg.enable {
    programs.emacs = {
      extraPackages = epkgs: with epkgs; [
        which-key         # Show available keybindings
        helpful           # Better *help* buffers
      ] ++ (optionals cfg.icons.enable [
        nerd-icons                # Icons using Nerd Fonts
        nerd-icons-completion     # Icons in minibuffer completion
        nerd-icons-dired          # Icons in dired
        nerd-icons-corfu          # Icons in corfu completions
      ]);

      extraConfig = ''
        ;;; UI Enhancements

        ;; == macOS keyboard settings ==
        (when (eq system-type 'darwin)
          ;; Ensure right-option is available for special characters (€, £, ©, etc.)
          (when (boundp 'ns-right-alternate-modifier)
            (setq ns-right-alternate-modifier 'none))
          (when (boundp 'mac-right-option-modifier)
            (setq mac-right-option-modifier 'none))

          ;; === emacs-mac port specific settings ===
          (when (boundp 'mac-option-modifier)
            (setq mac-option-modifier 'meta)         ; Option = Meta
            (setq mac-command-modifier 'super)       ; Command = Super
            (setq mac-control-modifier 'control)     ; Control = Control
            ;; Enable pixel-based scrolling for smoother experience
            (setq mac-mouse-wheel-smooth-scroll t))

          ;; === Standard NS Emacs settings (fallback) ===
          (when (and (boundp 'ns-command-modifier)
                     (not (boundp 'mac-option-modifier)))
            (setq ns-command-modifier 'super)
            (setq ns-option-modifier 'meta)
            (setq ns-control-modifier 'control)))

        ${optionalString cfg.frame.centerOnStartup ''
        ;; == Frame sizing and centering ==
        (defun decknix-center-frame ()
          "Center the frame on screen with appropriate size for the welcome screen."
          (let* ((screen-width (display-pixel-width))
                 (screen-height (display-pixel-height))
                 ;; Calculate max dimensions based on screen percentage
                 (max-width-px (/ (* screen-width ${toString cfg.frame.maxWidthPercent}) 100))
                 (max-height-px (/ (* screen-height ${toString cfg.frame.maxHeightPercent}) 100))
                 ;; Get character dimensions
                 (char-width (frame-char-width))
                 (char-height (frame-char-height))
                 ;; Calculate desired size in pixels
                 (desired-width-px (* ${toString cfg.frame.width} char-width))
                 (desired-height-px (* ${toString cfg.frame.height} char-height))
                 ;; Use smaller of desired or max
                 (frame-width-px (min desired-width-px max-width-px))
                 (frame-height-px (min desired-height-px max-height-px))
                 ;; Convert back to characters for set-frame-size
                 (frame-cols (/ frame-width-px char-width))
                 (frame-rows (/ frame-height-px char-height))
                 ;; Calculate centered position
                 (left (/ (- screen-width frame-width-px) 2))
                 (top (/ (- screen-height frame-height-px) 2)))
            ;; Apply size and position
            (set-frame-size (selected-frame) frame-cols frame-rows)
            (set-frame-position (selected-frame) left top)))

        ;; Center frame on startup
        (add-hook 'emacs-startup-hook #'decknix-center-frame)
        ''}
        ;; == Which-key: Show available keybindings ==
        (which-key-mode 1)
        (setq which-key-idle-delay 0.5
              which-key-idle-secondary-delay 0.1
              which-key-popup-type 'minibuffer
              which-key-max-display-columns nil
              which-key-min-display-lines 5
              which-key-separator " → "
              which-key-prefix-prefix "+"
              which-key-show-early-on-C-h t
              which-key-sort-order 'which-key-key-order-alpha)

        ;; Custom prefix descriptions
        (which-key-add-key-based-replacements
          "C-c p" "cape/project"
          "C-c !" "flycheck"
          "C-c Y" "yasnippet"
          "C-x p" "project"
          "C-x r" "register/bookmark"
          "M-g" "goto"
          "M-s" "search")

        ;; == Helpful: Better help buffers ==
        ;; Replace standard help commands with helpful versions
        (global-set-key [remap describe-function] 'helpful-callable)
        (global-set-key [remap describe-variable] 'helpful-variable)
        (global-set-key [remap describe-key] 'helpful-key)
        (global-set-key [remap describe-command] 'helpful-command)
        (global-set-key [remap describe-symbol] 'helpful-symbol)

        ;; Additional helpful bindings
        (global-set-key (kbd "C-h F") 'helpful-function)  ; Actual functions only
        (global-set-key (kbd "C-h C") 'helpful-command)   ; Interactive commands
        (global-set-key (kbd "C-c C-d") 'helpful-at-point)

        ;; Make helpful buffers pop up in a side window
        (setq helpful-switch-buffer-function
              (lambda (buf) (pop-to-buffer buf '(display-buffer-in-side-window))))
      ''
      + optionalString cfg.icons.enable ''

        ;; == Nerd Icons: Icons using Nerd Fonts ==
        ;; Note: Requires a Nerd Font to be installed (e.g., JetBrains Mono Nerd Font)

        ;; Enable icons in minibuffer completion (Vertico/Marginalia)
        (add-hook 'marginalia-mode-hook #'nerd-icons-completion-marginalia-setup)
        (nerd-icons-completion-mode 1)

        ;; Enable icons in dired
        (add-hook 'dired-mode-hook #'nerd-icons-dired-mode)

        ;; Enable icons in corfu completion popup
        (with-eval-after-load 'corfu
          (add-to-list 'corfu-margin-formatters #'nerd-icons-corfu-formatter))
      '';
    };
  };
}

