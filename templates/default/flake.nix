{
  description = "Decknix Local Configuration";

  inputs = {
    decknix.url = "github:ldeck/decknix";

    # --- ORG CONFIG (Optional) ---
    # Add org-specific configs as versioned flake inputs.
    # Each org repo exports darwinModules.default and homeModules.default.
    #
    # my-org-config.url = "github:my-org/decknix-config";

    # Follow decknix inputs to avoid duplicate instances
    nixpkgs.follows = "decknix/nixpkgs";
    nix-darwin.follows = "decknix/nix-darwin";
    nix-casks.follows = "decknix/nix-casks";
  };

  outputs = inputs@{ decknix, ... }:
    decknix.lib.mkSystem {
      inherit inputs;
      settings = import ./settings.nix;

      # Org config modules (uncomment if using an org config above)
      # darwinModules = [ inputs.my-org-config.darwinModules.default ];
      # homeModules   = [ inputs.my-org-config.homeModules.default ];
    };
}
