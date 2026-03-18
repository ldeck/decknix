# Editors

Decknix provides opinionated configurations for two editors: **Emacs** (full IDE experience) and **Vim** (lightweight enhancements).

## Emacs

A batteries-included Emacs configuration with 13+ modules covering completion, git, LSP, languages, org-mode, and more. Runs as a background daemon on macOS.

**Highlights:**
- Modern completion stack (Vertico, Consult, Corfu)
- Git integration via Magit + Forge (GitHub PRs)
- LSP support for Kotlin, Java, and more via Eglot
- 30+ language modes with syntax highlighting
- Org-mode presentations
- REST API client
- AI agent shell integration

→ **[Full Emacs documentation](./emacs.md)**

## Vim

Lightweight enhancements on top of the base Vim config.

**Highlights:**
- Trailing whitespace cleanup (vim-better-whitespace)
- Fuzzy file finder (skim)
- Base config: line numbers, exrc, secure mode

→ **[Full Vim documentation](./vim.md)**

## Profiles

Both editors support tiered profiles to control how much framework config is applied:

```nix
{ ... }: {
  decknix.editors.emacs.profile = "standard";  # minimal | standard | full | custom
  decknix.editors.vim.profile = "minimal";     # minimal | standard | custom
}
```

Setting `custom` disables the framework's editor config entirely, letting you bring your own.

