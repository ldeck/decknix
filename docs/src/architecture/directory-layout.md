# Directory Layout

## User Configuration

```
~/.config/decknix/                   # Your flake + personal overrides
├── flake.nix                        # Main flake (imports decknix + org configs)
├── flake.lock                       # Pinned dependency versions
├── settings.nix                     # username, hostname, system, role
│
├── local/                           # Personal overrides (always loaded)
│   ├── home.nix                     # Packages, git identity, shell aliases
│   ├── system.nix                   # macOS system preferences
│   └── secrets.nix                  # Auth tokens, keys (gitignored)
│
├── <org-name>/                      # Per-org personal overrides
│   ├── home.nix                     # Org-specific personal tweaks
│   ├── system.nix
│   ├── secrets.nix
│   └── home/                        # Nested home modules (recursively loaded)
│       └── extra.nix
│
└── secrets.nix                      # Root-level secrets (also supported)
```

### Key Points

- **`local/`** is for generic personal config — git identity, extra packages, shell aliases
- **`<org-name>/`** directories match flake input names — overrides specific to that org
- **`secrets.nix`** files are gitignored and loaded alongside `home.nix`
- **`home/` subdirectories** are recursively scanned for additional `.nix` files
- All directories are auto-discovered — no registration needed

## Framework Source

```
decknix/
├── bin/                             # Bootstrap scripts
│   └── bootstrap.sh                 # Fresh install script
├── cli/                             # Rust CLI source
│   └── src/main.rs                  # switch, update, help, extensions
├── docs/                            # This documentation site
├── lib/
│   ├── default.nix                  # mkSystem + configLoader
│   └── find.nix                     # File discovery utilities
├── modules/
│   ├── cli/                         # decknix CLI nix-darwin module
│   │   └── default.nix              # Subtask system, extensions.json
│   ├── common/
│   │   └── unfree.nix               # Unfree package allowlist
│   ├── darwin/                      # macOS system modules
│   │   ├── default.nix              # System packages, fonts, defaults
│   │   ├── aerospace.nix            # AeroSpace tiling WM (system-level)
│   │   └── emacs.nix                # Emacs daemon service
│   └── home/                        # Home-manager modules
│       ├── default.nix              # Imports + default packages
│       ├── options.nix              # Role templates, core options
│       └── options/
│           ├── cli/                  # auggie, board, extensions, nix-github-auth
│           ├── editors/              # emacs/ (13 modules), vim/
│           └── wm/                   # aerospace/, hammerspoon/, spaces.nix
├── pkgs/                            # Custom Nix packages
├── templates/                       # Flake templates for `nix flake init`
└── flake.nix                        # Framework flake
```

