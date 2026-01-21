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
  };

  config = mkIf cfg.enable {
    programs.emacs = {
      extraPackages = epkgs: with epkgs; [
        magit
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
      '';
    };
  };
}

