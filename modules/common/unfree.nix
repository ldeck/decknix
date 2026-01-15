# modules/common/unfree.nix
{ lib, config, ... }:
{
  # 1. Define the Option
  options.decknix.allowedUnfree = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = "List of unfree package names to allow.";
  };

  # 2. Apply the Logic
  config = {
    nixpkgs.config.allowUnfreePredicate = pkg:
      builtins.elem (lib.getName pkg) config.decknix.allowedUnfree;
  };
}
