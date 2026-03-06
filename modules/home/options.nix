{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix;

  # Bootstrap templates for `decknix init` / bootstrap.sh
  # These are written to ~/.config/decknix/local/home.nix on first setup.
  # They are NOT used at evaluation time — only as starter files.
  templates = {
    developer = ''
      { pkgs, ... }: {
        # -- DEVELOPER LOCAL CONFIG --
        # Fill in your identity, then rebuild.
        programs.git.extraConfig = {
          user.email = "you@example.com";
          user.name  = "Your Name";
        };

        # Additional packages beyond the framework defaults
        home.packages = with pkgs; [
          nodejs
        ];
      }
    '';

    designer = ''
      { pkgs, ... }: {
        # -- DESIGNER LOCAL CONFIG --
        home.packages = with pkgs; [
          inkscape
        ];
      }
    '';

    minimal = ''
      { ... }: {
        # Minimal local config — add your overrides here.
      }
    '';
  };

in {
  options.decknix = {
    role = mkOption {
      type = types.enum [ "developer" "designer" "minimal" ];
      default = "minimal";
      description = ''
        The user's role. Determines:
        - Which template is generated during bootstrap
        - Which default packages are included
      '';
    };

    username = mkOption {
      type = types.str;
      default = "setup-required";
      description = "The macOS username. Must be set in settings.nix.";
    };

    hostname = mkOption {
      type = types.str;
      default = "setup-required";
      description = "The machine hostname. Must be set in settings.nix.";
    };

    # Expose templates so bootstrap/CLI can read them
    _internal.templates = mkOption {
      type = types.attrsOf types.str;
      default = templates;
      internal = true;
      readOnly = true;
      description = "Bootstrap templates keyed by role name.";
    };
  };

  config = {
    # Framework-level assertions — every user gets these automatically.
    # No need to duplicate in individual flake.nix files.
    assertions = [
      {
        assertion = cfg.username != "REPLACE_ME" && cfg.username != "setup-required";
        message = "Decknix: You must set 'username' in ~/.config/decknix/settings.nix (run: whoami)";
      }
      {
        assertion = cfg.hostname != "setup-required";
        message = "Decknix: You must set 'hostname' in ~/.config/decknix/settings.nix (run: hostname -s)";
      }
    ];
  };
}
