{ config, lib, pkgs, ... }:

with lib;

let
  # decknix namespace, matching `decknix.wm.aerospace'.  Upstream
  # home-manager gained a `programs.omniwm' module, but NOT in the
  # release-25.11 branch this flake pins (its `modules/programs/' has
  # `aerospace.nix' and no `omniwm.nix'), so the launchd agent and settings
  # file are declared here rather than delegated.  If a later home-manager
  # bump brings the module in, this can become a thin wrapper over it.
  cfg = config.decknix.wm.omniwm;

  tomlFormat = pkgs.formats.toml { };

  settingsFile =
    if cfg.settings == null then null
    else if isPath cfg.settings || isString cfg.settings then cfg.settings
    else tomlFormat.generate "omniwm-settings.toml" cfg.settings;

in {
  options.decknix.wm.omniwm = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable OmniWM, a tiling window manager for Apple Silicon macOS
        (decknix configuration).

        Niri-style orientation-aware scrolling containers plus
        Hyprland-style dwindle BSP layouts.  An alternative to
        `decknix.wm.aerospace'; running both at once is not useful, since
        each will fight the other for window placement.

        Requirements, neither of which this module can enforce at
        evaluation time beyond the platform check:
          - Apple Silicon.  The nixpkgs package declares
            `platforms = [ "aarch64-darwin" ]', so enabling it elsewhere
            fails the assertion below rather than erroring deep in the
            package set.
          - macOS 26 or later.
          - Accessibility permission, granted on first launch.

        To enable: decknix.wm.omniwm.enable = true;
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.unstable.omniwm;
      defaultText = literalExpression "pkgs.unstable.omniwm";
      description = ''
        The OmniWM package.  `pkgs.unstable.omniwm' is overlaid from
        nixpkgs-current: OmniWM is absent on both the pinned stable
        nixpkgs (nixos-25.11) and the older shared unstable pin.

        Puts both `OmniWM' and `omniwmctl' on PATH.
      '';
    };

    startAtLogin = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Manage a launchd agent that starts OmniWM at login and restarts it
        if it exits.

        Set false to launch it yourself (from the Applications folder or
        `OmniWM' on PATH).  Leaving launchd out of it is also the escape
        hatch if you want the GUI to own the process entirely.
      '';
    };

    settings = mkOption {
      type = types.nullOr (types.either types.path (tomlFormat.type));
      default = null;
      example = literalExpression ''
        {
          general.gaps = 8;
          layout.default = "dwindle";
        }
      '';
      description = ''
        Declarative `~/.config/omniwm/settings.toml', as either an attribute
        set (rendered to TOML) or a path to a TOML file.

        Null by default, and deliberately so: OmniWM preserves settings
        symlinks, so a settings file backed by a read-only Nix store path
        CANNOT be saved from the GUI.  Leaving this unset lets OmniWM own
        its own settings and keeps the GUI's preferences usable, which is
        the right default for a window manager people tune by eye.  Set it
        only once you want the config version-controlled, and accept that
        the GUI becomes read-only for it.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.system == "aarch64-darwin";
        message = ''
          decknix.wm.omniwm.enable is set, but OmniWM is Apple Silicon only
          (nixpkgs declares platforms = [ "aarch64-darwin" ]); this system is
          ${pkgs.stdenv.hostPlatform.system}.  Use decknix.wm.aerospace
          instead, or leave omniwm disabled on this host.
        '';
      }
    ];

    warnings = optional config.decknix.wm.aerospace.enable ''
      Both decknix.wm.omniwm and decknix.wm.aerospace are enabled.  Two
      tiling window managers will compete for window placement; enable one.
    '';

    home.packages = [ cfg.package ];

    xdg.configFile = mkIf (settingsFile != null) {
      "omniwm/settings.toml".source = settingsFile;
    };

    # `mkIf' guards the whole attribute rather than sitting inside the agent
    # value: at the definition position the module system always processes it,
    # whereas nested inside an attribute set it can survive as a literal
    # `{ _type = "if"; ... }' and reach launchd as a malformed agent.
    launchd.agents = mkIf cfg.startAtLogin {
      omniwm = {
        enable = true;
        config = {
          # The store `bin/OmniWM' symlinks into the app bundle's own
          # Contents/MacOS, so the process still resolves its bundle -- which
          # matters, because Accessibility permission is granted per bundle.
          ProgramArguments = [ "${cfg.package}/bin/OmniWM" ];
          RunAtLoad = true;
          KeepAlive = true;
          ProcessType = "Interactive";
          StandardOutPath = "${config.home.homeDirectory}/.local/state/omniwm/launchd.out.log";
          StandardErrorPath = "${config.home.homeDirectory}/.local/state/omniwm/launchd.err.log";
        };
      };
    };
  };
}
