# Secrets & Authentication

Decknix keeps secrets separate from your main configuration via gitignored `secrets.nix` files.

## How secrets.nix Works

The [config loader](../architecture/config-loader.md) discovers and loads `secrets.nix` files alongside `home.nix`:

1. `~/.config/decknix/secrets.nix` (root level)
2. `~/.config/decknix/<org>/secrets.nix` (per-org)

Both are merged into your home-manager configuration.

## Never put a secret in a Nix string

Anything Nix evaluates into a file (`home.file.<name>.text`, `.source`, `programs.*.extraConfig`, an env value) is copied into `/nix/store`, which every user on the machine can read, and it stays there until garbage-collected. A gitignored `secrets.nix` keeps a secret out of git, not out of the store. Keep secrets as raw `0600` files outside Nix (for example under `~/.config/decknix/<org>/secrets/`, mode `0700`) and reference them by path, or let a tool that already stores the secret in the keychain hand it over at runtime.

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

1. **Never commit secrets** — always gitignore `secrets.nix`
2. **Keep secrets out of the store**: no `home.file` text or Nix strings; use the keychain (gh), `.authinfo.gpg`, or raw `0600` files
3. **Use short-lived tokens** — set token expiration when possible
4. **Limit token scopes** — only grant necessary permissions
5. **Prefer SSH** — use SSH over HTTPS for git operations
6. **Rotate regularly** — update tokens periodically