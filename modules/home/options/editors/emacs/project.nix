{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.project;
in
{
  options.programs.emacs.decknix.project = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable project.el enhancements with better switch actions.";
    };
  };

  config = mkIf cfg.enable {
    programs.emacs = {
      extraConfig = ''
        ;;; Project.el Enhancements

        ;; == Project switch commands ==
        ;; Customize the actions available when switching projects (C-x p p)
        ;; Adding Magit, Shell, and fixing default behavior

        ;; Ensure magit is autoloaded so 'm' works immediately
        (autoload 'magit-project-status "magit" "Run Magit in the current project" t)

        ;; Custom shell function for project
        (defun decknix-project-shell ()
          "Start a shell in the current project root."
          (interactive)
          (let ((default-directory (project-root (project-current t))))
            (shell (format "*shell: %s*" (project-name (project-current t))))))

        ;; Custom eshell function for project (improved)
        (defun decknix-project-eshell ()
          "Start eshell in the current project root."
          (interactive)
          (let ((default-directory (project-root (project-current t))))
            (eshell t)))

        ;; Configure project-switch-commands after project.el loads
        (with-eval-after-load 'project
          ;; Set the project switch commands with proper ordering
          ;; Each entry: (COMMAND LABEL KEY)
          (setq project-switch-commands
                '((project-find-file "Find File" ?f)
                  (project-find-regexp "Find Regexp" ?g)
                  (project-find-dir "Find Directory" ?d)
                  (project-vc-dir "VC-Dir" ?v)
                  (decknix-project-shell "Shell" ?s)
                  (decknix-project-eshell "Eshell" ?e)
                  (magit-project-status "Magit" ?m)
                  (project-any-command "Other" ?o))))

        ;; Fix for project-any-command cursor placement
        ;; The 'o' (Other) command should properly place cursor in minibuffer
        (defun decknix-project-any-command-advice (orig-fun &rest args)
          "Advice to ensure cursor is placed in minibuffer for project-any-command."
          (let ((enable-recursive-minibuffers t))
            (apply orig-fun args)))
        (advice-add 'project-any-command :around #'decknix-project-any-command-advice)

        ;; Keybinding for quick project shell
        (global-set-key (kbd "C-x p s") 'decknix-project-shell)
      '';
    };
  };
}

