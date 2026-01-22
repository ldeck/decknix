{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.completion;
in
{
  options.programs.emacs.decknix.completion = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable modern completion stack (Vertico, Consult, Corfu, etc.).";
    };
  };

  config = mkIf cfg.enable {
    programs.emacs = {
      extraPackages = epkgs: with epkgs; [
        # Minibuffer completion
        vertico           # Vertical completion UI
        marginalia        # Rich annotations in minibuffer
        consult           # Enhanced commands (search, navigation, etc.)
        orderless         # Flexible completion matching
        embark            # Context actions on any target
        embark-consult    # Embark integration with Consult

        # In-buffer completion
        corfu             # Completion popup (lighter than company)
        cape              # Completion-at-point extensions

        # Editing enhancements
        wgrep             # Editable grep buffers (works great with consult-ripgrep)
      ];

      extraConfig = ''
        ;;; Completion Stack Configuration

        ;; == Vertico: Vertical completion UI ==
        (vertico-mode 1)
        (setq vertico-cycle t
              vertico-count 15
              vertico-resize nil)

        ;; == Marginalia: Rich annotations ==
        (marginalia-mode 1)

        ;; == Orderless: Flexible matching ==
        (setq completion-styles '(orderless basic)
              completion-category-defaults nil
              completion-category-overrides '((file (styles basic partial-completion))))

        ;; == Savehist: Persist minibuffer history (essential for Vertico) ==
        (savehist-mode 1)
        (setq savehist-additional-variables '(search-ring regexp-search-ring)
              savehist-autosave-interval 60)

        ;; == Consult: Enhanced commands ==
        ;; Remap standard commands to Consult versions
        (global-set-key [remap switch-to-buffer] 'consult-buffer)
        (global-set-key [remap switch-to-buffer-other-window] 'consult-buffer-other-window)
        (global-set-key [remap switch-to-buffer-other-frame] 'consult-buffer-other-frame)
        (global-set-key [remap goto-line] 'consult-goto-line)
        (global-set-key [remap yank-pop] 'consult-yank-pop)
        (global-set-key [remap bookmark-jump] 'consult-bookmark)
        (global-set-key [remap project-find-regexp] 'consult-ripgrep)
        (global-set-key [remap imenu] 'consult-imenu)
        (global-set-key [remap repeat-complex-command] 'consult-complex-command)

        ;; Isearch replacement with consult-line
        (global-set-key (kbd "C-s") 'consult-line)
        (global-set-key (kbd "C-r") 'consult-line)

        ;; Additional Consult bindings
        (global-set-key (kbd "C-x r b") 'consult-bookmark)
        (global-set-key (kbd "M-g g") 'consult-goto-line)
        (global-set-key (kbd "M-g M-g") 'consult-goto-line)
        (global-set-key (kbd "M-g o") 'consult-outline)
        (global-set-key (kbd "M-g m") 'consult-mark)
        (global-set-key (kbd "M-g k") 'consult-global-mark)
        (global-set-key (kbd "M-g i") 'consult-imenu)
        (global-set-key (kbd "M-g I") 'consult-imenu-multi)
        (global-set-key (kbd "M-s f") 'consult-find)
        (global-set-key (kbd "M-s r") 'consult-ripgrep)
        (global-set-key (kbd "M-s g") 'consult-grep)
        (global-set-key (kbd "M-s G") 'consult-git-grep)
        (global-set-key (kbd "M-s l") 'consult-line)
        (global-set-key (kbd "M-s L") 'consult-line-multi)

        ;; Consult preview settings
        (setq consult-preview-key "M-.")

        ;; Use ripgrep for project search
        (setq consult-ripgrep-args
              "rg --null --line-buffered --color=never --max-columns=1000 --path-separator / --smart-case --no-heading --with-filename --line-number --search-zip")

        ;; == Embark: Context actions ==
        (global-set-key (kbd "C-.") 'embark-act)
        (global-set-key (kbd "C-;") 'embark-dwim)
        (global-set-key (kbd "C-h B") 'embark-bindings)

        ;; Use Embark to show keybindings in a completing-read buffer
        (setq prefix-help-command #'embark-prefix-help-command)

        ;; == Corfu: In-buffer completion ==
        (global-corfu-mode 1)
        (setq corfu-auto t
              corfu-auto-delay 0.2
              corfu-auto-prefix 2
              corfu-cycle t
              corfu-preselect 'prompt
              corfu-quit-no-match 'separator
              corfu-quit-at-boundary 'separator)

        ;; Corfu in terminal
        (unless (display-graphic-p)
          (corfu-terminal-mode 1))

        ;; Corfu history
        (corfu-history-mode 1)
        (add-to-list 'savehist-additional-variables 'corfu-history)

        ;; == Cape: Additional completion sources ==
        (add-to-list 'completion-at-point-functions #'cape-file)
        (add-to-list 'completion-at-point-functions #'cape-dabbrev)

        ;; Bind cape-prefix for manual capf selection
        (global-set-key (kbd "C-c p p") 'completion-at-point)
        (global-set-key (kbd "C-c p f") 'cape-file)
        (global-set-key (kbd "C-c p d") 'cape-dabbrev)
        (global-set-key (kbd "C-c p w") 'cape-dict)
        (global-set-key (kbd "C-c p l") 'cape-line)

        ;; == Wgrep: Editable grep buffers ==
        ;; Use C-c C-p in grep buffers to make them editable
        (setq wgrep-auto-save-buffer t
              wgrep-change-readonly-file t)
      '';
    };
  };
}

