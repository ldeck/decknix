{ config, pkgs, lib, ... }:
let
  username = config.system.primaryUser;
  homeDir = config.users.users.${username}.home;
in
{
  # set and forget
  system.stateVersion = 6;

  # 0. overlay custom decknix cli, enabled by default
  imports = [
    ../cli/default.nix
    ../common/unfree.nix
    ./aerospace.nix
  ];

  nixpkgs.overlays = [
    # Assuming we are inside the decknix repo, we can import the overlay directly
    # OR rely on the user's flake to pass it.
    # Safe fallback:
    (final: prev: {
      decknix-cli = prev.callPackage ../../pkgs/decknix-cli/default.nix { };
      nix-open = prev.callPackage ../../pkgs/nix-open/default.nix { };
    })
  ];

  programs.decknix-cli.enable = lib.mkDefault true;

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

  # Include user-managed access tokens (e.g. GitHub API auth) so the
  # nix-daemon can make authenticated requests. The token file is
  # written by the nix-github-auth activation script and is NOT in
  # the Nix store. If the file doesn't exist, !include silently skips it.
  nix.extraOptions = ''
    !include ${homeDir}/.config/nix/access-tokens.conf
  '';

  # 3. SYSTEM PACKAGES
  # These are installed in /run/current-system/sw (available to all users).
  # This list will MERGE with any packages the user defines locally.
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    skim
    nix-open
  ];

  # 4. FONTS
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
  ];

  # 5. ACTIVATION SCRIPTS
  system.activationScripts.postActivation.text = ''
    mkdir -p ~/.config/decknix
  '';
}
