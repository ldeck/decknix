# Secrets & Authentication

This guide covers setting up authentication for GitHub (Forge), GPG encryption, and other secrets management in decknix.

## Quick Setup

The recommended approach is using a `secrets.nix` file in your org directory:

```nix
# ~/.local/decknix/default/secrets.nix
{ config, lib, pkgs, ... }: {

  # GitHub authentication for Forge (PR management in Emacs)
  home.file.".authinfo".text = ''
    machine api.github.com login YOUR_GITHUB_USERNAME^forge password ghp_YOUR_TOKEN
  '';
}
```

**Important:** Add `secrets.nix` to `.gitignore`:

```bash
echo "secrets.nix" >> ~/.local/decknix/.gitignore
```

## GitHub Token for Forge

Forge requires a GitHub Personal Access Token to manage PRs and issues.

### 1. Create a GitHub Token

1. Go to [GitHub Settings → Developer Settings → Personal Access Tokens](https://github.com/settings/tokens)
2. Click "Generate new token (classic)"
3. Select scopes:
   - `repo` (full control of private repositories)
   - `read:org` (read org membership)
   - `read:user` (read user profile)
4. Copy the generated token (starts with `ghp_`)

### 2. Configure Authentication

#### Option A: Plain Text (Simple)

```nix
# ~/.local/decknix/default/secrets.nix
{ ... }: {
  home.file.".authinfo".text = ''
    machine api.github.com login YOUR_USERNAME^forge password ghp_xxxxxxxxxxxx
  '';
}
```

#### Option B: GPG Encrypted (Recommended)

First, create the encrypted file manually:

```bash
# Create authinfo content
cat > /tmp/authinfo << 'EOF'
machine api.github.com login YOUR_USERNAME^forge password ghp_xxxxxxxxxxxx
EOF

# Encrypt with your GPG key
gpg --encrypt --recipient YOUR_GPG_KEY_ID /tmp/authinfo
mv /tmp/authinfo.gpg ~/.authinfo.gpg

# Clean up
rm /tmp/authinfo
```

Then reference it in your config:

```nix
# ~/.local/decknix/default/secrets.nix
{ ... }: {
  # Tell Emacs to use the encrypted file
  programs.emacs.extraConfig = ''
    (setq auth-sources '("~/.authinfo.gpg"))
  '';
}
```

#### Option C: Using macOS Keychain

```nix
{ ... }: {
  programs.emacs.extraConfig = ''
    (setq auth-sources '(macos-keychain-internet macos-keychain-generic))
  '';
}
```

Then add to Keychain:
```bash
security add-internet-password -a "YOUR_USERNAME^forge" -s "api.github.com" -w "ghp_xxxxxxxxxxxx"
```

### 3. Verify in Emacs

After `decknix switch`:

```elisp
M-x auth-source-search RET
;; Enter: host api.github.com, user YOUR_USERNAME^forge
```

## Using Forge

Once authenticated, in any git repository:

```
C-x g          → Open Magit status
@ f f          → Fetch forge topics (PRs, issues)
@ c p          → Create pull request
@ l p          → List pull requests
@ l i          → List issues
RET on PR      → View PR details
```

## Multi-Account GitHub Setup

If you work with multiple GitHub accounts (e.g., personal and work), Forge supports
using different credentials per repository.

### 1. Create Tokens for Each Account

Create a GitHub Personal Access Token for each account:
- Personal account: `ghp_personal_xxxxx`
- Work account: `ghp_work_yyyyy`

### 2. Configure Multiple Accounts in authinfo

Add entries for each account (same host, different logins):

```bash
# ~/.authinfo.gpg content (before encryption)
machine api.github.com login ldeck^forge password ghp_personal_xxxxx
machine api.github.com login lachlan-nurturecloud^forge password ghp_work_yyyyy
```

To create/update encrypted file:
```bash
cat > /tmp/authinfo << 'EOF'
machine api.github.com login ldeck^forge password ghp_personal_xxxxx
machine api.github.com login lachlan-nurturecloud^forge password ghp_work_yyyyy
EOF

gpg --encrypt --recipient YOUR_GPG_KEY_ID /tmp/authinfo
mv /tmp/authinfo.gpg ~/.authinfo.gpg
rm /tmp/authinfo
```

### 3. First-Time Per-Repository Setup

When you first use Forge in a repository:

1. Open the repo in Emacs: `C-x g` (magit-status)
2. Fetch topics: `@ f f`
3. Forge will prompt: "GitHub username for https://github.com/ORG/REPO:"
4. Enter the appropriate username (e.g., `lachlan-nurturecloud` for work repos)

This stores the username in `.git/config`:
```ini
[github "user"]
    username = lachlan-nurturecloud
```

### 4. Automatic Git Email Switching

Combine with Git conditional includes to automatically use correct email:

```nix
# ~/.local/decknix/nurturecloud/home.nix
{ ... }: {
  programs.git.includes = [
    {
      condition = "gitdir:~/Code/nurturecloud/";
      contents = {
        user = {
          email = "lachlan@nurturecloud.com";
          name = "Lachlan Deck";
        };
        commit.gpgsign = true;
      };
    }
  ];
}
```

### 5. Verify Multi-Account Setup

Test that Forge finds the correct credentials:

```elisp
;; In Emacs
M-x auth-source-search RET
;; host: api.github.com
;; user: lachlan-nurturecloud^forge
;; Should return your work token

M-x auth-source-search RET
;; host: api.github.com
;; user: ldeck^forge
;; Should return your personal token
```

## PR Review Workflow

Once set up, use these keybindings to review PRs:

```
;; In Magit status (C-x g)
@ f f          → Fetch PRs and issues
@ l p          → List all PRs

;; On a PR in the list
RET            → View PR details
C-c C-r        → Show PR diff for review

;; In PR diff
C-c C-c        → Add review comment at point
C-c C-a        → Approve PR
C-c C-r        → Request changes
C-c C-s        → Submit review

;; In PR topic buffer
C-c C-m        → Merge PR
b              → Open in browser
w              → Copy PR URL
```

## GitLab Support

For GitLab, add another machine entry:

```nix
{ ... }: {
  home.file.".authinfo".text = ''
    machine api.github.com login YOUR_GITHUB_USER^forge password ghp_xxxx
    machine gitlab.com/api/v4 login YOUR_GITLAB_USER^forge password glpat-xxxx
  '';
}
```

## SSH Keys

### Generate SSH Key

```nix
# ~/.local/decknix/default/home.nix
{ ... }: {
  programs.ssh = {
    enable = true;
    matchBlocks = {
      "github.com" = {
        identityFile = "~/.ssh/id_ed25519";
        user = "git";
      };
      "work-github" = {
        hostname = "github.com";
        identityFile = "~/.ssh/id_work";
        user = "git";
      };
    };
  };
}
```

### SSH Agent on macOS

```nix
{ ... }: {
  programs.ssh.extraConfig = ''
    AddKeysToAgent yes
    UseKeychain yes
  '';
}
```

## GPG Setup

### Install GPG

```nix
# ~/.local/decknix/default/home.nix
{ pkgs, ... }: {
  home.packages = [ pkgs.gnupg pkgs.pinentry_mac ];

  programs.gpg.enable = true;

  # Use pinentry-mac for passphrase prompts
  home.file.".gnupg/gpg-agent.conf".text = ''
    pinentry-program ${pkgs.pinentry_mac}/bin/pinentry-mac
    default-cache-ttl 3600
    max-cache-ttl 86400
  '';
}
```

### Import Existing Key

```bash
gpg --import your-private-key.asc
gpg --edit-key YOUR_KEY_ID trust
```

## Environment Variables

For non-sensitive env vars:

```nix
{ ... }: {
  home.sessionVariables = {
    AWS_PROFILE = "default";
    KUBECONFIG = "$HOME/.kube/config";
  };
}
```

For sensitive env vars, use a shell script:

```nix
{ ... }: {
  home.file.".config/secrets/env.sh" = {
    text = ''
      export API_KEY="secret-value"
      export DATABASE_URL="postgres://..."
    '';
    executable = false;
  };

  programs.zsh.initExtra = ''
    [[ -f ~/.config/secrets/env.sh ]] && source ~/.config/secrets/env.sh
  '';
}
```

## Security Best Practices

1. **Never commit secrets** - Always gitignore `secrets.nix` and credential files
2. **Use GPG encryption** - Encrypt `.authinfo` as `.authinfo.gpg`
3. **Use short-lived tokens** - Set token expiration when possible
4. **Limit token scopes** - Only grant necessary permissions
5. **Use SSH keys** - Prefer SSH over HTTPS for git operations
6. **Rotate regularly** - Update tokens periodically

