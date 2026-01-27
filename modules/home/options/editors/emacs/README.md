# Emacs Configuration

This directory contains the decknix Emacs configuration modules, providing a modern,
batteries-included Emacs experience out of the box.

## Modules Overview

| Module | Description | Enabled by Default |
|--------|-------------|-------------------|
| `default.nix` | Core settings (theme, scrolling, backups) | ✓ |
| `welcome.nix` | Startup screen with keybinding cheat sheet | ✓ |
| `magit.nix` | Git integration via Magit, Forge, code-review | ✓ |
| `completion.nix` | Modern completion (Vertico, Consult, Corfu) | ✓ |
| `treemacs.nix` | Project file tree with git integration | ✓ |
| `undo.nix` | Improved undo (undo-fu, vundo) | ✓ |
| `editing.nix` | Editing enhancements (smartparens, crux) | ✓ |
| `development.nix` | Development tools (Flycheck, Yasnippet) | ✓ |
| `ui.nix` | UI improvements (which-key, helpful, icons) | ✓ |
| `org.nix` | Org-mode presentations and modern styling | ✓ |
| `languages.nix` | 30+ language modes with syntax highlighting | ✓ |

## Features by Module

### Core (`default.nix`)

- Modus-vivendi theme (high-contrast dark)
- Line numbers, column numbers, current line highlighting
- Matching parentheses, recent files, save-place
- Better scrolling, spaces instead of tabs
- Auto-refresh buffers, organized backups
- Winner mode, improved performance settings

### Welcome Screen (`welcome.nix`)

Beautiful startup screen with decknix branding:

- **ASCII Art Logo**: "DECKNIX" banner in Unicode block characters
- **Keybinding Cheat Sheet**: 6 categories in 2-column layout
  - Navigation & Search, Buffers & Files, Editing
  - Code & Completion, Git (Magit), Help & Discovery
- **Recent Files**: Optional list of recently opened files
- **Auto-refresh**: Responds to window resizing

Key bindings:
- `C-c w` → Open welcome screen anytime

Options:
- `programs.emacs.decknix.welcome.enable` - Enable/disable (default: true)
- `programs.emacs.decknix.welcome.showRecentFiles` - Show recent files section (default: true)
- `programs.emacs.decknix.welcome.recentFilesCount` - Number of files to show (default: 5)

### Completion (`completion.nix`)

Modern completion stack replacing traditional Emacs defaults:

- **Vertico**: Vertical completion UI in minibuffer
- **Marginalia**: Rich annotations (file sizes, docstrings, etc.)
- **Consult**: Enhanced commands with live preview
- **Orderless**: Flexible fuzzy matching
- **Embark**: Context actions on any target (`C-.`)
- **Corfu**: In-buffer completion popup
- **Cape**: Completion-at-point extensions
- **Wgrep**: Editable grep buffers

Key bindings (Consult remaps standard commands):
- `C-s` → `consult-line` (search in buffer)
- `C-x b` → `consult-buffer` (switch buffer with preview)
- `M-y` → `consult-yank-pop` (browse kill ring)
- `M-s r` → `consult-ripgrep` (project-wide search)
- `C-.` → `embark-act` (context actions)

### Treemacs (`treemacs.nix`)

Project file tree for visual navigation:

- **Treemacs**: Full-featured file tree with icons and git integration
- **treemacs-magit**: Magit integration for git status
- **treemacs-all-the-icons**: Beautiful icons (when ui.icons enabled)

Key bindings:
- `C-x t t` → Toggle treemacs
- `C-x t f` → Find current file in tree
- `C-x t d` → Select directory to display
- `C-x p p t` → Open treemacs for project (via project-switch)

Features:
- Auto-follows current file in tree
- Git status indicators on files/folders
- File system watching for auto-refresh
- Tucks away when selecting a file

Options:
- `programs.emacs.decknix.treemacs.width` - Tree width (default: 35)
- `programs.emacs.decknix.treemacs.followMode` - Auto-follow files (default: true)
- `programs.emacs.decknix.treemacs.gitMode` - Show git status (default: true)

### Undo (`undo.nix`)

Improved undo/redo replacing undo-tree:

- **undo-fu**: Linear undo/redo (`C-/` / `C-?`)
- **undo-fu-session**: Persist undo history across sessions
- **vundo**: Visual undo tree (`C-x u`)

### Editing (`editing.nix`)

- **Smartparens**: Structured pair editing with navigation
- **Editorconfig**: Respect `.editorconfig` files
- **Crux**: Useful commands (`C-a` smart home, `C-c d` duplicate line)
- **Move-text**: Move lines/regions (`M-up` / `M-down`)

### Development (`development.nix`)

- **Flycheck**: On-the-fly syntax checking (`M-n` / `M-p` to navigate errors)
- **Yasnippet**: Snippet expansion (`C-c y` to expand)

### UI (`ui.nix`)

- **Which-key**: Shows available keybindings as you type
- **Helpful**: Enhanced help buffers with more context
- **Nerd-icons**: File icons in completion, dired, corfu (uses Nerd Fonts)

### Git (`magit.nix`)

- **Magit**: Full Git interface (`C-x g` for status)
- **Forge**: GitHub/GitLab PR and issue management
- **code-review**: Inline PR review with comments

Key bindings (in magit-status after `C-x g`):
- `@ f f` → Fetch forge topics (PRs, issues)
- `@ c p` → Create pull request
- `@ l p` → List pull requests
- `@ l i` → List issues
- `RET` on PR → View PR details

**Setup Required:** Forge needs a GitHub token. See [Secrets Guide](../../../../docs/secrets.md).

Options:
- `programs.emacs.decknix.magit.forge.enable` - Enable Forge (default: true)
- `programs.emacs.decknix.magit.codeReview.enable` - Enable code-review (default: true)

### Org-mode (`org.nix`)

Beautiful org documents and interactive presentations:

- **Org-modern**: Modern styling with pretty bullets, checkboxes, and tables
- **Org-tree-slide**: Presentation mode showing one heading at a time
- **Olivetti**: Centered, distraction-free view during presentations

Key bindings:
- `<F5>` or `C-c p` → Start/stop presentation mode
- `<right>` or `n` → Next slide (during presentation)
- `<left>` or `p` → Previous slide (during presentation)
- `q` → Exit presentation

Features during presentation:
- Larger text (configurable scale)
- Centered content with olivetti
- Line numbers and highlighting hidden
- Checkboxes remain interactive (`C-c C-c` to toggle)

Options:
- `programs.emacs.decknix.org.enable` - Enable/disable (default: true)
- `programs.emacs.decknix.org.presentation.enable` - Enable presentation mode (default: true)
- `programs.emacs.decknix.org.presentation.textScale` - Text size during presentation (default: 2)
- `programs.emacs.decknix.org.modern.enable` - Enable org-modern styling (default: true)

### Languages (`languages.nix`)

Comprehensive syntax highlighting for 30+ languages and file types:

| Category | Languages |
|----------|-----------|
| **Primary** | Kotlin, Java, Scala, SQL, Terraform/HCL, Shell, Nix, Python |
| **Data** | JSON, YAML, TOML, XML, Markdown |
| **Web** | HTML, CSS/SCSS/LESS, JavaScript, TypeScript, JSX, Vue, Svelte |
| **Systems** | Rust (+ Cargo), Go, Protobuf, Thrift, GraphQL, Docker, Lua |
| **Lisp** | Common Lisp (SLY), Scheme (Geiser), Clojure (CIDER), Racket |
| **Build** | Makefile, CMake, Just, Gradle, Maven, Bazel |
| **Config** | EditorConfig, .gitignore, .env, Apache, properties |

Special features:
- **Cargo integration** for Rust (`C-c C-c C-b` build, `C-c C-c C-t` test)
- **Maven commands** (`M-x mvn-*`) - only active in Maven projects
- **Gradle commands** (`M-x gradle-*`) - manual activation
- **Lisp tools**: paredit (structural editing), rainbow-delimiters
- **Org source blocks**: Native syntax highlighting via `org-src-fontify-natively`

Options (each language can be disabled individually):
```nix
{
  programs.emacs.decknix.languages.enable = false;     # Disable all languages
  programs.emacs.decknix.languages.rust.enable = false; # Disable just Rust
  programs.emacs.decknix.languages.lisp.enable = false; # Disable Lisp family
}
```

## Disabling Modules

All modules are enabled by default. Disable individually:

```nix
{
  programs.emacs.decknix.enable = false;            # Disable ALL emacs config
  programs.emacs.decknix.welcome.enable = false;    # Disable welcome screen
  programs.emacs.decknix.magit.enable = false;      # Disable just magit
  programs.emacs.decknix.completion.enable = false; # Disable completion stack
  programs.emacs.decknix.undo.enable = false;       # Disable undo enhancements
  programs.emacs.decknix.editing.enable = false;    # Disable editing enhancements
  programs.emacs.decknix.development.enable = false;# Disable flycheck/yasnippet
  programs.emacs.decknix.ui.enable = false;         # Disable UI enhancements
  programs.emacs.decknix.ui.icons.enable = false;   # Disable just icons
  programs.emacs.decknix.org.enable = false;        # Disable org enhancements
  programs.emacs.decknix.org.presentation.enable = false; # Disable just presentations
}
```

## Emacs Daemon

Configured in `modules/darwin/emacs.nix`, enabled by default on macOS.

```bash
ec filename           # Open file in terminal
emacsclient -c        # Create new GUI frame
```

## Customization

### Use a different Emacs package

```nix
{
  programs.emacs.decknix.package = pkgs.emacs29;
}
```

### Add your own packages

```nix
{
  programs.emacs.extraPackages = epkgs: with epkgs; [
    treemacs
    lsp-mode
  ];
}
```

### Add your own configuration

```nix
{
  programs.emacs.extraConfig = ''
    ;; Your custom Emacs Lisp here
    (setq my-custom-variable t)
  '';
}
```

## Note on Evil Mode

Evil mode (Vim emulation) is **not** included. Add it in your local configuration:

```nix
{
  programs.emacs.extraPackages = epkgs: [ epkgs.evil ];
  programs.emacs.extraConfig = "(evil-mode 1)";
}
```

