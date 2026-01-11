{ pkgs, ... }: {
  # Common System Settings
  system.defaults.dock.autohide = true;
  system.defaults.NSGlobalDomain.AppleShowAllExtensions = true;
  
  # Nix Settings
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  services.nix-daemon.enable = true;

  # Common Packages
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
  ];
  
  # Font setup
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
  ];
}
