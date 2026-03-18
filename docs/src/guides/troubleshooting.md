# Troubleshooting

## Common Issues

### "command not found: decknix"

The CLI hasn't been installed yet. Run the full command manually:

```bash
sudo darwin-rebuild switch --flake ~/.config/decknix#default --impure
```

After the first successful switch, `decknix` will be in your PATH.

### Build Errors

Check the loader trace to see which files are being loaded:

```bash
decknix switch 2>&1 | grep "\[Loader\]"
```

Common causes:
- **Syntax error in a `.nix` file** — check the error message for the file path
- **Missing input** — run `nix flake update` to fetch all inputs
- **Stale lock file** — delete `flake.lock` and rebuild

### Config Not Taking Effect

1. Did you run `decknix switch`?
2. Check that your file is in the right location (the loader traces what it finds)
3. Another module may be setting the value with higher priority — try `lib.mkForce`

### Emacs Daemon Not Starting

```bash
# Check service status
launchctl list | grep emacs

# View logs
log show --predicate 'process == "emacs"' --last 1h

# Manually start
launchctl start org.nix-community.home.emacs
```

### Emacs Keybindings Not Working

1. Rebuild: `decknix switch`
2. Restart Emacs: `pkill emacs && launchctl start org.nix-community.home.emacs`
3. Check for conflicting configs:
   - `~/.emacs`
   - `~/.emacs.d/init.el`
   - `~/.config/emacs/init.el`
4. Test in Emacs: `M-x describe-key RET` then press the key

### Emacsclient Can't Connect

```bash
# Check if daemon is running
ps aux | grep "emacs.*daemon"

# Try starting manually
emacs --daemon

# Then connect
emacsclient -c
```

## Debugging

### Evaluate Without Building

```bash
nix repl
:lf .
darwinConfigurations.default.config.home-manager.users.YOU.home.packages
```

### Check Option Values

```bash
nix repl
:lf .
darwinConfigurations.default.config.programs.emacs.decknix.languages.kotlin.enable
```

### Check Generated Emacs Config

```bash
find /nix/store -name "default.el" -path "*/emacs-packages-deps/*" 2>/dev/null | head -1 | xargs cat
```

### Reset to Clean State

```bash
rm -rf ~/.config/decknix
# Re-run bootstrap or nix flake init -t github:ldeck/decknix
```

