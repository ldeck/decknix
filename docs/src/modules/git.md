# Git

Decknix provides a sensible Git configuration with modern tooling.

## Default Settings

| Setting | Value | Description |
|---------|-------|-------------|
| `init.defaultBranch` | `main` | Default branch name |
| `pull.rebase` | `true` | Rebase on pull instead of merge |
| `push.autoSetupRemote` | `true` | Auto-create remote tracking branch |
| `core.pager` | `delta` | Syntax-highlighted diffs |
| `lfs.enable` | `true` | Git Large File Storage |

## Delta Integration

[Delta](https://github.com/dandavison/delta) provides beautiful, syntax-highlighted diffs in the terminal with line numbers.

## Customising Git

```nix
# ~/.config/decknix/local/home.nix
{ ... }: {
  programs.git.settings = {
    user.email = "you@example.com";
    user.name = "Your Name";
    core.editor = "emacsclient -c";
  };
}
```

## Conditional Includes

Use different identities for different directories:

```nix
{ ... }: {
  programs.git.includes = [{
    condition = "gitdir:~/Code/work/";
    contents = {
      user.email = "you@company.com";
      user.name = "Your Name";
      commit.gpgsign = true;
    };
  }];
}
```

## Magit (Emacs Git Interface)

The [Emacs module](./emacs.md) includes **Magit** — a full Git interface inside Emacs:

- `C-x g` → Git status
- Stage, commit, push, pull, rebase — all from keyboard
- **Forge** — manage GitHub PRs and issues without leaving Emacs
- **code-review** — inline PR review with comments

See [Secrets & Authentication](../configuration/secrets.md) for Forge token setup.

## GitHub CLI

The `gh` CLI is installed by default. Decknix also auto-configures authenticated GitHub API access for Nix itself via `decknix.nix.githubAuth` (see [Secrets](../configuration/secrets.md#nix-github-auth)).

