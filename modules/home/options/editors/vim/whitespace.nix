# module config for hm vim's whitespace
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.vim.decknix.whitespace;

  toVimBool = val: if val then "1" else "0";
in
{
  # 1. Define the options you want to expose
  options.programs.vim.decknix.whitespace = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "vim-better-whitespace integration";
    };

    stripModifiedOnly = mkOption {
      type = types.bool;
      default = true; # Default to "Option A"
      description = "If true, only strips whitespace on lines you edited.";
    };

    confirm = mkOption {
      type = types.bool;
      default = false;
      description = "Ask for confirmation before stripping.";
    };
  };

  # 2. Define what happens when these options are enabled
  config = mkIf cfg.enable {
    programs.vim = {
      # Add the plugin automatically
      plugins = with pkgs.vimPlugins; [ vim-better-whitespace ];

      # Generate the config based on the option values
      extraConfig = ''
        let g:strip_whitespace_on_save = 1
        let g:strip_only_modified_lines = ${toVimBool cfg.stripModifiedOnly}
        let g:strip_whitespace_confirm = ${toVimBool cfg.confirm}
      '';
    };
  };
}
