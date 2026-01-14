{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.decknix;

  # Define your templates here as multi-line strings
  templates = {
    developer = ''
      { pkgs, ... }: {
        # -- DEVELOPER LOCAL CONFIG --
        programs.git = {
          settings = {
            user.email = "dev@example.com";
            user.name = "Your Name";
          };
        };

        home.packages = with pkgs; [
          ripgrep
          jq
          nodejs
        ];

        #home.sessionVariables = {
        #  EDITOR = "nano"; # override default 'vim'
        #};

        # This overrides the upstream Starship symbol
        #programs.starship.settings.character.success_symbol = "[⚡](bold yellow)";
      }
    '';

    designer = ''
      { pkgs, ... }: {
        # -- DESIGNER LOCAL CONFIG --
        home.packages = with pkgs; [
          figma-linux
          inkscape
        ];
      }
    '';
  };

in {
  options.decknix = {
    role = mkOption {
      type = types.enum [ "developer" "designer" "minimal" ];
      default = "minimal";
      description = "The role determining the template for the local config.";
    };
  };

  config = {
    # We use Home Manager's activation system
    # This runs AFTER the build, but BEFORE the generation is marked 'current'
    # home.activation.ensureLocalConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
    #   LOCAL_CONFIG="$HOME/.local/decknix/default/home.nix"

    #   if [ ! -f "$LOCAL_CONFIG" ]; then
    #     echo -e "\033[0;31m[Decknix] Local configuration missing at $LOCAL_CONFIG\033[0m"
    #     echo -e "\033[0;34m[Decknix] Generating template for role: ${cfg.role}...\033[0m"

    #     mkdir -p "$(dirname "$LOCAL_CONFIG")"

    #     # Inject the template content based on the role selected in flake.nix
    #     cat > "$LOCAL_CONFIG" <<EOF
    #   ${if cfg.role == "developer" then templates.developer
    #     else if cfg.role == "designer" then templates.designer
    #     else "{ ... }: { }"}
    #   EOF

    #     echo -e "\033[0;32m[Decknix] Template created successfully.\033[0m"
    #     echo -e "\033[1;33m[ACTION REQUIRED] Please edit $LOCAL_CONFIG to fill in your details.\033[0m"
    #     echo -e "\033[1;31mAborting activation to prevent applying incomplete config.\033[0m"

    #     # This aborts the switch!
    #     exit 1
    #   fi
    # '';
  };
}
