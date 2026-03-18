# Secrets & Authentication

Decknix keeps secrets separate from your main configuration via gitignored `secrets.nix` files.

## How secrets.nix Works

The [config loader](../architecture/config-loader.md) discovers and loads `secrets.nix` files alongside `home.nix`:

1. `~/.config/decknix/secrets.nix` (root level)
2. `~/.config/decknix/<org>/secrets.nix` (per-org)

Both are merged into your home-manager configuration.

## Quick Setup

```nix
# ~/.config/decknix/local/secrets.nix
{ ... }: {
  home.file.".authinfo".text = ''
    machine api.github.com login YOUR_USERNAME^forge password ghp_YOUR_TOKEN
  '';
}
```

Make sure `secrets.nix` is gitignored:

```bash
echo "secrets.nix" >> ~/.config/decknix/.gitignore
```

## GitHub Token for Forge

Forge (GitHub PRs in Emacs) needs a Personal Access Token.

### 1. Create a Token

1. Go to [GitHub → Settings → Developer Settings → Personal Access Tokens](https://github.com/settings/tokens)
2. Generate a classic token with scopes: `repo`, `read:org`, `read:user`
3. Copy the token (starts with `ghp_`)

### 2. Add to secrets.nix

```nix
{ ... }: {
  home.file.".authinfo".text = ''
    machine api.github.com login YOUR_USERNAME^forge password ghp_xxxxxxxxxxxx
  '';
}
```

### 3. Verify in Emacs

```
M-x auth-source-search RET
host: api.github.com
user: YOUR_USERNAME^forge
```

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

For multiple GitHub accounts (personal + work), add entries for each:

```nix
{ ... }: {
  home.file.".authinfo".text = ''
    machine api.github.com login personal-user^forge password ghp_personal_xxx
    machine api.github.com login work-user^forge password ghp_work_yyy
  '';
}
```

When you first use Forge in a repo, it prompts for which username to use. The choice is stored in `.git/config`.

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
2. **Use GPG encryption** — encrypt `.authinfo` as `.authinfo.gpg`
3. **Use short-lived tokens** — set token expiration when possible
4. **Limit token scopes** — only grant necessary permissions
5. **Prefer SSH** — use SSH over HTTPS for git operations
6. **Rotate regularly** — update tokens periodically