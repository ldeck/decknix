{ config, lib, pkgs, ... }:

{
  # 1. IMPORT THE LOGIC
  # We separate the complex logic (roles/templates) into options.nix
  imports = [
    ./options.nix
  ];

  # 2. SHARED TEAM CONFIGURATION
  # These settings apply to EVERYONE on the team, regardless of role.
  programs.home-manager.enable = true;

  # Standard Environment Variables
  home.sessionVariables = {
    EDITOR = "vim";
    # PAGER = "less"; 
  };

  # Common Tools (The "Base Layer")
  home.packages = with pkgs; [
    # Core Utilities
    coreutils
    curl
    wget
    tree
    jq
    ripgrep
    fd
    bat
    
    # Team Connectivity
    gh # GitHub CLI
  ];

  # Common Git Configuration 
  # (Users override specific email/name in their local config)
  programs.git = {
    enable = true;
    lfs.enable = true;
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
    };
    # Delta: A syntax-highlighting pager for git
    delta = {
      enable = true;
      options = {
        navigate = true;
        line-numbers = true;
        syntax-theme = "Dracula";
      };
    };
  };

  # Shell Configuration (e.g., Zsh)
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    
    shellAliases = {
      ll = "ls -l";
      # Helper alias to rebuild the system quickly
      update = "darwin-rebuild switch --flake ~/.config/nix-darwin#default --impure";
    };
  };
  
  # Starship Prompt (Uniform terminal look for the team)
  programs.starship = {
    enable = true;
    settings = {
      add_newline = false;
      character = {
        success_symbol = "[➜](bold green)";
        error_symbol = "[➜](bold red)";
      };
    };
  };
}
