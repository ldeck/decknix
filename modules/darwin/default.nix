{ pkgs, lib, ... }: {
  # set and forget
  system.stateVersion = 6;

  # 1. SYSTEM DEFAULTS
  # Using mkDefault allows a user to say "I hate autohiding" in their local config
  # and set it to false without a conflict error.
  system.defaults = {
    dock = {
      autohide = lib.mkDefault true;
      show-recents = lib.mkDefault false;
    };

    NSGlobalDomain = {
      AppleShowAllExtensions = lib.mkDefault true;
      "com.apple.swipescrolldirection" = lib.mkDefault false; # Natural scrolling off
    };

    finder = {
      AppleShowAllFiles = lib.mkDefault true;
      ShowPathbar = lib.mkDefault true;
    };
  };

  # 2. NIX SETTINGS
  #services.nix-daemon.enable = true; # deprecated

  # Lists (like this one) merge automatically. 
  # You generally do NOT need mkDefault here unless you want to allow 
  # the user to strictly *remove* your experimental features.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # 3. SYSTEM PACKAGES
  # These are installed in /run/current-system/sw (available to all users).
  # This list will MERGE with any packages the user defines locally.
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
  ];

  # 4. FONTS
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
  ];

  # 5. ACTIVATION SCRIPTS
  # (Your previous logic for creating ~/.local/decknix fits here)
  system.activationScripts.postActivation.text = ''
    mkdir -p ~/.local/decknix
    # ... logic to create empty placeholder if needed ...
  '';
}
