# Secrets & Authentication

This guide covers setting up authentication for GitHub (Forge), GPG encryption, and other secrets management in decknix.

## How secrets.nix Works

The decknix `configLoader` (see [`lib/default.nix`](../lib/default.nix)) automatically discovers and loads `secrets.nix` files from your org directories alongside `home.nix`. This allows you to keep sensitive configuration separate and gitignored.

**File discovery order:**
1. `~/.local/decknix/secrets.nix` (root level)
2. `~/.local/decknix/<org>/secrets.nix` (per-org)

Both are merged into your home-manager configuration.

## Quick Setup

Create a `secrets.nix` file in your org directory:

```nix
# ~/.local/decknix/default/secrets.nix
{ ... }: {
  # GitHub authentication for Forge (PR management in Emacs)
  # Format: machine HOST login USER^forge password TOKEN
  home.file.".authinfo".text = ''
    machine api.github.com login YOUR_GITHUB_USERNAME^forge password ghp_YOUR_TOKEN
  '';
}
```

**Important:** Add `secrets.nix` to `.gitignore`:

```bash
echo "secrets.nix" >> ~/.local/decknix/.gitignore
```

After creating the file, run `decknix switch` to apply.

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

### 2. Configure Authentication in secrets.nix

Create `~/.local/decknix/<org>/secrets.nix`:

```nix
# ~/.local/decknix/default/secrets.nix
{ ... }: {
  home.file.".authinfo".text = ''
    machine api.github.com login YOUR_USERNAME^forge password ghp_xxxxxxxxxxxx
  '';
}
```

This writes your credentials to `~/.authinfo`, which Emacs reads for Forge authentication.

> **Reference:** The authinfo format is documented in the [Emacs auth-source manual](https://www.gnu.org/software/emacs/manual/html_mono/auth.html) and [Forge documentation](https://magit.vc/manual/forge/Token-Creation.html).

### Alternative: GPG Encrypted (More Secure)

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
' (apostrophe) → Open Forge dispatch menu
  f f          → Fetch all topics (PRs, issues)
  c p          → Create pull request
  v p          → Visit pull request (select from list)
  v i          → Visit issue
  b p          → Browse PR in browser
```

## Multi-Account GitHub Setup

If you work with multiple GitHub accounts (e.g., personal and work), Forge supports
using different credentials per repository.

### 1. Create Tokens for Each Account

Create a GitHub Personal Access Token for each account:
- Personal account: `ghp_personal_xxxxx`
- Work account: `ghp_work_yyyyy`

### 2. Configure Multiple Accounts in secrets.nix

Add entries for each account in your `secrets.nix` (same host, different logins):

```nix
# ~/.local/decknix/default/secrets.nix
{ ... }: {
  home.file.".authinfo".text = ''
    machine api.github.com login ldeck^forge password ghp_personal_xxxxx
    machine api.github.com login lachlan-work^forge password ghp_work_yyyyy
  '';
}
```

Then run `decknix switch` to apply.

> **How it works:** Forge uses the `^forge` suffix to identify credentials for its use.
> When you have multiple entries for the same host, Forge selects based on the
> repository's configured username (see step 3 below).
>
> **Reference:** See [Forge Token Creation](https://magit.vc/manual/forge/Token-Creation.html)
> and [ghub Getting Started](https://magit.vc/manual/ghub/Getting-Started.html).

### 3. First-Time Per-Repository Setup

When you first use Forge in a repository:

1. Open the repo in Emacs: `C-x g` (magit-status)
2. Open Forge dispatch: `'` (apostrophe), then `f f` to fetch topics
3. Forge will prompt: "GitHub username for https://github.com/ORG/REPO:"
4. Enter the appropriate username (e.g., `lachlan-work` for work repos)

This stores the username in `.git/config`:
```ini
[github "user"]
    username = lachlan-work
```

### 4. Automatic Git Email Switching

Combine with Git conditional includes to automatically use correct email:

```nix
# ~/.local/decknix/work/home.nix
{ ... }: {
  programs.git.includes = [
    {
      condition = "gitdir:~/Code/work/";
      contents = {
        user = {
          email = "lachlan@work.com";
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
;; user: lachlan-work^forge
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
' (apostrophe) → Open Forge dispatch menu
  f f          → Fetch all topics (PRs/issues)
  v p          → Visit pull request (select from list)

;; In PR topic buffer
n / p          → Navigate sections
TAB            → Expand/collapse section
C-c C-n        → Create new comment
C-c C-r        → Show PR diff for review [decknix]
b              → Open in browser
w              → Copy PR URL

;; Note: Inline code comments require the code-review package
;; Forge's topic buffer shows existing comments but has limited
;; inline comment creation. Use 'b' to open in browser for full review.
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

