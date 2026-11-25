# Secrets & Authentication

Secrets live in the OS keychain, managed with `decknix secrets`, and are read at runtime by whatever needs them. They never live inside `~/.config/decknix`.

## Why not inside ~/.config/decknix

`~/.config/decknix` is your system flake. `decknix switch` hands it to Nix as a `path:` flake, so every evaluation copies the **whole directory** into `/nix/store`, which every user on the machine can read. File modes do not survive the copy: a `0600` token under `~/.config/decknix/<org>/secrets/` ends up world-readable, once per switch, and stays there until the store is garbage-collected. A gitignored `secrets.nix` keeps a value out of git, not out of the store.

Every switch, and every evaluation, warns about leftovers by path (never contents): an `<org>/secrets/` directory, a secret-named file such as `local/slack.env`, or what looks like a credential literal in a `secrets.nix`.

## decknix secrets

```bash
decknix secrets set jira-token --org my-org     # hidden prompt, or the value on stdin
decknix secrets get jira-token --org my-org     # prints the value (for scripts)
decknix secrets list --org my-org               # names and whether each is set, never values
decknix secrets rm jira-token --org my-org
decknix secrets backend --org my-org            # which store, and its keychain service
decknix secrets exec --org my-org --secret JIRA_API_TOKEN=jira-token -- some-tool
```

Values never travel on the command line (argv is visible to every local user through `ps`): `set` reads stdin or a hidden prompt, and the keychain write goes through `security -i` with the value hex-encoded on its stdin. `exec` puts the named secrets into one child's environment and no other process's; a variable already set in the caller's environment wins.

`--org` groups secrets per org (default `$DECKNIX_SECRETS_ORG`, else `local`).

### Backends

| Backend     | Where                                                                | Chosen when                         |
|-------------|----------------------------------------------------------------------|-------------------------------------|
| `keychain`  | macOS login keychain, service `decknix-<org>`                        | macOS (default)                     |
| `libsecret` | Linux session keyring through `secret-tool`                          | `secret-tool` is on `PATH`          |
| `file`      | `0600` files in `~/.local/share/decknix/<org>/secrets/` (dir `0700`) | neither of the above                |

Override per machine in `~/.config/decknix/settings.toml` (non-secret settings only):

```toml
[secrets]
backend = "file"                 # or set $DECKNIX_SECRETS_BACKEND

[secrets.services]
my-org = "my-org-tooling"        # keychain service for one org (or $DECKNIX_SECRETS_SERVICE)
```

The file backend refuses any location inside `~/.config/decknix`.

Keychain items are local to the machine: the login keychain is not synced through iCloud, and nothing here is backed up with your config. After a reimage, rerun your org's bootstrap, which prompts for each secret again and stores it with `decknix secrets set`. A password-manager backend may be added later **(Planned)**.

### Reading a secret from config

Reference the secret by name and fetch it when the program starts, never at evaluation time:

```nix
{ pkgs, ... }: {
  # A wrapper script: the store holds the script, not the value.
  home.packages = [ (pkgs.writeShellScriptBin "my-tool" ''
    export MY_TOKEN="$(decknix secrets get my-token --org my-org)"
    exec ${pkgs.my-tool}/bin/my-tool "$@"
  '') ];
}
```

The hub's Jira poller does the same: `decknix.services.hub.jira.apiTokenSecret` (default `jira-token`) in `decknix.services.hub.jira.secretsOrg`.

### Migrating raw files out of the flake dir

```bash
decknix secrets migrate --org my-org --dry-run   # what would move
decknix secrets migrate --org my-org             # move, verify, delete the old files
```

`migrate` stores each file from `~/.config/decknix/<org>/secrets/` through stdin, reads it back and compares it in memory (the report shows only byte counts), and deletes the old file only when that check passes (`--keep` leaves it). `--file NAME=PATH` moves a single file kept elsewhere, and `--env-file PATH` moves each `KEY=value` line of an env file as a kebab-case name (`SLACK_TOKEN` becomes `slack-token`). A name already stored with a different value is left alone unless you pass `--overwrite`.

Until a secret is migrated, `decknix secrets get` (and the hub) still fall back to the old file, with a deprecation warning.

Moving a file does not remove the copies already in the store. Afterwards:

1. Delete any value from `secrets.nix` files and `decknix switch`, so new evaluations copy nothing secret.
2. Garbage-collect the old generations and store paths: `sudo nix-collect-garbage -d`.
3. Confirm, per secret, by file name only. The value goes to `grep` on stdin, not its argv, and is never printed:

   ```bash
   v="$(decknix secrets get jira-token --org my-org)"
   printf '%s\n' "$v" | sudo grep -rlF -f - /nix/store/*-source 2>/dev/null; unset v
   ```

   Any path printed is still alive: `nix-store --query --roots <path>` shows what holds it. Drop `*-source` to search the whole store (much slower).
4. **Rotate** every migrated secret at its provider, since earlier switches published it to the store, and store the new value with `decknix secrets set`.

## Never put a secret in a Nix string

Anything Nix evaluates into a file (`home.file.<name>.text`, `.source`, `programs.*.extraConfig`, an env value) is copied into `/nix/store` too. Keep the value in `decknix secrets` and have a wrapper fetch it at runtime, or let a tool that already stores the secret in the keychain hand it over (as `gh` does for Forge below).

Generating `~/.authinfo` or `~/.netrc` through `home.file` triggers an evaluation warning for exactly this reason.

## GitHub Token for Forge

Forge (GitHub PRs in Emacs) authenticates through ghub. With `programs.emacs.decknix.magit.forge.ghToken.enable` (on by default), a GitHub lookup that auth-source cannot answer falls back to `gh auth token --hostname HOST --user USER`, so the token stays in the keychain and is cached only in Emacs's memory. No `~/.authinfo` is needed.

### 1. Log in with gh

```bash
gh auth login            # once per GitHub account
gh auth status           # lists the logged-in accounts
```

The token's scopes must cover what Forge does: `repo`, `read:org` and `read:user` (the default `gh auth login` scopes include them).

### 2. Tell ghub your username

```bash
git config --global github.user YOUR_USERNAME
```

### 3. Verify in Emacs

```
M-x forge-pull RET
```

After `gh auth refresh` or switching tokens, run `M-x decknix-ghub-gh-token-clear-cache`.

An explicit auth-source entry (for example in `~/.authinfo.gpg`) still takes precedence over gh. Non-GitHub forges such as GitLab still need one.

## GPG-Encrypted Alternative

```bash
# Create and encrypt
echo "machine api.github.com login USER^forge password ghp_xxx" | \
  gpg --encrypt --recipient YOUR_KEY_ID > ~/.authinfo.gpg
```

```nix
{ ... }: {
  programs.emacs.extraConfig = ''
    (setq auth-sources '("~/.authinfo.gpg"))
  '';
}
```

## macOS Keychain

```nix
{ ... }: {
  programs.emacs.extraConfig = ''
    (setq auth-sources '(macos-keychain-internet macos-keychain-generic))
  '';
}
```

```bash
security add-internet-password -a "USER^forge" -s "api.github.com" -w "ghp_xxx"
```



## Multi-Account GitHub Setup

For multiple GitHub accounts (personal + work), log in to each with `gh auth login`; the gh fallback asks for the account ghub names (`gh auth token --user USER`), so each repo gets its own account's token.

When you first use Forge in a repo, it prompts for which username to use. The choice is stored in `.git/config` (`github.user`).

Combine with Git conditional includes for automatic email switching:

```nix
# ~/.config/decknix/my-org/home.nix
{ ... }: {
  programs.git.includes = [{
    condition = "gitdir:~/Code/my-org/";
    contents.user.email = "you@my-org.com";
  }];
}
```

## SSH Keys

```nix
{ ... }: {
  programs.ssh = {
    enable = true;
    matchBlocks."github.com" = {
      identityFile = "~/.ssh/id_ed25519";
      user = "git";
    };
    extraConfig = ''
      AddKeysToAgent yes
      UseKeychain yes
    '';
  };
}
```

## GPG Setup

```nix
{ pkgs, ... }: {
  home.packages = [ pkgs.gnupg pkgs.pinentry_mac ];
  programs.gpg.enable = true;
  home.file.".gnupg/gpg-agent.conf".text = ''
    pinentry-program ${pkgs.pinentry_mac}/bin/pinentry-mac
    default-cache-ttl 3600
    max-cache-ttl 86400
  '';
}
```

## Nix GitHub Auth

Decknix automatically provides authenticated GitHub API access to Nix (5,000 req/hr instead of 60). This uses `gh auth token` to generate `~/.config/nix/access-tokens.conf` on every `decknix switch`.

No configuration needed — enabled by default via `decknix.nix.githubAuth.enable`.

## Security Best Practices

1. **Never commit secrets**, and keep no values in `secrets.nix`
2. **Keep secrets out of the store**: nothing secret inside `~/.config/decknix`, no `home.file` text or Nix strings; use `decknix secrets`, the keychain (gh) or `.authinfo.gpg`
3. **Use short-lived tokens** — set token expiration when possible
4. **Limit token scopes** — only grant necessary permissions
5. **Prefer SSH** — use SSH over HTTPS for git operations
6. **Rotate regularly** — update tokens periodically