{ config, lib, pkgs, ... }:

let
  # 1. Define the recursive loading function
  loadAll = dir:
    let
      # Get a list of all files recursively (returns paths)
      files = lib.filesystem.listFilesRecursive dir;

      # Filter for files ending in .nix
      nixFiles = lib.filter
        (file: lib.hasSuffix ".nix" (toString file))
        files;
    in
      nixFiles;
in
{
  imports = [
    ./options.nix
    ../common/unfree.nix
  ] ++ (loadAll ./options);

  # 1. BOILERPLATE
  # Even 'enable' flags should be defaults, in case a user wants to
  # temporarily disable something locally for debugging.
  programs.home-manager.enable = lib.mkDefault true;

  # 2. SESSION VARIABLES
  # By using mkDefault, if the user sets EDITOR in their local config,
  # their value takes precedence.
  home.sessionVariables = {
    EDITOR = lib.mkDefault "vim";
    # PAGER = lib.mkDefault "less";
  };

  # 3. PACKAGES (Lists are special!)
  # Lists in Nix modules MERGE by default.
  # If you add [ curl ] here and the user adds [ wget ], they get BOTH.
  # You generally don't need mkDefault for packages unless you want the
  # user to be able to completely wipe this list.
  home.packages = with pkgs; [
    coreutils
    curl
    wget
    tree
    jq
    ripgrep
    gh
  ];

  # 4. GIT and diffing CONFIGURATION
  programs.delta = {
    enable = true;
    enableGitIntegration = true; # Needed to auto-configure git to use delta
    options = {
      # Note: You can't use mkDefault on a whole attribute set if you want
      #       to merge it. Apply it to the values.
      navigate = lib.mkDefault true;
      line-numbers = lib.mkDefault true;
      syntax-theme = lib.mkDefault "Dracula";
    };
  };

  programs.git = {
    enable = lib.mkDefault true;
    lfs.enable = lib.mkDefault true;

    settings = {
      # Use mkDefault on the specific leaves you want overridable
      init.defaultBranch = lib.mkDefault "main";
      pull.rebase = lib.mkDefault true;
      push.autoSetupRemote = lib.mkDefault true;
    };
  };

  # 5. SHELL CONFIGURATION
  programs.zsh = {
    enable = lib.mkDefault true;
    enableCompletion = lib.mkDefault true;
    autosuggestion.enable = lib.mkDefault true;
    syntaxHighlighting.enable = lib.mkDefault true;

    # Aliases merge, so no conflict here usually.
    shellAliases = {
      ll = lib.mkDefault "ls -l";
      reload = "unset __HM_SESS_VARS_SOURCED && exec zsh";
      update = lib.mkDefault "darwin-rebuild switch --flake ~/.config/nix-darwin#default --impure";
    };

    # Set terminal tab/window title (macOS zsh doesn't do this by default)
    # This makes terminal windows searchable in AeroSpace window picker
    # Using lib.mkOrder 1000 (default order) for general configuration
    initContent = lib.mkOrder 1000 ''
      # Set terminal title before each prompt (precmd hook)
      # Format matches bash: "📁 user@host: ~/path" or "📁 ~/path"
      function set_terminal_title() {
        local icon="📁"
        local path
        # Use ~ for home directory, otherwise show full path
        if [[ "$PWD" == "$HOME"* ]]; then
          path="~''${PWD#$HOME}"
        else
          path="$PWD"
        fi
        # Format: "📁 ~/path — zsh" (shows icon and full path like bash)
        echo -ne "\033]0;$icon $path — zsh\007"
      }
      precmd_functions+=(set_terminal_title)

      # Set terminal title when running a command (preexec hook)
      function set_terminal_title_preexec() {
        local icon="⚙️"
        local path
        if [[ "$PWD" == "$HOME"* ]]; then
          path="~''${PWD#$HOME}"
        else
          path="$PWD"
        fi
        # Extract first word of command for cleaner display
        local cmd="''${1%% *}"
        # Format: "⚙️ command — ~/path" (shows running command with icon)
        echo -ne "\033]0;$icon $cmd — $path\007"
      }
      preexec_functions+=(set_terminal_title_preexec)
    '';
  };

  programs.starship = {
    enable = lib.mkDefault true;
    settings = {
      add_newline = lib.mkDefault false;
      # To allow overriding deeper keys easily:
      character = {
        success_symbol = lib.mkDefault "[➜](bold green)";
        error_symbol = lib.mkDefault "[➜](bold red)";
      };
    };
  };

  programs.vim = {
    enable = lib.mkDefault true;

    extraConfig = ''
      set exrc   " Look for .exrc or .nvimrc in current directory
      set number " show line numbers
      set secure " Disallow shell commands in local files (security)
    '';
  };
}
