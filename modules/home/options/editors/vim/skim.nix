{ config, lib, pkgs, ... }:

with lib;

let
  # Simplified namespace
  cfg = config.programs.vim.decknix.skim;

  # Helper to convert Nix bools to Vim 1/0
  toVimBool = val: if val then "1" else "0";
in
{
  # 1. Option Definitions
  options.programs.vim.decknix.skim = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable vim-better-whitespace integration.";
    };
  };

  config = mkIf cfg.enable {
    programs.vim = {
      plugins = with pkgs.vimPlugins; [ skim ];
    };
  };
}
