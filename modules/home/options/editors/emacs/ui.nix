{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.ui;
in
{
  options.programs.emacs.decknix.ui = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable UI enhancements (which-key, helpful, nerd-icons).";
    };

    icons.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable all-the-icons for file icons in completion and dired.";
    };

    macosShortcuts = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Enable standard macOS keyboard shortcuts (Cmd+C/V/X/W/Q/A/S/Z).
          Makes Emacs more accessible for newcomers from other macOS apps.
        '';
      };
    };

    frame = {
      centerOnStartup = mkOption {
        type = types.bool;
        default = true;
        description = "Center the Emacs frame on screen at startup.";
      };

      width = mkOption {
        type = types.int;
        default = 120;
        description = "Default frame width in columns.";
      };

      height = mkOption {
        type = types.int;
        default = 50;
        description = "Default frame height in lines.";
      };

      maxWidthPercent = mkOption {
        type = types.int;
        default = 85;
        description = "Maximum frame width as percentage of screen width.";
      };

      maxHeightPercent = mkOption {
        type = types.int;
        default = 85;
        description = "Maximum frame height as percentage of screen height.";
      };
    };
  };

  config = mkIf cfg.enable {
    programs.emacs = {
      extraPackages = epkgs: with epkgs; [
        which-key         # Show available keybindings
        helpful           # Better *help* buffers
      ] ++ (optionals cfg.icons.enable [
        all-the-icons             # Icons (auto-installs fonts)
        all-the-icons-completion  # Icons in minibuffer completion
        all-the-icons-dired       # Icons in dired
      ]);

      extraConfig = ''
        ;;; UI Enhancements

        ;; == macOS keyboard settings ==
        (when (eq system-type 'darwin)
          ;; Ensure right-option is available for special characters (€, £, ©, etc.)
          (when (boundp 'ns-right-alternate-modifier)
            (setq ns-right-alternate-modifier 'none))
          (when (boundp 'mac-right-option-modifier)
            (setq mac-right-option-modifier 'none))

          ;; === emacs-mac port specific settings ===
          (when (boundp 'mac-option-modifier)
            (setq mac-option-modifier 'meta)         ; Option = Meta
            (setq mac-command-modifier 'super)       ; Command = Super
            (setq mac-control-modifier 'control)     ; Control = Control
            ;; Enable pixel-based scrolling for smoother experience
            (setq mac-mouse-wheel-smooth-scroll t))

          ;; === Standard NS Emacs settings (fallback) ===
          (when (and (boundp 'ns-command-modifier)
                     (not (boundp 'mac-option-modifier)))
            (setq ns-command-modifier 'super)
            (setq ns-option-modifier 'meta)
            (setq ns-control-modifier 'control)))

        ${optionalString cfg.frame.centerOnStartup ''
        ;; == Frame sizing and centering ==
        (defun decknix-center-frame ()
          "Center the frame on screen with appropriate size for the welcome screen."
          (let* ((screen-width (display-pixel-width))
                 (screen-height (display-pixel-height))
                 ;; Calculate max dimensions based on screen percentage
                 (max-width-px (/ (* screen-width ${toString cfg.frame.maxWidthPercent}) 100))
                 (max-height-px (/ (* screen-height ${toString cfg.frame.maxHeightPercent}) 100))
                 ;; Get character dimensions
                 (char-width (frame-char-width))
                 (char-height (frame-char-height))
                 ;; Calculate desired size in pixels
                 (desired-width-px (* ${toString cfg.frame.width} char-width))
                 (desired-height-px (* ${toString cfg.frame.height} char-height))
                 ;; Use smaller of desired or max
                 (frame-width-px (min desired-width-px max-width-px))
                 (frame-height-px (min desired-height-px max-height-px))
                 ;; Convert back to characters for set-frame-size
                 (frame-cols (/ frame-width-px char-width))
                 (frame-rows (/ frame-height-px char-height))
                 ;; Calculate centered position
                 (left (/ (- screen-width frame-width-px) 2))
                 (top (/ (- screen-height frame-height-px) 2)))
            ;; Apply size and position
            (set-frame-size (selected-frame) frame-cols frame-rows)
            (set-frame-position (selected-frame) left top)))

        ;; Center frame on startup
        (add-hook 'emacs-startup-hook #'decknix-center-frame)
        ''}
        ;; == Which-key: Show available keybindings ==
        (which-key-mode 1)
        (setq which-key-idle-delay 0.3
              which-key-idle-secondary-delay 0.05
              which-key-popup-type 'side-window
              which-key-side-window-location 'bottom
              which-key-side-window-max-height 0.25
              which-key-max-display-columns nil
              which-key-min-display-lines 5
              which-key-separator " → "
              which-key-prefix-prefix "+"
              which-key-show-early-on-C-h t
              which-key-sort-order 'which-key-key-order-alpha)

        ;; Custom prefix descriptions
        (which-key-add-key-based-replacements
          "C-c p" "cape/project"
          "C-c !" "flycheck"
          "C-c Y" "yasnippet"
          "C-x p" "project"
          "C-x r" "register/bookmark"
          "M-g" "goto"
          "M-s" "search")

        ;; == Helpful: Better help buffers ==
        ;; Replace standard help commands with helpful versions
        (global-set-key [remap describe-function] 'helpful-callable)
        (global-set-key [remap describe-variable] 'helpful-variable)
        (global-set-key [remap describe-key] 'helpful-key)
        (global-set-key [remap describe-command] 'helpful-command)
        (global-set-key [remap describe-symbol] 'helpful-symbol)

        ;; Additional helpful bindings
        (global-set-key (kbd "C-h F") 'helpful-function)  ; Actual functions only
        (global-set-key (kbd "C-h C") 'helpful-command)   ; Interactive commands
        (global-set-key (kbd "C-c C-d") 'helpful-at-point)

        ;; Make helpful buffers pop up in a side window
        (setq helpful-switch-buffer-function
              (lambda (buf) (pop-to-buffer buf '(display-buffer-in-side-window))))
      ''
      + optionalString cfg.icons.enable ''

        ;; == All The Icons ==
        ;; Auto-install fonts if not present (first run only)
        (when (and (display-graphic-p)
                   (not (member "all-the-icons" (font-family-list))))
          (all-the-icons-install-fonts t))

        ;; Enable icons in minibuffer completion (Vertico/Marginalia)
        (add-hook 'marginalia-mode-hook #'all-the-icons-completion-marginalia-setup)
        (all-the-icons-completion-mode 1)

        ;; Enable icons in dired
        (add-hook 'dired-mode-hook #'all-the-icons-dired-mode)
      ''
      + optionalString (cfg.macosShortcuts.enable && pkgs.stdenv.isDarwin) ''

        ;; == Standard macOS Keyboard Shortcuts ==
        ;; Makes Emacs more accessible for users coming from other macOS apps
        ;; Command key is mapped to 'super' (s-)

        ;; Editing shortcuts
        (global-set-key (kbd "s-c") 'kill-ring-save)        ; Cmd+C = Copy
        (global-set-key (kbd "s-v") 'yank)                   ; Cmd+V = Paste
        (global-set-key (kbd "s-x") 'kill-region)            ; Cmd+X = Cut
        (global-set-key (kbd "s-z") 'undo-fu-only-undo)      ; Cmd+Z = Undo
        (global-set-key (kbd "s-Z") 'undo-fu-only-redo)      ; Cmd+Shift+Z = Redo
        (global-set-key (kbd "s-a") 'mark-whole-buffer)      ; Cmd+A = Select All
        (global-set-key (kbd "s-s") 'save-buffer)            ; Cmd+S = Save
        (global-set-key (kbd "s-S") 'write-file)             ; Cmd+Shift+S = Save As

        ;; Window/frame management
        (defun decknix-close-window-or-frame ()
          "Close the current window if split exists, otherwise close the frame."
          (interactive)
          (if (> (count-windows) 1)
              (delete-window)
            (delete-frame)))

        (global-set-key (kbd "M-o") 'ace-window)              ; M-o = ace-window (quick switch)
        (global-set-key (kbd "s-t") 'split-window-right)     ; Cmd+T = Split window right
        (global-set-key (kbd "s-T") 'split-window-below)     ; Cmd+Shift+T = Split below
        (global-set-key (kbd "s-w") 'decknix-close-window-or-frame) ; Cmd+W = Close window/frame
        (global-set-key (kbd "s-W") 'delete-frame)           ; Cmd+Shift+W = Close frame (force)
        (global-set-key (kbd "s-q") 'save-buffers-kill-emacs) ; Cmd+Q = Quit
        (global-set-key (kbd "s-n") 'make-frame-command)     ; Cmd+N = New frame

        ;; Search/Find
        (global-set-key (kbd "s-f") 'consult-line)           ; Cmd+F = Find (in buffer)
        (global-set-key (kbd "s-F") 'consult-ripgrep)        ; Cmd+Shift+F = Find in project
        (global-set-key (kbd "s-g") 'consult-line)           ; Cmd+G = Find next (same as find)

        ;; Open/Navigation
        (global-set-key (kbd "s-o") 'find-file)              ; Cmd+O = Open file
        (global-set-key (kbd "s-p") 'project-find-file)      ; Cmd+P = Quick open (project file)
        (global-set-key (kbd "s-b") 'consult-buffer)         ; Cmd+B = Switch buffer
        (global-set-key (kbd "s-,") 'customize)              ; Cmd+, = Preferences

        ;; Font size (zoom)
        (global-set-key (kbd "s-=") 'text-scale-increase)    ; Cmd+= = Zoom in
        (global-set-key (kbd "s--") 'text-scale-decrease)    ; Cmd+- = Zoom out
        (global-set-key (kbd "s-0") 'text-scale-adjust)      ; Cmd+0 = Reset zoom

        ;; == Update menu bar to show macOS shortcuts ==
        ;; == Update menu bar to show both Emacs and macOS shortcuts ==
        ;; Format: "C-x C-s  │   ⌘ S" (Emacs binding │ Apple logo ⌘ Key)

        (defvar decknix-macos-menu-shortcuts
          '((menu-bar-file-menu
             ;; File menu - based on Pages/TextEdit/Xcode conventions
             (new-file . " ⌘ N")           ; Visit New File...
             (open-file . " ⌘ O")          ; Open File...
             (dired . " ⌘ ⇧ O")            ; Open Directory...
             (save-buffer . " ⌘ S")        ; Save
             (write-file . " ⌘ ⇧ S")       ; Save As...
             (revert-buffer . " ⌘ U")      ; Revert Buffer
             (recover-session . " ⌘ ⇧ R")  ; Recover Crashed Session
             (insert-file . " ⌘ ⇧ V")      ; Insert File... (like Paste Special)
             (make-frame . " ⌘ ⇧ N")       ; New Frame (New Window in Xcode)
             (delete-frame . " ⌘ ⇧ W")     ; Delete Frame (Close Window variant)
             (delete-this-frame . " ⌘ ⇧ W") ; Delete Frame alternate key
             (make-tab . " ⌘ T")           ; New Tab (standard macOS)
             (close-tab . " ⌘ W")          ; Close Tab
             (print-buffer . " ⌘ P")       ; Print
             (exit-emacs . " ⌘ Q"))        ; Quit
            (menu-bar-edit-menu
             ;; Edit menu - based on Pages/TextEdit/Xcode conventions
             (undo . " ⌘ Z")               ; Undo
             (redo . " ⌘ ⇧ Z")             ; Redo
             (cut . " ⌘ X")                ; Cut
             (copy . " ⌘ C")               ; Copy
             (paste . " ⌘ V")              ; Paste
             (paste-from-menu . " ⌘ ⌥ ⇧ V") ; Paste Special
             (clear . " ⌫")                ; Delete/Clear
             (select-all . " ⌘ A")         ; Select All
             (search . " ⌘ F")             ; Search submenu / Find
             (replace . " ⌘ ⌥ F")          ; Find and Replace (Xcode style)
             (goto . " ⌘ L")               ; Go to Line (standard IDE)
             (fill . " ⌘ ⌥ Q")             ; Fill/Reflow paragraph
             (spell . " ⌘ ;"))             ; Check Spelling
            (menu-bar-options-menu
             ;; Options menu
             (highlight-paren-mode . " ⌘ ⇧ P")  ; Highlight Matching Parens
             (blink-cursor-mode . " ⌘ ⌥ C")    ; Blink Cursor Mode
             (save-place-mode . " ⌘ ⌥ S"))     ; Save Place Mode
            (menu-bar-buffer-menu
             ;; Buffer menu
             (next-buffer . " ⌘ }")        ; Next Buffer (like Pages next tab)
             (previous-buffer . " ⌘ {")    ; Previous Buffer
             (select-named-buffer . " ⌘ B") ; Select Buffer
             (list-all-buffers . " ⌘ ⌥ B")) ; List Buffers
            (menu-bar-tools-menu
             ;; Tools menu
             (compile . " ⌘ B")            ; Build/Compile (Xcode style)
             (shell . " ⌘ ⌥ T")            ; Terminal/Shell
             (gdb . " ⌘ ⌥ D")              ; Debugger
             (eshell . " ⌘ ⌥ E")           ; Eshell
             (calendar . " ⌘ ⌥ K")         ; Calendar
             (compose-mail . " ⌘ ⌥ M"))    ; Compose Mail
            (menu-bar-showhide-menu
             ;; Show/Hide menu
             (showhide-tool-bar . " ⌘ ⌥ T")   ; Tool Bar
             (showhide-scroll-bar . " ⌘ ⌥ R") ; Scroll Bar
             (showhide-fringe . " ⌘ ⌥ G")))   ; Fringe
          "Alist mapping menu items to their macOS shortcuts.
Based on standard macOS conventions from Pages, TextEdit, and Xcode.")

        (defvar decknix-menu-shortcuts-applied nil
          "Whether macOS shortcuts have been applied to menus.")

        (defun decknix-format-menu-keys (emacs-keys macos-key)
          "Format keyboard shortcut string with Emacs binding and macOS shortcut.
Pads the Emacs binding for better alignment."
          (let* ((emacs-str (or emacs-keys ""))
                 ;; Pad Emacs keys to ~12 chars for alignment
                 (padded-emacs (if (< (length emacs-str) 12)
                                   (concat emacs-str (make-string (- 12 (length emacs-str)) ?\s))
                                 emacs-str)))
            (concat padded-emacs " │ " macos-key)))

        (defun decknix-apply-macos-menu-shortcuts ()
          "Apply macOS shortcuts to menu items by replacing :keys property."
          (unless decknix-menu-shortcuts-applied
            (dolist (menu-spec decknix-macos-menu-shortcuts)
              (when (boundp (car menu-spec))
                (let ((menu (symbol-value (car menu-spec))))
                  (when menu
                    (dolist (item-spec (cdr menu-spec))
                      (let* ((key (car item-spec))
                             (macos-key (cdr item-spec))
                             ;; Use assq instead of lookup-key to get full menu-item form
                             (item (cdr (assq key menu))))
                        ;; Only modify full menu-item forms to preserve original labels
                        (when (and item (consp item) (eq (car item) 'menu-item))
                          (let* ((label (nth 1 item))
                                 (command (nth 2 item))
                                 (binding (where-is-internal command nil t))
                                 (emacs-keys (when binding (key-description binding)))
                                 (new-keys (decknix-format-menu-keys emacs-keys macos-key))
                                 (new-props
                                  (let ((props (nthcdr 3 item))
                                        (result nil))
                                    (while props
                                      (unless (eq (car props) :keys)
                                        (push (car props) result)
                                        (when (cdr props)
                                          (push (cadr props) result)))
                                      (setq props (cddr props)))
                                    (nreverse result))))
                            (define-key menu (vector key)
                              `(menu-item ,label ,command :keys ,new-keys ,@new-props))))))))))
            (setq decknix-menu-shortcuts-applied t)))

        ;; Apply on first menu bar update (ensures menus exist)
        (add-hook 'menu-bar-update-hook #'decknix-apply-macos-menu-shortcuts)
      '';
    };
  };
}

