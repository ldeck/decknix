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
          ;; Import AI-provider API keys from the login shell so tools launched
          ;; by the daemon (e.g. agent-shell's pi via the pi-acp bridge) inherit
          ;; them.  The keys themselves are set at runtime from 0600 secret files
          ;; by the shell rc (never through the Nix store); here we only widen the
          ;; set of variables exec-path-from-shell copies.  Unset keys are a no-op.
          (dolist (v '("GEMINI_API_KEY" "ANTHROPIC_API_KEY"
                       "OPENAI_API_KEY" "OPENROUTER_API_KEY"))
            (add-to-list 'exec-path-from-shell-variables v))
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
        ;; Silence "nil value is invalid, use `unspecified' instead" by
        ;; repairing the theme's AUTHORITATIVE settings store.
        ;;
        ;; modus-themes 20251007.415 ships face specs carrying literal nil
        ;; for attributes that reject it.  Measured across every face in
        ;; this Emacs, three are affected -- `modus-themes-button',
        ;; `widget-inactive' and `window-tool-bar-button-disabled' -- each
        ;; with `:background nil :foreground nil'.
        ;;
        ;; This has now been got wrong twice, the same way each time, so the
        ;; layering is worth stating.  There are THREE copies of a themed
        ;; face spec, and only the first is authoritative:
        ;;
        ;;   (get THEME 'theme-settings)  entries of (prop face theme spec)
        ;;   (get FACE  'theme-face)      per-face copy, used to realise it
        ;;   the realised face attributes on each frame
        ;;
        ;; `enable-theme' rebuilds the second from the first, in custom.el:
        ;;
        ;;   (put symbol prop (cons (cddr s) (assq-delete-all theme spec-list)))
        ;;
        ;; and then recalculates the third from the second.  So:
        ;;
        ;;   * The ORIGINAL fix here called `set-face-attribute' with
        ;;     `unspecified', repairing copy three.  Overwritten by the next
        ;;     `enable-theme'.
        ;;   * The SECOND attempt rewrote `theme-face', copy two.  Also
        ;;     overwritten, from copy one, by that same line above.
        ;;
        ;; Both looked correct and neither survived a theme enable.  Fix copy
        ;; one and the other two follow; fix either of the others and the
        ;; warning returns the moment anything re-enables the theme.  Copy
        ;; two is rewritten as well, but only so the running session is clean
        ;; without waiting for a re-enable.
        ;;
        ;; Only attributes that genuinely reject nil are rewritten.  For
        ;; `:underline', `:box', `:extend' and friends nil is a VALID value
        ;; meaning "off", and modus uses it that way (e.g.
        ;; `modus-themes-reset-soft' sets five of them); rewriting those
        ;; would change how the theme looks.
        (defconst decknix-face-attrs-rejecting-nil
          '(:family :foundry :width :height :weight :slant
            :foreground :background :distant-foreground :font)
          "Face attributes for which nil is invalid and `unspecified' is meant.
The complement (`:underline', `:box', `:extend', `:inherit', ...) accepts
nil as a real value, so those must be left exactly as the theme wrote
them.")

        (defun decknix-face-attr-plist-p (plist)
          "Non-nil when PLIST is a well-formed face attribute plist.
That is: a proper list of even length whose every even element is a
keyword.

Checked before rewriting anything because a face spec clause is NOT
always a plist.  The old-style form is (DISPLAY (ATTRS...)), where the
attributes are nested one level deeper, and walking that as a plist reads
the inner list as a key, finds no value, and appends a spurious nil.
Measured: a transform without this guard rewrote 103 face specs when only
3 contained an invalid nil -- i.e. it silently restructured 100 specs it
had no business touching.  A theme repair that corrupts the theme is a
worse bug than the warning."
          (and (proper-list-p plist)
               (cl-evenp (length plist))
               (let ((ok t) (rest plist))
                 (while rest
                   (unless (keywordp (car rest)) (setq ok nil))
                   (setq rest (cddr rest)))
                 ok)))

        (defun decknix-sanitise-face-plist (plist)
          "Return PLIST with nil-valued nil-rejecting attributes set to `unspecified'.
Returns PLIST unchanged when it is not a well-formed attribute plist.
Pure: builds a fresh list and leaves PLIST untouched."
          (if (not (decknix-face-attr-plist-p plist))
              plist
            (let ((out nil))
              (while plist
                (let ((key (car plist))
                      (value (cadr plist)))
                  (push key out)
                  (push (if (and (null value)
                                 (memq key decknix-face-attrs-rejecting-nil))
                            'unspecified
                          value)
                        out))
                (setq plist (cddr plist)))
              (nreverse out))))

        (defun decknix-sanitise-face-spec (spec)
          "Return face SPEC with every clause's plist sanitised.
SPEC is a list of (DISPLAY . PLIST) clauses, as stored in a theme.  A
clause whose tail is not a well-formed attribute plist is returned as-is,
structure untouched."
          (mapcar (lambda (clause)
                    (if (consp clause)
                        (let* ((old (cdr clause))
                               (new (decknix-sanitise-face-plist old)))
                          (if (eq old new) clause (cons (car clause) new)))
                      clause))
                  spec))

        (defun decknix-sanitise-theme-faces (theme)
          "Drop invalid nil face attributes from THEME, authoritative copy first.
Returns the number of face settings repaired, so a switch that silently
stops finding any is visible rather than assumed fixed."
          (let ((repaired 0)
                (faces nil))
            ;; Copy one: the theme's own settings store.  `enable-theme'
            ;; rebuilds each face's `theme-face' from here, so this is the
            ;; only edit that survives.
            (put theme 'theme-settings
                 (mapcar
                  (lambda (setting)
                    ;; setting is (PROP FACE THEME SPEC)
                    (if (eq (car setting) 'theme-face)
                        (let* ((old (nth 3 setting))
                               (new (decknix-sanitise-face-spec old)))
                          (if (equal old new)
                              setting
                            (setq repaired (1+ repaired))
                            (push (nth 1 setting) faces)
                            (list (nth 0 setting) (nth 1 setting)
                                  (nth 2 setting) new)))
                      setting))
                  (get theme 'theme-settings)))
            ;; Copy two, and then copy three, for the faces just repaired --
            ;; so this session is clean immediately rather than only after
            ;; something re-enables the theme.
            (dolist (face faces)
              (put face 'theme-face
                   (mapcar (lambda (entry)
                             (list (car entry)
                                   (decknix-sanitise-face-spec (cadr entry))))
                           (get face 'theme-face)))
              ;; Guarded by `facep': a theme carries settings for faces whose
              ;; package has not loaded (`window-tool-bar-button-disabled' is
              ;; one here), and `face-spec-recalc' signals "Invalid face" on
              ;; those, aborting the sweep.  A repair that breaks startup is
              ;; worse than the warning it was fixing.  Their spec is still
              ;; fixed, so they come up clean whenever they are defined.
              (when (facep face)
                (face-spec-recalc face (selected-frame))))
            repaired))

        ;; Load modus-vivendi (high-contrast dark theme), then repair it.
        ;;
        ;; The two are one operation.  `load-theme' runs the theme's own
        ;; `custom-theme-set-faces', which INSTALLS the broken specs and
        ;; APPLIES them in the same breath, so the first burst of warnings is
        ;; emitted before any repair could run.  Measured: 14 warnings from
        ;; the `load-theme' call, then 0 across three subsequent
        ;; `enable-theme's once repaired.
        ;;
        ;; So the log is quietened for the duration of that one call only.
        ;; `inhibit-message' alone would still write to *Messages*; suppressing
        ;; the log needs `message-log-max' nil as well.  Deliberately narrow:
        ;; it covers a single form whose only expected output is this warning,
        ;; and `load-theme' reports real problems by signalling rather than by
        ;; messaging, so a genuine failure still surfaces.
        (let ((inhibit-message t)
              (message-log-max nil))
          (load-theme 'modus-vivendi t)
          (decknix-sanitise-theme-faces 'modus-vivendi))

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
          ;; The LOW threshold matters as much as the high one, and was
          ;; left at the Emacs default of 800 KB.  gcmh raises the
          ;; threshold from `pre-command-hook' and drops it on idle, so
          ;; anything allocating OUTSIDE the command loop -- timers --
          ;; runs at 800 KB and collects constantly.
          ;;
          ;; Measured 2026-09-22 with `profiler-start' while typing felt
          ;; laggy, over a 12s sample:
          ;;
          ;;     38%  timer-event-handler
          ;;     33%  Automatic GC          <- at the 800 KB threshold
          ;;     25%  redisplay_internal
          ;;
          ;; A third of the CPU went on collections nobody asked for, and
          ;; `gc-elapsed' reached 754s over one session.  This is a
          ;; timer-heavy Emacs -- sidebar ticks, header ticks, agent
          ;; heartbeats -- so the idle threshold is in force most of the
          ;; time, not the work one.
          ;;
          ;; 64 MB still reclaims on idle (gcmh collects explicitly via
          ;; `gcmh-idle-garbage-collect'); it only stops the per-800 KB
          ;; thrash between those reclaims.
          (setq gcmh-high-cons-threshold (* 512 1024 1024)  ; 512 MB during work
                gcmh-low-cons-threshold  (* 64 1024 1024)   ; 64 MB between commands
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

