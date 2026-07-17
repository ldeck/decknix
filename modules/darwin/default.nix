{ config, pkgs, lib, ... }:
let
  username = config.system.primaryUser;
  # Avoid using config.users.users.${username}.home directly in nix.settings
  # because nix.linux-builder triggers evaluation of nix.settings, which would
  # then need users.users, creating infinite recursion. Use literal path instead.
  homeDir = "/Users/${username}";
in
{
  # set and forget
  system.stateVersion = 6;

  # 0. overlay custom decknix cli, enabled by default
  imports = [
    ../cli/default.nix
    ../common/unfree.nix
    ./aerospace.nix
    ./hub.nix
    ./iap-proxy.nix
  ];

  # The decknix custom packages (decknix-cli/hub, nix-open) are provided by
  # self.overlays.default, applied to the system nixpkgs in
  # flake.nix:darwinModules.default. That overlay builds them with a pinned
  # rustPlatform (nixpkgs-rust) to dodge the crates.io vendoring 403s — a
  # fallback overlay here would clobber it with the stable, 403-prone build,
  # so it is deliberately not redefined.

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

  # Allow the primary user to pass per-build settings (e.g. `system`) to the
  # nix-daemon. Without this, devenv and other per-shell tools emit:
  #   "ignoring the client-specified setting 'system', because it is a
  #    restricted setting and you are not a trusted user"
  nix.settings.trusted-users = [ "root" username ];

  # Include user-managed access tokens (e.g. GitHub API auth) so the
  # nix-daemon can make authenticated requests. The token file is
  # written by the nix-github-auth activation script and is NOT in
  # the Nix store. If the file doesn't exist, !include silently skips it.
  nix.extraOptions = ''
    !include ${homeDir}/.config/nix/access-tokens.conf
  '';

  # Authenticate Nix's fetchers to NurtureCloud's private GAR Maven repo the same
  # way Gradle does — so hermetic builds that vendor private deps (e.g. CONN-539's
  # nix container build) can pull them without per-artifact workarounds. On the
  # multi-user daemon, fixed-output fetches read the daemon's netrc-file (a client
  # `--option` is ignored), so it must be set here. Points at a user-writable file
  # the daemon reads; refresh it with a short-lived token before such a build:
  #   printf 'machine australia-southeast1-maven.pkg.dev\nlogin oauth2accesstoken\npassword %s\n' \
  #     "$(gcloud auth print-access-token)" > ~/.config/nix/netrc
  # Fetches are content-addressed, so this is only needed until each artifact is
  # in the store. A missing file is harmless (public fetches don't consult it).
  nix.settings.netrc-file = "${homeDir}/.config/nix/netrc";

  # Linux remote builder (lightweight NixOS VM via Apple Virtualization) so macOS
  # can build Linux derivations locally — e.g. `dockerTools` OCI images for the
  # hermetic Nix container builds (CONN-539). The guest is aarch64-linux (native
  # under Apple silicon), which is enough to build and run the image locally; the
  # linux/amd64 deploy image is built natively in CI. The VM runs as a
  # LaunchDaemon after a `decknix switch` (sudo darwin-rebuild).
  nix.linux-builder = {
    enable = true;
    maxJobs = 4;
    config.virtualisation = {
      cores = 6;
      darwin-builder.diskSize = 40 * 1024; # MB — room for the JVM dep closure
      darwin-builder.memorySize = 6 * 1024; # MB
    };
  };

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
