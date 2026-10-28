# modules/common/adoption.nix
#
# Declared in both the system and home-manager layers (like unfree.nix) so a
# darwin module and a home module can gate on the same component. mkSystem sets
# both from ~/.config/decknix/adoption.toml (lib/adoption.nix).
{ lib, config, ... }:

with lib;

let
  adoption = import ../../lib/adoption.nix { inherit lib; };
  cfg = config.decknix.adoption;

  toggle = description: default: defaultText: {
    enable = mkOption {
      type = types.bool;
      inherit default description;
      defaultText = literalExpression defaultText;
    };
  };
in
{
  options.decknix.adoption = {
    tier = mkOption {
      type = types.ints.between adoption.minSystemTier adoption.maxTier;
      default = adoption.maxTier;
      description = ''
        The adopted decknix tier: 1 base, 2 AI agents, 3 workstation,
        4 deckmacs. Components default on when the tier reaches theirs.
        Without an adoption.toml this is 4, which keeps installs made before
        adoption state on everything they had.
      '';
    };

    fromFile = mkOption {
      type = types.bool;
      default = false;
      internal = true;
      description = "Whether the adoption state came from an adoption.toml.";
    };

    components = mapAttrs (id: c:
      toggle c.description (cfg.tier >= c.tier)
        "config.decknix.adoption.tier >= ${toString c.tier}")
      adoption.components;

    org = mkOption {
      type = types.attrsOf (types.submodule {
        options.enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether this org overlay component is adopted.";
        };
      });
      default = { };
      example = literalExpression ''{ core.enable = true; services.enable = false; }'';
      description = ''
        Org overlay component toggles, keyed by the component id the overlay
        declares. Overlays gate each component on
        `config.decknix.adoption.org.<id>.enable or true`.
      '';
    };
  };
}
