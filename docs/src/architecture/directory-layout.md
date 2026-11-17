# Directory Layout

## User Configuration

```
~/.config/decknix/                   # Your flake + personal overrides
├── flake.nix                        # Main flake (imports decknix + org configs)
├── flake.lock                       # Pinned dependency versions
├── settings.nix                     # username, hostname, system, role
├── settings.toml                    # CLI settings: [switch.overrides], [repos], [session]
├── adoption.toml                    # Adopted tier and component toggles (optional)
├── extensions.json                  # Home-level CLI extensions (generated)
│
├── local/                           # Personal overrides (always loaded)
│   ├── home.nix                     # Packages, git identity, shell aliases
│   ├── system.nix                   # macOS system preferences
│   └── secrets.nix                  # Auth tokens, keys (gitignored)
│
├── <org-name>/                      # Per-org personal overrides
│   ├── identity.nix                 # Org identity, auto-wired to config.<org-name>.user.*
│   ├── home.nix                     # Org-specific personal tweaks
│   ├── system.nix
│   ├── secrets.nix
│   ├── secrets/                     # Raw 0600 secret files, referenced by path (not loaded)
│   └── home/                        # Nested home modules (recursively loaded)
│       └── extra.nix
│
└── secrets.nix                      # Root-level secrets (also supported)
```

The same directory also holds runtime state written by the CLI, the hub and the Emacs agent tooling (for example `agent-sessions.json`, `repo-sync.json`, `hub/`, `boards/`). Those files are not configuration and are not read by the loader.

### Key Points

- **`local/`** is for generic personal config: git identity, extra packages, shell aliases
- **`<org-name>/`** directories match flake input names; overrides specific to that org
- **`identity.nix`** in an org directory generates `config.<org-name>.user.{email,name,githubUser,gpgKey}` in both the system and home-manager layers
- **`secrets.nix`** files are gitignored and loaded into both the system and home-manager layers
- **`home/`, `system/` and `secrets/*.nix` subdirectories** are recursively scanned for additional `.nix` files
- All directories are auto-discovered; no registration needed

## Framework Source

```
decknix/
├── bin/
│   ├── bootstrap.sh                 # Fresh install script
│   └── cli-update                   # Refresh Cargo.lock and the CLI cargoHash
├── cli/                             # Rust CLI source
│   ├── src/main.rs                  # switch, update, pull-local-changes, help, extensions, wt
│   ├── src/session.rs               # decknix session (list, resume, new, tag, tags)
│   ├── src/session_archive.rs       # decknix session archive, restore, gc
│   ├── src/repo_sync.rs             # decknix repos (sync, fix-lock, list)
│   ├── src/wt_finished.rs           # decknix wt finished
│   └── reference.md                 # Generated CLI reference (checked by cargo test)
├── docs/                            # This documentation site
├── lib/
│   ├── default.nix                  # mkSystem + configLoader
│   ├── adoption.nix                 # adoption.toml parsing, tiers and components
│   └── find.nix                     # File discovery utilities
├── modules/
│   ├── cli/                         # decknix CLI nix-darwin module
│   │   └── default.nix              # CLI package, /etc/decknix/extensions.json
│   ├── common/
│   │   ├── adoption.nix             # decknix.adoption.* options (system and home)
│   │   └── unfree.nix               # Unfree package allowlist (system and home)
│   ├── darwin/                      # macOS system modules (all auto-imported)
│   │   ├── default.nix              # System packages, fonts, Nix settings, defaults
│   │   ├── aerospace.nix            # AeroSpace tiling WM (system-level)
│   │   ├── emacs.nix                # Emacs daemon service
│   │   ├── hub.nix                  # decknix-hub work-item aggregator
│   │   ├── iap-proxy.nix            # Local IAP authenticating proxies
│   │   ├── manifest.nix             # Install manifest (system.build.decknixManifest)
│   │   ├── repo-sync.nix            # Periodic repos sync agent
│   │   ├── session-gc.nix           # Weekly agent session GC
│   │   └── linux-builder/           # On-demand Linux builder VM
│   └── home/                        # Home-manager modules
│       ├── default.nix              # Imports + default packages
│       ├── options.nix              # Core options (role, username, hostname, defaultEditor)
│       └── options/                 # All auto-imported
│           ├── ai/                  # antigravity, claude, codex, gemini, goose, gortex, opencode, pi, qwen
│           ├── apps/                # Ungoogled Chromium
│           ├── cli/                 # agent-sync, auggie, board, extensions, nix-github-auth, repo-jdk
│           ├── editors/             # emacs/ (17 modules), vim/, profiles.nix
│           ├── shell/               # direnv, starship
│           └── wm/                  # aerospace/, hammerspoon/, omniwm/, spaces.nix
├── pkgs/                            # Custom Nix packages (CLI, hub, broker, ACP bridges, ...)
├── templates/                       # Flake templates for `nix flake init`
├── tests/                           # Eval tests (adoption.nix), closure-unchanged.sh, fixtures/
└── flake.nix                        # Framework flake
```

