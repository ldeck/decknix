{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix;
  isDarwin = pkgs.stdenv.isDarwin;

  # Base Emacs package
  # Use standard emacs (emacs30) on all platforms.
  # emacs-macport has better macOS integration but its daemon mode cannot
  # create GUI frames - emacsclient -c only creates terminal frames.
  # Standard emacs daemon mode works correctly with GUI frames.
  baseEmacsPackage = pkgs.emacs;
in
{
  options.programs.emacs.decknix = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Emacs with decknix defaults.";
    };

    package = mkOption {
      type = types.package;
      default = baseEmacsPackage;
      defaultText = literalExpression "pkgs.emacs";
      description = ''
        The Emacs package to use.

        Defaults to standard GNU Emacs (emacs30) which supports:
        - Daemon mode with GUI frames (emacsclient -c creates GUI frames)
        - Hidden daemon process (no Dock icon until frame is opened)
        - Native macOS Cocoa integration

        Note: emacs-macport has better macOS integration (pixel scrolling,
        input methods) but its daemon mode cannot create GUI frames.
      '';
    };

  };

  config = mkIf cfg.enable {
    programs.emacs = {
      enable = true;
      package = cfg.package;

      extraPackages = epkgs: with epkgs; [
        modus-themes           # High-contrast accessible themes
        exec-path-from-shell   # Inherit PATH from shell (critical for tools like rg, git, etc.)
        gcmh                   # GC Magic Hack: large threshold while active, GC on idle
      ];

      extraConfig = ''
        ;;; Decknix Core Emacs Configuration

        ;; == PATH from shell ==
        ;; Critical: Inherit PATH from shell so tools like rg, git, etc. are found
        ;; This is especially important for GUI Emacs and the Emacs daemon
        (use-package exec-path-from-shell
          :config
          (when (or (daemonp) (memq window-system '(mac ns x)))
            (exec-path-from-shell-initialize)))

        ;; == Server ==
        ;; Start the Emacs server when running as GUI (not daemon)
        ;; This allows emacsclient to connect to the GUI Emacs
        ;; For emacs-mac-port, the server must be started from GUI context
        ;; to support creating new GUI frames via emacsclient
        (require 'server)
        (unless (or (daemonp) (server-running-p))
          (server-start))

        ;; == Startup ==
        (setq inhibit-startup-message t
              initial-scratch-message nil
              initial-major-mode 'fundamental-mode)

        ;; Disable all bells (audible and visual) - no beeps or flashes
        ;; Visual feedback is provided by UI elements instead
        (setq ring-bell-function 'ignore)

        ;; Don't blink the cursor
        (blink-cursor-mode -1)

        ;; == Theme ==
        ;; Load modus-vivendi (high-contrast dark theme)
        (load-theme 'modus-vivendi t)

        ;; Fix face attribute warnings (nil should be 'unspecified)
        (with-eval-after-load 'modus-themes
          (when (facep 'modus-themes-button)
            (set-face-attribute 'modus-themes-button nil
                                :background 'unspecified
                                :foreground 'unspecified)))
        (when (facep 'widget-inactive)
          (set-face-attribute 'widget-inactive nil
                              :background 'unspecified
                              :foreground 'unspecified))

        ;; == Line numbers ==
        (global-display-line-numbers-mode 1)

        ;; Disable line numbers in specific modes
        (dolist (mode '(org-mode-hook
                        term-mode-hook
                        vterm-mode-hook
                        shell-mode-hook
                        eshell-mode-hook
                        treemacs-mode-hook))
          (add-hook mode (lambda () (display-line-numbers-mode 0))))

        ;; == Mode line ==
        (line-number-mode 1)
        (column-number-mode 1)

        ;; == Visual feedback ==
        (global-hl-line-mode 1)
        (show-paren-mode 1)
        (setq show-paren-delay 0
              show-paren-style 'parenthesis)

        ;; == Recent files ==
        (recentf-mode 1)
        (setq recentf-max-menu-items 25
              recentf-max-saved-items 100
              recentf-exclude '("COMMIT_EDITMSG" "COMMIT_MSG" "\\.git"))

        ;; == Save place ==
        (save-place-mode 1)

        ;; == Scrolling ==
        (setq scroll-conservatively 101
              scroll-margin 3
              scroll-preserve-screen-position t)

        ;; == Indentation ==
        (setq-default indent-tabs-mode nil
                      tab-width 2)

        ;; == Auto-revert ==
        (global-auto-revert-mode 1)
        (setq global-auto-revert-non-file-buffers t)

        ;; == Backups and autosave ==
        (let ((backup-dir (expand-file-name "backups" user-emacs-directory))
              (autosave-dir (expand-file-name "auto-save-list" user-emacs-directory)))
          (unless (file-exists-p backup-dir) (make-directory backup-dir t))
          (unless (file-exists-p autosave-dir) (make-directory autosave-dir t))
          (setq backup-directory-alist `(("." . ,backup-dir))
                auto-save-file-name-transforms `((".*" ,autosave-dir t))))

        ;; Don't create lock files
        (setq create-lockfiles nil)

        ;; == Window management ==
        (winner-mode 1)

        ;; == Yes/No prompts ==
        (setq use-short-answers t)  ; 'y' or 'n' instead of 'yes' or 'no'

        ;; == Clipboard ==
        (setq select-enable-clipboard t
              select-enable-primary nil
              save-interprogram-paste-before-kill t
              mouse-yank-at-point t)

        ;; == Performance / GC ==
        ;; gcmh (GC Magic Hack): keep gc-cons-threshold large during
        ;; interactive work (no GC stalls during LSP completion, consult
        ;; searches, Kotlin/Java file analysis), then collect once after
        ;; `gcmh-idle-delay' seconds of idle time.  This reclaims memory
        ;; when a session goes quiet — important when multiple Emacs frames
        ;; share one daemon heap.
        (use-package gcmh
          :demand t
          :config
          ;; 512 MB during work (was 256): long agent-shell sessions churn
          ;; large overlay/text-property/interval trees, and CPU sampling
          ;; showed GC *marking* (mark_overlays / traverse_intervals /
          ;; mark_char_table) as a top cost.  A higher work-time threshold
          ;; keeps that collection from firing mid-typing; gcmh still
          ;; reclaims on idle.
          ;; `gcmh-idle-delay' was 5s, so any think-pause over 5s fired the
          ;; ~213ms reclaim GC right as the user resumed typing (the profiler
          ;; caught it as the "cursor stuck on resume" hitch).  Raise it to
          ;; 20s (above gcmh's own 15s default) so only genuine idle
          ;; reclaims; memory headroom is ample (~600MB RSS, no pressure).
          (setq gcmh-high-cons-threshold (* 512 1024 1024)  ; 512 MB during work
                gcmh-idle-delay 20)                          ; reclaim only after 20s idle
          (gcmh-mode 1))

        ;; Increase process output buffer (important for LSP)
        (setq read-process-output-max (* 1024 1024))  ; 1MB

        ;; Comint buffer size cap — prevents long-running agent-shell
        ;; sessions from accumulating unbounded output in memory.
        ;; comint truncates to this line count when the filter hook fires.
        (setq comint-buffer-maximum-size 20000)
        (add-hook 'comint-output-filter-functions
                  #'comint-truncate-buffer)

        ;; == Misc ==
        (setq uniquify-buffer-name-style 'forward)  ; Better buffer naming
        (setq-default fill-column 80)               ; Default fill column
      '';
    };
  };
}

