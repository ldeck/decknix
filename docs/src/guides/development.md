# Framework Development

This guide covers how to develop and test changes to the decknix framework itself.

## Setup

Clone the framework:

```bash
git clone git@github.com:ldeck/decknix.git ~/tools/decknix
```

## Testing Changes

### Quick Test with `--override`

The fastest way to test framework changes is to point `decknix switch` at
your local checkout:

```bash
# Edit framework code
$EDITOR ~/tools/decknix/modules/home/options/editors/emacs/default.nix

# Build using local checkout
decknix switch --override decknix=~/tools/decknix
```

`--override INPUT=PATH` is repeatable — override the framework and an
org-config at the same time:

```bash
decknix switch \
  --override decknix=~/tools/decknix \
  --override nc-config=~/Code/my-org/decknix-config
```

Each `--override` becomes `--override-input <INPUT> path:<PATH>` on the
underlying `darwin-rebuild` call.

### Persist Overrides for Every Switch

If you always run with the same local checkouts, pin them once in
`~/.config/decknix/settings.toml` so plain `decknix switch` picks them up
automatically:

```toml
[switch.overrides]
decknix   = "~/tools/decknix"
nc-config = "~/Code/my-org/decknix-config"
```

CLI `--override` flags win per-input; pass `--no-overrides` to ignore the
config file for a single run (useful when reproducing an issue against the
published inputs). See [`decknix switch` → Persistent overrides](../cli/core-commands.md#persistent-overrides-via-settingstoml)
for the full precedence rules.

### Manual Override

If you'd rather bypass the CLI entirely:

```bash
cd ~/.config/decknix
sudo darwin-rebuild switch --flake .#default --impure \
  --override-input decknix path:~/tools/decknix
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

3. Test: `decknix switch --override decknix=~/tools/decknix`

## Verifying

```bash
# Check the generated Emacs config
find /nix/store -name "default.el" -path "*/emacs-packages-deps/*" 2>/dev/null | head -1 | xargs cat

# Check loaded modules
decknix switch --override decknix=~/tools/decknix 2>&1 | grep "\[Loader\]"

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

