# First Configuration

After installation, you'll have this directory structure:

```
~/.config/decknix/
├── flake.nix           # Main flake (imports decknix)
├── flake.lock          # Locked dependencies
├── settings.nix        # username, hostname, system, role
└── local/              # Your personal overrides
    ├── home.nix        # Home-manager config
    └── system.nix      # Darwin system config
```

## Set Up Git Identity

Edit `~/.config/decknix/local/home.nix`:

```nix
{ pkgs, ... }: {
  programs.git.settings = {
    user.email = "you@example.com";
    user.name = "Your Name";
  };
}
```

## Add Your Packages

```nix
{ pkgs, ... }: {
  home.packages = with pkgs; [
    nodejs
    python3
    go
  ];
}
```

## Choose Your Editor Profile

Decknix offers tiered editor profiles:

| Profile | Emacs Includes | Vim Includes |
|---------|---------------|--------------|
| `minimal` | Core, completion, editing, UI, undo | Base config |
| `standard` | + development, magit, treemacs, languages, welcome | + whitespace, skim |
| `full` *(default)* | + LSP, org-mode, HTTP client, agent-shell | — |
| `custom` | Your own config (disables framework) | Your own config |

Change profiles in your `home.nix`:

```nix
{ ... }: {
  decknix.editors.emacs.profile = "standard";
  decknix.editors.vim.profile = "minimal";
}
```

## Apply Your Changes

```bash
decknix switch
```

The first build takes a few minutes as it downloads packages. Subsequent builds are faster.

## Verify Installation

```bash
# Check Emacs daemon is running
launchctl list | grep emacs

# Open a file in Emacs
ec test.txt

# Check Magit
# In Emacs: C-x g (opens git status)
```

## Next Steps

- [Applying Changes](./applying-changes.md) — day-to-day workflow
- [Personal Overrides](../configuration/personal-overrides.md) — directory layout and advanced customisation
- [Secrets & Authentication](../configuration/secrets.md) — GitHub tokens, GPG, SSH keys

