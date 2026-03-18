# Vim

Decknix provides lightweight Vim enhancements on top of a sensible base config.

## Base Config (All Profiles)

- `set exrc` — load project-local `.vimrc`
- `set secure` — restrict commands in project `.vimrc`
- Line numbers enabled

## Whitespace Module

**Plugin:** `vim-better-whitespace`

Automatically strips trailing whitespace on save.

| Option | Default | Description |
|--------|---------|-------------|
| `programs.vim.decknix.whitespace.enable` | `true` (standard profile) | Enable whitespace cleanup |
| `programs.vim.decknix.whitespace.stripModifiedOnly` | `true` | Only strip modified lines |
| `programs.vim.decknix.whitespace.confirm` | `false` | Prompt before stripping |

## Skim Module

**Plugin:** `skim` (fuzzy finder)

Integrates skim into Vim for fast file and buffer searching.

| Option | Default | Description |
|--------|---------|-------------|
| `programs.vim.decknix.skim.enable` | `true` (standard profile) | Enable skim integration |

## Profiles

| Profile | Includes |
|---------|----------|
| `minimal` | Base config only |
| `standard` *(default)* | Base + whitespace + skim |
| `custom` | Disables framework Vim entirely |

```nix
{ ... }: {
  decknix.editors.vim.profile = "minimal";
}
```

## Adding Your Own Config

```nix
{ ... }: {
  programs.vim = {
    enable = true;
    plugins = [ pkgs.vimPlugins.vim-surround ];
    extraConfig = ''
      set relativenumber
    '';
  };
}
```

