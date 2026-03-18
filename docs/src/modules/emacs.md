# Emacs

Decknix provides a modern, batteries-included Emacs experience with 13+ modules, background daemon, and three profile tiers.

## Modules

| Module | Description | Profile |
|--------|-------------|---------|
| **Core** | Modus theme, line numbers, better defaults | minimal+ |
| **Completion** | Vertico, Consult, Corfu, Embark | minimal+ |
| **Editing** | Smartparens, Crux, Move-text, EditorConfig | minimal+ |
| **UI** | Which-key, Helpful, Nerd-icons | minimal+ |
| **Undo** | undo-fu, vundo (visual undo tree) | minimal+ |
| **Project** | Project management and navigation | minimal+ |
| **Welcome** | Startup screen with keybinding cheat sheet | standard+ |
| **Development** | Flycheck, Yasnippet | standard+ |
| **Magit** | Git interface, Forge (GitHub PRs), code-review | standard+ |
| **Treemacs** | Project file tree with git integration | standard+ |
| **Languages** | 30+ language modes with syntax highlighting | standard+ |
| **LSP** | Eglot, kotlin-ls, jdt-ls, dape (debugging) | full |
| **Org-mode** | Modern styling, presentations (Olivetti) | full |
| **HTTP** | REST client, jq integration, org-babel | full |
| **Agent Shell** | AI agent interface (Augment Code) | full |

## Key Bindings — Quick Reference

### Navigation & Search

| Key | Action |
|-----|--------|
| `C-s` | Search in buffer (consult-line) |
| `C-x b` | Switch buffer with preview |
| `M-s r` | Project-wide ripgrep search |
| `M-y` | Browse kill ring |
| `C-.` | Context actions (Embark) |

### Git (Magit)

| Key | Action |
|-----|--------|
| `C-x g` | Magit status |
| `@ f f` | Fetch forge topics (PRs/issues) |
| `@ c p` | Create pull request |
| `@ l p` | List pull requests |

### File Tree (Treemacs)

| Key | Action |
|-----|--------|
| `C-x t t` | Toggle treemacs |
| `C-x t f` | Find current file in tree |

### LSP / Code

| Key | Action |
|-----|--------|
| `C-c l r` | Rename symbol |
| `C-c l a` | Code actions |
| `C-c l f` | Format region |
| `C-c l F` | Format buffer |
| `C-c l d` | Show documentation |

### Debugging (dape)

| Key | Action |
|-----|--------|
| `C-c d d` | Start debugger |
| `C-c d b` | Toggle breakpoint |
| `C-c d n` | Step over |
| `C-c d s` | Step in |
| `C-c d c` | Continue |

### Editing

| Key | Action |
|-----|--------|
| `C-a` | Smart home (Crux) |
| `C-c d` | Duplicate line |
| `M-up/down` | Move line/region |
| `C-/` | Undo |
| `C-?` | Redo |
| `C-x u` | Visual undo tree (vundo) |

### Org-mode

| Key | Action |
|-----|--------|
| `F5` or `C-c p` | Start/stop presentation |
| `n` / `p` | Next/previous slide |

## Languages

30+ languages with syntax highlighting:

| Category | Languages |
|----------|-----------|
| **Primary** | Kotlin, Java, Scala, SQL, Terraform/HCL, Shell, Nix, Python |
| **Data** | JSON, YAML, TOML, XML, Markdown |
| **Web** | HTML, CSS/SCSS/LESS, JavaScript, TypeScript, JSX, Vue, Svelte |

## Emacs Daemon

Configured in `modules/darwin/emacs.nix`, enabled by default on macOS. Runs as a background launchd service — no Dock icon, no Cmd+Tab entry.

```bash
ec filename          # Open file in Emacs
ec -c -n             # New GUI frame
ec -c -n file.txt    # Open file in new GUI frame
ec -t file.txt       # Open in terminal
emacsclient -c       # Create new GUI frame
```

GUI frames appear in the Dock while open; closing a frame doesn't kill the daemon.

| Option | Default | Description |
|--------|---------|-------------|
| `services.emacs.decknix.enable` | `true` | Enable Emacs daemon |
| `services.emacs.decknix.package` | `pkgs.emacs` | Emacs package to use |
| `services.emacs.decknix.additionalPath` | `[]` | Extra PATH entries for daemon |

## Module Options Reference

### Disabling Modules

```nix
{ ... }: {
  programs.emacs.decknix.enable = false;             # ALL emacs config
  programs.emacs.decknix.welcome.enable = false;     # Welcome screen
  programs.emacs.decknix.magit.enable = false;       # Git interface
  programs.emacs.decknix.magit.forge.enable = false;  # Just Forge
  programs.emacs.decknix.completion.enable = false;  # Completion stack
  programs.emacs.decknix.treemacs.enable = false;    # File tree
  programs.emacs.decknix.undo.enable = false;        # Undo enhancements
  programs.emacs.decknix.editing.enable = false;     # Editing enhancements
  programs.emacs.decknix.development.enable = false; # Flycheck/Yasnippet
  programs.emacs.decknix.ui.enable = false;          # UI enhancements
  programs.emacs.decknix.ui.icons.enable = false;    # Just icons
  programs.emacs.decknix.org.enable = false;         # Org enhancements
  programs.emacs.decknix.lsp.enable = false;         # LSP/IDE
  programs.emacs.decknix.http.enable = false;        # REST client
  programs.emacs.decknix.languages.enable = false;   # All languages
}
```

### Customisation

```nix
{ pkgs, ... }: {
  # Add your own packages
  programs.emacs.extraPackages = epkgs: [ epkgs.evil epkgs.lsp-mode ];

  # Add your own config
  programs.emacs.extraConfig = ''
    (evil-mode 1)
    (setq my-custom-variable t)
  '';
}
```

> **Note:** Evil mode (Vim emulation) is not included by default. Add it in your personal config as shown above.

