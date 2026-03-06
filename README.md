# decknix

**decknix** – opinionated Nix framework for individuals or teams.

A batteries-included macOS configuration using [Nix Flakes](https://nixos.wiki/wiki/Flakes), [nix-darwin](https://github.com/LnL7/nix-darwin), and [home-manager](https://github.com/nix-community/home-manager). Provides sensible defaults with easy customization through organization-based configuration directories.

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [Getting Started](docs/getting-started.md) | Installation and initial setup |
| [Configuration Guide](docs/configuration.md) | How to customize your setup |
| [Emacs Guide](modules/home/options/editors/emacs/README.md) | Comprehensive Emacs documentation |
| [Secrets & Auth](docs/secrets.md) | GitHub tokens, GPG, SSH keys |

---

## 🚀 Quick Start

### Fresh Install (macOS)

Run this command to set up your Mac from scratch:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ldeck/decknix/main/bin/bootstrap)"
```

### Existing Nix Installation

```bash
# 1. Create your local config directory
mkdir -p ~/tmp/decknix-test && cd ~/tmp/decknix-test

# 2. Initialize from template
nix flake init -t github:ldeck/decknix

# 3. Edit settings
$EDITOR settings.nix  # Set username, hostname

# 4. Build and switch
decknix switch
```

---

## 🏗️ Architecture

```
~/.config/decknix/                    # Your local configurations
├── default/                         # Personal/default org
│   ├── home.nix                     # Home-manager config
│   └── system.nix                   # Darwin system config
├── <work-org>/                      # Work organization
│   ├── home.nix
│   ├── system.nix
│   └── secrets.nix                  # Auth tokens, keys (gitignored)
└── enabled-orgs.nix                 # Optional: explicit org list

~/tmp/decknix-test/                  # Your flake (or any location)
├── flake.nix                        # Imports decknix + your configs
├── flake.lock
└── settings.nix                     # username, hostname, system, role
```

### How It Works

1. **decknix** provides opinionated defaults via `darwinModules.default` and `homeModules.default`
2. **Org configs** are loaded via flake inputs (versioned repos) or filesystem auto-discovery
3. Each org's `system.nix` and `home.nix` modules are merged into your configuration
4. Your settings override decknix defaults (everything uses `lib.mkDefault`)

---

## 📦 What's Included

### System (nix-darwin)

| Feature | Description |
|---------|-------------|
| **AeroSpace** | Tiling window manager with fuzzy workspace picker |
| **Emacs Daemon** | Background Emacs service with `ec` command |
| **decknix CLI** | `decknix switch`, `decknix update`, extensible subtasks |

### Home Manager

| Category | Features |
|----------|----------|
| **Editors** | Emacs (full IDE), Vim enhancements |
| **Shell** | Zsh with Starship prompt, common aliases |
| **Git** | Global config, delta diff viewer |
| **Dev Tools** | ripgrep, jq, curl, tree, gh CLI |
| **Window Manager** | AeroSpace config with workspace definitions |

### Emacs

A complete, modern Emacs experience. See [Emacs Guide](modules/home/options/editors/emacs/README.md).

| Module | Features |
|--------|----------|
| **Core** | Modus theme, line numbers, better defaults |
| **Completion** | Vertico, Consult, Corfu, Embark |
| **Git** | Magit, Forge (GitHub PRs), code-review |
| **Languages** | 30+ language modes with syntax highlighting |
| **Org** | Presentations, modern styling, hierarchical navigation |
| **Development** | Flycheck, Yasnippet, EditorConfig |

---

## ⚙️ Configuration

### Organization-Based Config

Org configs can be versioned flake inputs (recommended for teams) or local filesystem directories. See the [Configuration Guide](docs/configuration.md) for the flake input approach.

Each subdirectory in `~/.config/decknix/` is an "organization" that provides local configuration:

```nix
# ~/.config/decknix/default/home.nix
{ pkgs, ... }: {
  programs.git.settings = {
    user.email = "you@example.com";
    user.name = "Your Name";
  };

  home.packages = with pkgs; [
    nodejs
    python3
  ];
}
```

```nix
# ~/.config/decknix/work/home.nix
{ pkgs, ... }: {
  # Work-specific tools
  home.packages = with pkgs; [
    awscli2
    terraform
  ];
}
```

### Enabling/Disabling Features

All decknix options use `lib.mkDefault` so you can override them:

```nix
# ~/.config/decknix/default/home.nix
{ ... }: {
  # Disable specific Emacs modules
  programs.emacs.decknix.welcome.enable = false;
  programs.emacs.decknix.languages.rust.enable = false;

  # Disable AeroSpace
  decknix.wm.aerospace.enable = false;
}
```

### Secrets Configuration

For sensitive data like GitHub tokens, create a gitignored `secrets.nix`:

```nix
# ~/.config/decknix/default/secrets.nix
{ config, lib, pkgs, ... }: {
  # Forge authentication for GitHub PRs
  home.file.".authinfo".text = ''
    machine api.github.com login YOUR_USERNAME^forge password ghp_YOUR_TOKEN
  '';

  # Or use GPG-encrypted version
  home.file.".authinfo.gpg".source = ./authinfo.gpg;
}
```

See [Secrets Guide](docs/secrets.md) for detailed setup instructions.

---

## 🔑 Key Commands

```bash
# Switch to new configuration
decknix switch

# Update flake inputs and switch
decknix update

# Open file in Emacs daemon
ec filename

# Emacs GUI frame
emacsclient -c

# Git status in Emacs
# C-x g (then @ c p to create PR with Forge)
```

---

## 🎨 Customization Examples

### Add Custom Packages

```nix
# ~/.config/decknix/default/home.nix
{ pkgs, ... }: {
  home.packages = with pkgs; [
    kubectl
    helm
    k9s
  ];
}
```

### Custom Emacs Config

```nix
{ ... }: {
  programs.emacs.extraPackages = epkgs: [ epkgs.treemacs ];
  programs.emacs.extraConfig = ''
    (treemacs)
    (setq treemacs-width 30)
  '';
}
```

### AeroSpace Workspaces

```nix
{ ... }: {
  decknix.wm.aerospace.workspaces = {
    "1" = { name = "Terminal"; };
    "2" = { name = "Browser"; };
    "3" = { name = "Code"; };
    "4" = { name = "Slack"; monitor = "secondary"; };
  };
}
```

---

## 📁 Project Structure

```
decknix/
├── bin/                    # Bootstrap scripts
├── cli/                    # Rust CLI source
├── docs/                   # Extended documentation
├── lib/                    # Nix library functions
│   └── default.nix         # configLoader implementation
├── modules/
│   ├── cli/                # decknix CLI module
│   ├── common/             # Shared config (unfree packages)
│   ├── darwin/             # macOS system modules
│   │   ├── aerospace.nix   # AeroSpace WM
│   │   └── emacs.nix       # Emacs daemon service
│   └── home/               # Home-manager modules
│       └── options/
│           ├── editors/    # Emacs, Vim configs
│           └── wm/         # Window manager configs
├── pkgs/                   # Custom packages
├── templates/              # Flake templates
└── flake.nix               # Main flake
```

---

## 🔗 Links

- [Nix Flakes Manual](https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-flake.html)
- [nix-darwin Manual](https://daiderd.com/nix-darwin/manual/)
- [Home Manager Manual](https://nix-community.github.io/home-manager/)
- [Emacs Manual](https://www.gnu.org/software/emacs/manual/)

---

## License

MIT
