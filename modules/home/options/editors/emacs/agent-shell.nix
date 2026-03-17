{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.agentShell;

  # == Package sources (not yet in nixpkgs) ==

  acp-el = pkgs.emacsPackages.trivialBuild {
    pname = "acp";
    version = "0-unstable-2026-03-17";
    src = pkgs.fetchFromGitHub {
      owner = "xenodium";
      repo = "acp.el";
      rev = "9737a9678a658a3289229d7d37459c84db1eef24";
      hash = "sha256-P3E3CQJde0pn0BHM3liZ/F7mCxoAXzKp8dF8/p2Wf9A=";
    };
    # acp.el has acp.el and acp-traffic.el at the top level
  };

  agent-shell-el = pkgs.emacsPackages.trivialBuild {
    pname = "agent-shell";
    version = "0-unstable-2026-03-17";
    src = pkgs.fetchFromGitHub {
      owner = "xenodium";
      repo = "agent-shell";
      rev = "4594c16ab9665bf68052a06fd08581168b69d8d5";
      hash = "sha256-BG+NQpNIzkiOwkfU0TSSp4AMwhNiaQoXmgmlnc4Vi1g=";
    };
    packageRequires = with pkgs.emacsPackages; [
      shell-maker
      acp-el
      markdown-mode
    ];
  };

  agent-shell-manager-el = pkgs.emacsPackages.trivialBuild {
    pname = "agent-shell-manager";
    version = "0-unstable-2026-03-17";
    src = pkgs.fetchFromGitHub {
      owner = "jethrokuan";
      repo = "agent-shell-manager";
      rev = "53b73f13ed1ac9d2de128465a8504a7265490ea7";
      hash = "sha256-JPB/OnOhYbM0LMirSYQhpB6hW8SAg0Ri6buU8tMP7rA=";
    };
    packageRequires = [ agent-shell-el ];
  };

  agent-shell-workspace-el = pkgs.emacsPackages.trivialBuild {
    pname = "agent-shell-workspace";
    version = "0-unstable-2026-03-17";
    src = pkgs.fetchFromGitHub {
      owner = "gveres";
      repo = "agent-shell-workspace";
      rev = "5d791c658b0692867c03a598ff4457599b5e20a5";
      hash = "sha256-durGK2f+Ovv5scbz4hv1k8nHeylgLNfHAR5tvQAifKI=";
    };
    packageRequires = [ agent-shell-el ];
  };

  agent-shell-attention-el = pkgs.emacsPackages.trivialBuild {
    pname = "agent-shell-attention";
    version = "0-unstable-2026-03-17";
    src = pkgs.fetchFromGitHub {
      owner = "ultronozm";
      repo = "agent-shell-attention.el";
      rev = "db89dc71e6e2ca5f0a6859ea9e9b183391614cea";
      hash = "sha256-bc5DjvGJnFBlsLtyYlN1hJQrcvK9khGaywtT37ACn+s=";
    };
    packageRequires = [ agent-shell-el ];
  };

in
{
  options.programs.emacs.decknix.agentShell = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable agent-shell.el ecosystem for auggie AI integration.";
    };

    manager.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable agent-shell-manager (tabulated session dashboard).";
    };

    workspace.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable agent-shell-workspace (dedicated tab-bar workspace).";
    };

    attention.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable agent-shell-attention (mode-line attention tracker).";
    };
  };

  config = mkIf cfg.enable {
    programs.emacs = {
      extraPackages = _epkgs:
        # Core: agent-shell + acp + shell-maker + markdown-mode
        [ agent-shell-el acp-el ]
        ++ (with pkgs.emacsPackages; [ shell-maker markdown-mode ])
        # Add-ons
        ++ (optional cfg.manager.enable agent-shell-manager-el)
        ++ (optional cfg.workspace.enable agent-shell-workspace-el)
        ++ (optional cfg.attention.enable agent-shell-attention-el);

      extraConfig = ''
        ;;; Agent Shell Configuration (auggie AI integration)

        ;; == Core: agent-shell with auggie defaults ==
        (require 'agent-shell)
        (require 'agent-shell-auggie)

        ;; Use auggie as the default agent
        (setq agent-shell-default-agent-config
              (agent-shell-auggie-make-agent-config))

        ;; Project-scoped sessions: each project.el root gets its own sessions
        ;; Strategy: prompt to resume or start new
        (setq agent-shell-session-strategy 'prompt)

        ;; Keybindings under C-c A prefix (agent-shell-command-map)
        (global-set-key (kbd "C-c A a") 'agent-shell)                      ; Start/switch to agent
        (global-set-key (kbd "C-c A n") 'agent-shell-new)                  ; Force new session
        (global-set-key (kbd "C-c A r") 'agent-shell-rename-buffer)        ; Rename session
        (global-set-key (kbd "C-c A k") 'agent-shell-interrupt)            ; Interrupt agent
      ''
      + optionalString cfg.manager.enable ''

        ;; == Manager: tabulated session dashboard ==
        (require 'agent-shell-manager)
        (global-set-key (kbd "C-c A m") 'agent-shell-manager-toggle)
        ;; Show manager at the bottom of the frame
        (setq agent-shell-manager-side 'bottom)
      ''
      + optionalString cfg.workspace.enable ''

        ;; == Workspace: dedicated tab-bar tab with sidebar ==
        (require 'agent-shell-workspace)
        (with-eval-after-load 'agent-shell
          (define-key agent-shell-command-map (kbd "w") 'agent-shell-workspace-toggle))
        (global-set-key (kbd "C-c A w") 'agent-shell-workspace-toggle)
      ''
      + optionalString cfg.attention.enable ''

        ;; == Attention: mode-line indicator + jump-to-pending ==
        (require 'agent-shell-attention)
        (agent-shell-attention-mode 1)

        ;; Show both pending and busy counts: AS:n/m
        (setq agent-shell-attention-render-function
              #'agent-shell-attention-render-active)

        ;; Jump to session needing attention
        (global-set-key (kbd "C-c A j") 'agent-shell-attention-jump)
        ;; Also bind globally for quick access
        (global-set-key (kbd "C-z a") 'agent-shell-attention-jump)
      ''
      + ''

        ;; Disable line numbers in agent-shell buffers
        (add-hook 'agent-shell-mode-hook
                  (lambda () (display-line-numbers-mode 0)))
      '';
    };
  };
}
