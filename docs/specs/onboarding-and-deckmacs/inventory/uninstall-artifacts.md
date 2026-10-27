# Inventory: what a full uninstall must handle

Read-only survey of the reference machine on 2026-10-27 (Determinate installer receipt 3.11.3, Nix 2.31.2, nix-darwin 25.11 active, no Homebrew). decknix has no uninstall code today (`grep -rni uninstall` finds only transcripts and vendored JS). Ordering below is a recommendation, unverified until slice 3 runs it on a VM.

## System level

- `/etc/static` (link into the store): every nix-darwin `/etc` link depends on it.
- `/etc/zshrc`, `/etc/zshenv`, `/etc/zprofile`, `/etc/bashrc` link to `/etc/static/*`. Must be replaced by their `*.before-nix-darwin` backups (plus `zshrc_Apple_Terminal`) before `/nix` goes, or every login shell breaks. Machines installed by `bin/bootstrap.sh` may also have `*.before-decknix.<ts>` backups from its preflight.
- `/etc/nix/nix.conf` and `registry.json` (links), with `nix.conf.before-nix-darwin` and `nix.custom.conf.before-nix-darwin` backups. `nix.conf` includes `~/.config/nix/access-tokens.conf` and a `netrc-file`.
- `/etc/nix/machines`, `/etc/nix/builder_ed25519{,.pub}`: Linux builder.
- `/etc/nix/macos-keychain.crt`: created by the Determinate installer.
- `/etc/decknix/extensions.json`: decknix.
- `/etc/pam.d/sudo_local`: probably Touch ID for sudo (unverified); safe to remove.
- `/etc/ssh/sshd_config.d/100-nix-darwin.conf`, `101-authorized-keys.conf`; `/etc/static` also has `ssh_config.d/100-linux-builder.conf` and `100-nix-darwin.conf` (whether `/etc/ssh/ssh_config.d` links exist is unverified). Dangling links break ssh config.
- `/etc/ssl/certs/ca-certificates.crt` (link): dangling link breaks tools that read the bundle.
- `/etc/static/sudoers.d/10-nix-darwin-extra-config`, `/etc/terminfo`: low risk.
- `/etc/synthetic.conf` (`nix`, `run`), `/etc/fstab` (Nix volume): the Determinate uninstaller handles them; a reboot is needed.
- APFS volume "Nix Store" (about 119 GB on the reference machine, encrypted; key likely in the system keychain, unverified).
- `/Library/LaunchDaemons`: `org.nixos.nix-daemon`, `org.nixos.darwin-store`, `org.nixos.activate-system`, `org.nixos.linux-builder`, `systems.determinate.nix-installer.nix-hook`. Boot out before deleting the volume.
- `/var/lib/linux-builder/nixos.qcow2` (about 29.5 GB) and `keys/`: not on the Nix volume, removed separately.
- `_nixbld*` users (32) and `nixbld` group: Determinate uninstaller.
- `/nix/var/nix/profiles` (system generations): on the Nix volume.

## User level

- Home-manager links: `~/.zshrc`, `~/.zshenv`, `~/.authinfo` (credentials generated from Nix: copy out a real file first), `~/.config/git`, `~/.config/direnv`, `~/.config/starship.toml`, `~/.hammerspoon/init.lua`, `~/.gradle/gradle.properties`, `~/Library/Fonts/*`, about 20 links inside `~/.emacs.d`, links inside the org workspace directory.
- `~/.local/state/home-manager/gcroots`, `~/.local/state/nix/profiles`.
- `~/Applications/Nix Apps` (16 real app copies made by an rsync activation) and `~/Applications/Home Manager Apps` (link). App preferences in `~/Library` stay. Removing Docker.app may affect Docker data (unverified).
- `~/Library/LaunchAgents` (11 loaded on the reference machine): `emacs-server`, `org.nixos.decknix-hub`, `decknix-repo-sync`, `decknix-session-gc`, `org.nix-community.home.gortex`, plus org overlay agents (an MCP server, five IAP proxies).
- `~/.config/decknix/local/` and `~/.config/decknix/<org>/` (identity, secrets): never delete by default.
- `~/.config/decknix/{flake.nix,flake.lock,settings.nix,settings.toml,adoption.toml}`: keep for reinstall.
- `~/.config/decknix/result`: a GC root to remove.
- `~/.config/decknix` runtime state: `agent-sessions.json` (and about 17 `.bak*`), `agent-previous-*.el`, `agent-live-sessions.el`, `sidebar-state.el`, logs, `hub/`, `boards/`, `agent-progress/`, `repo-sync.json`. Session history is easy to lose for good; keep unless `--purge-state`.
- `~/.local/state/decknix/`: `agent-inbox/`, `agent-sockets/` (1,136 entries), `boards/`, `session-archive/`, layout and session files. Sockets are safe to remove; the archive is worth keeping.
- `~/.cache/decknix/`: safe to delete.
- Agent-sync copies: the agent-sync manifest lists 188 files across agent discovery paths (workspace `.claude`, `.agents`, `.augment`, and user-level `~/.claude/commands`, `~/.augment`, `~/.pi/agent/prompts`, `~/.claude/skills/synced`). They are real copies, so they survive a switch-based removal; delete only manifest entries whose hash is unchanged, and move edited ones to the backup.
- `~/.claude`, `~/.pi`, `~/.augment` beyond manifest entries: the agents' own data (settings, history, projects). Never touch.
- `~/.config/nix/netrc`, `~/.config/nix/access-tokens.conf`: credentials; back up or delete only on purpose.
- Homebrew, App Store apps, vendor installers, company endpoint agents: out of scope, never touched.

## Recommended order for `decknix uninstall --all [--nix]`

1. Plan screen from `/etc/decknix/manifest.json`, backup index, agent-sync manifest; `--dry-run` stops here.
2. Copy out generated credential files flagged in the plan.
3. Boot out decknix and overlay launchd agents and daemons.
4. Remove unchanged agent-sync copies; back up edited ones.
5. Remove non-declarative leftovers: app copies, Linux builder disk, sockets, `result` GC root.
6. nix-darwin uninstaller (restores `*.before-nix-darwin`), then restore installer backups including legacy `*.before-decknix.<ts>`.
7. Remove home-manager generations and GC roots.
8. With `--nix`: `/nix/nix-installer uninstall`; print the reboot note.
9. `decknix doctor --leftovers` (or the shell fallback in `install.sh`) reports anything remaining.
