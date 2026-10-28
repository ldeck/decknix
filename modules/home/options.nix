{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix;
in {
  options.decknix = {
    role = mkOption {
      type = types.enum [ "developer" "designer" "minimal" ];
      default = "minimal";
      description = ''
        Informational only; nothing reads it. What a machine installs is
        decided by the adoption tier (`decknix.adoption.tier`, from
        ~/.config/decknix/adoption.toml). Kept so existing settings.nix files
        still evaluate. It is deliberately not mapped onto tiers: mkSystem
        passes "developer" when settings.nix omits it, so a mapping would
        silently change what existing installs build.
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

    defaultEditor = mkOption {
      type = types.str;
      default = "vim";
      description = ''
        The default EDITOR environment variable.
        Set this to decouple your preferred editor from any editor profile.
        Examples: "vim", "nvim", "emacs", "emacsclient -t"
      '';
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
