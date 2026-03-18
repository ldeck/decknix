# Framework Development

This guide covers how to develop and test changes to the decknix framework itself.

## Setup

Clone the framework:

```bash
git clone git@github.com:ldeck/decknix.git ~/tools/decknix
```

## Testing Changes

### Quick Test with --dev

The fastest way to test framework changes:

```bash
# Edit framework code
$EDITOR ~/tools/decknix/modules/home/options/editors/emacs/default.nix

# Build using local checkout
decknix switch --dev
```

This passes `--override-input decknix path:~/tools/decknix` to darwin-rebuild.

### Manual Override

```bash
cd ~/.config/decknix
sudo darwin-rebuild switch --flake .#default --impure \
  --override-input decknix path:~/tools/decknix
```

### Using DECKNIX_DEV

Set the environment variable to avoid `--dev-path` every time:

```bash
export DECKNIX_DEV=~/tools/decknix
decknix switch --dev
```

## Project Structure

```
decknix/
├── cli/src/main.rs          # Rust CLI binary
├── lib/default.nix          # mkSystem + configLoader
├── modules/
│   ├── cli/                 # CLI nix-darwin module
│   ├── darwin/              # System modules
│   └── home/                # Home-manager modules
│       └── options/
│           ├── cli/         # auggie, board, extensions
│           ├── editors/     # emacs/, vim/
│           └── wm/          # aerospace/, hammerspoon/
├── pkgs/                    # Custom packages
└── flake.nix                # Framework flake
```

## Adding a New Module

1. Create the module file in the appropriate directory:

```nix
# modules/home/options/my-tool.nix
{ config, lib, pkgs, ... }:
let cfg = config.decknix.myTool;
in {
  options.decknix.myTool.enable = lib.mkEnableOption "My Tool";

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.my-tool ];
  };
}
```

2. The module is auto-imported — all `.nix` files in `modules/home/options/` are loaded.

3. Test: `decknix switch --dev`

## Verifying

```bash
# Check the generated Emacs config
find /nix/store -name "default.el" -path "*/emacs-packages-deps/*" 2>/dev/null | head -1 | xargs cat

# Check loaded modules
decknix switch --dev 2>&1 | grep "\[Loader\]"

# Evaluate an option
nix repl
:lf .
darwinConfigurations.default.config.programs.emacs.decknix.languages.kotlin.enable
```

## Troubleshooting

### Emacs Daemon Issues

```bash
# Check if daemon is running
launchctl list | grep emacs

# Restart daemon
launchctl stop org.nix-community.home.emacs
launchctl start org.nix-community.home.emacs

# View logs
log show --predicate 'process == "emacs"' --last 1h
```

### Keybindings Not Working

1. Did you run `decknix switch`?
2. Check for conflicting configs: `~/.emacs`, `~/.emacs.d/init.el`
3. Test in Emacs: `M-x describe-key RET <key>`

