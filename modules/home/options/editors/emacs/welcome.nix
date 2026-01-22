{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.welcome;
in
{
  options.programs.emacs.decknix.welcome = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable decknix welcome screen with keybinding cheat sheet.";
    };

    showRecentFiles = mkOption {
      type = types.bool;
      default = true;
      description = "Show recent files section on welcome screen.";
    };

    showRecentCommands = mkOption {
      type = types.bool;
      default = true;
      description = "Show recently used commands section.";
    };

    recentFilesCount = mkOption {
      type = types.int;
      default = 5;
      description = "Number of recent files to show.";
    };

    recentCommandsCount = mkOption {
      type = types.int;
      default = 5;
      description = "Number of recent commands to show.";
    };
  };

  config = mkIf cfg.enable {
    programs.emacs = {
      extraPackages = epkgs: with epkgs; [
        page-break-lines  # For visual separators
      ];

      extraConfig = ''
        ;;; Decknix Welcome Screen - Interactive Cheat Sheet

        (require 'seq)

        (defgroup decknix-welcome nil
          "Decknix welcome screen customization."
          :group 'convenience)

        ;; === Faces ===
        (defface decknix-welcome-title
          '((t :inherit font-lock-keyword-face :height 1.6 :weight bold))
          "Face for the welcome screen title."
          :group 'decknix-welcome)

        (defface decknix-welcome-subtitle
          '((t :inherit font-lock-comment-face :height 1.0))
          "Face for the welcome screen subtitle."
          :group 'decknix-welcome)

        (defface decknix-welcome-heading
          '((t :inherit font-lock-type-face :weight bold))
          "Face for section headings (clickable)."
          :group 'decknix-welcome)

        (defface decknix-welcome-key
          '((t :inherit font-lock-keyword-face :weight bold))
          "Face for keybindings."
          :group 'decknix-welcome)

        (defface decknix-welcome-description
          '((t :inherit font-lock-comment-face))
          "Face for keybinding descriptions."
          :group 'decknix-welcome)

        (defface decknix-welcome-file
          '((t :inherit font-lock-string-face))
          "Face for file paths."
          :group 'decknix-welcome)

        (defface decknix-welcome-feature
          '((t :inherit font-lock-function-name-face :weight bold))
          "Face for feature names."
          :group 'decknix-welcome)

        (defface decknix-welcome-link
          '((t :inherit link))
          "Face for clickable links."
          :group 'decknix-welcome)

        ;; === Buffer names ===
        (defvar decknix-welcome-buffer-name "*decknix*"
          "Name of the welcome buffer.")

        ;; === Logo ===
        ;; Using ASCII art for predictable width across all fonts/terminals
        (defvar decknix-welcome-logo
          '("     _            _          _       "
            "  __| | ___  ____| | __ __  (_)_  __ "
            " / _` |/ _ \\/ __|| |/ //  \\ | \\ \\/ / "
            "| (_| |  __/ (__ |   <| () || |>  <  "
            " \\__,_|\\___|\\___||_|\\_\\\\__/ |_/_/\\_\\ ")
          "ASCII art logo for decknix.")

        ;; === Features ===
        (defvar decknix-welcome-features
          '(("Vertico"    . "Vertical completion UI")
            ("Consult"    . "Enhanced search & navigation")
            ("Marginalia" . "Rich annotations")
            ("Corfu"      . "In-buffer completion")
            ("Embark"     . "Context actions (C-.)")
            ("Magit"      . "Git interface (C-x g)"))
          "Key features included in decknix.")

        ;; === Keybinding categories with full details ===
        ;; Each category has :key (shortcut), :quick (main view), :full (detail view)
        (defvar decknix-welcome-categories
          '(("Navigation & Search"
             :key "1"
             :quick (("C-s" . "Search buffer (consult-line)")
                     ("M-s r" . "Ripgrep project")
                     ("C-x b" . "Switch buffer"))
             :full  (("C-s" . "consult-line - Incremental search with preview")
                     ("M-s r" . "consult-ripgrep - Search project with ripgrep")
                     ("M-s l" . "consult-line - Search lines in buffer")
                     ("M-s L" . "consult-line-multi - Search across buffers")
                     ("M-g g" . "consult-goto-line - Go to line number")
                     ("M-g o" . "consult-outline - Jump to heading/outline")
                     ("M-g i" . "consult-imenu - Jump to symbol/function")
                     ("M-g m" . "consult-mark - Jump to mark")
                     ("M-g k" . "consult-global-mark - Jump to global mark")
                     ("C-x b" . "consult-buffer - Switch buffer with preview")
                     ("C-x 4 b" . "consult-buffer-other-window")
                     ("C-c f" . "consult-recent-file - Open recent file")))

            ("Editing"
             :key "2"
             :quick (("C-/" . "Undo")
                     ("C-?" . "Redo")
                     ("C-x u" . "Visual undo tree"))
             :full  (("C-/" . "undo-fu-only-undo - Undo last change")
                     ("C-?" . "undo-fu-only-redo - Redo last undo")
                     ("C-x u" . "vundo - Visual undo tree browser")
                     ("C-c d" . "crux-duplicate-current-line-or-region")
                     ("C-a" . "crux-move-beginning-of-line - Smart home")
                     ("C-k" . "crux-smart-kill-line - Smart kill")
                     ("M-<up>" . "move-text-up - Move line up")
                     ("M-<down>" . "move-text-down - Move line down")
                     ("C-M-f" . "sp-forward-sexp - Forward s-expression")
                     ("C-M-b" . "sp-backward-sexp - Backward s-expression")
                     ("C-M-k" . "sp-kill-sexp - Kill s-expression")))

            ("Completion & Code"
             :key "3"
             :quick (("TAB" . "Complete at point")
                     ("C-." . "Context actions")
                     ("M-n/p" . "Next/prev error"))
             :full  (("TAB" . "corfu-complete - Trigger completion popup")
                     ("C-." . "embark-act - Context actions menu")
                     ("C-;" . "embark-dwim - Default action")
                     ("C-c y" . "yas-expand - Expand snippet")
                     ("C-c Y n" . "yas-new-snippet - Create snippet")
                     ("C-c Y v" . "yas-visit-snippet-file")
                     ("M-n" . "flycheck-next-error - Next error")
                     ("M-p" . "flycheck-previous-error - Previous error")
                     ("C-c ! l" . "flycheck-list-errors - List all errors")
                     ("C-c ! a" . "consult-flycheck - Browse errors")
                     ("C-c p f" . "cape-file - Complete filename")
                     ("C-c p d" . "cape-dabbrev - Complete from buffer")))

            ("Git (Magit)"
             :key "4"
             :quick (("C-x g" . "Magit status")
                     ("C-x M-g" . "Magit dispatch")
                     ("s / u" . "Stage / unstage"))
             :full  (("C-x g" . "magit-status - Open Magit status buffer")
                     ("C-x M-g" . "magit-dispatch - Magit command menu")
                     ("s" . "magit-stage - Stage file/hunk at point")
                     ("u" . "magit-unstage - Unstage file/hunk")
                     ("c c" . "magit-commit - Create commit")
                     ("c a" . "magit-commit-amend - Amend last commit")
                     ("P p" . "magit-push - Push to remote")
                     ("F p" . "magit-pull - Pull from remote")
                     ("b b" . "magit-checkout - Switch branch")
                     ("b c" . "magit-branch-create - Create branch")
                     ("l l" . "magit-log - Show log")
                     ("d d" . "magit-diff - Show diff")))

            ("Buffers & Windows"
             :key "5"
             :quick (("C-x C-f" . "Find file")
                     ("C-x k" . "Kill buffer")
                     ("C-x 1" . "Delete other windows"))
             :full  (("C-x C-f" . "find-file - Open file")
                     ("C-x C-s" . "save-buffer - Save file")
                     ("C-x k" . "kill-buffer - Close buffer")
                     ("C-x b" . "consult-buffer - Switch buffer")
                     ("C-x 0" . "delete-window - Close current window")
                     ("C-x 1" . "delete-other-windows - Maximize")
                     ("C-x 2" . "split-window-below - Split horizontal")
                     ("C-x 3" . "split-window-right - Split vertical")
                     ("C-x o" . "other-window - Switch window")
                     ("C-x <left>" . "winner-undo - Undo window config")
                     ("C-x <right>" . "winner-redo - Redo window config")))

            ("Help & Discovery"
             :key "6"
             :quick (("C-h f" . "Describe function")
                     ("C-h k" . "Describe key")
                     ("C-h m" . "Describe mode"))
             :full  (("C-h f" . "helpful-callable - Describe function")
                     ("C-h v" . "helpful-variable - Describe variable")
                     ("C-h k" . "helpful-key - Describe key binding")
                     ("C-h m" . "describe-mode - Current mode help")
                     ("C-h ?" . "help-for-help - Help on help")
                     ("C-h B" . "embark-bindings - All bindings")
                     ("C-h C-d" . "helpful-at-point - Help for thing at point")
                     ("C-h F" . "helpful-function - Functions only")
                     ("C-h C" . "helpful-command - Commands only"))))
          "Categories with :key shortcut, :quick (main view), :full (detail view).")

        ;; === Button types ===
        (define-button-type 'decknix-welcome-category-button
          'face 'decknix-welcome-heading
          'follow-link t
          'help-echo "Click to see full cheat sheet"
          'action #'decknix-welcome-show-category)

        (define-button-type 'decknix-welcome-file-button
          'face 'decknix-welcome-file
          'follow-link t
          'help-echo "Click to open file"
          'action #'decknix-welcome-open-file)

        (define-button-type 'decknix-welcome-command-button
          'face 'decknix-welcome-key
          'follow-link t
          'help-echo "Click to run command"
          'action #'decknix-welcome-run-command)

        ;; === Helper functions ===
        (defun decknix-welcome-center-line (text)
          "Return TEXT centered for the current window width.
Uses `string-width' to handle Unicode characters correctly."
          (let* ((width (window-width))
                 (text-width (string-width text))
                 (padding (max 0 (/ (- width text-width) 2))))
            (concat (make-string padding ?\s) text)))

        (defun decknix-welcome-insert-centered (text &optional face)
          "Insert TEXT centered with optional FACE."
          (let ((centered (decknix-welcome-center-line text)))
            (insert (if face (propertize centered 'face face) centered))
            (insert "\n")))

        (defun decknix-welcome-pad-right (str width)
          "Pad STR with spaces on the right to reach WIDTH."
          (let ((len (length str)))
            (if (>= len width)
                str
              (concat str (make-string (- width len) ?\s)))))

        ;; === Category detail view ===
        (defun decknix-welcome-show-category-by-name (category-name)
          "Show full cheat sheet for CATEGORY-NAME."
          (let* ((category (seq-find (lambda (c) (string= (car c) category-name))
                                     decknix-welcome-categories))
                 (full-bindings (plist-get (cdr category) :full))
                 (shortcut-key (plist-get (cdr category) :key))
                 (buf (get-buffer-create (format "*decknix: %s*" category-name))))
            (with-current-buffer buf
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert "\n")
                (insert (propertize (format "  [%s] %s - Full Reference\n" shortcut-key category-name)
                                    'face 'decknix-welcome-title))
                (insert (propertize "  ─────────────────────────────────────────────────\n"
                                    'face 'decknix-welcome-subtitle))
                (insert "\n")
                (dolist (binding full-bindings)
                  (let ((key (car binding))
                        (desc (cdr binding)))
                    (insert "    ")
                    (insert (propertize (decknix-welcome-pad-right key 14) 'face 'decknix-welcome-key))
                    (insert (propertize desc 'face 'decknix-welcome-description))
                    (insert "\n")))
                (insert "\n")
                (insert (propertize "  Press 'q' to close, 'w' to return to welcome screen\n"
                                    'face 'decknix-welcome-subtitle))
                (goto-char (point-min)))
              (decknix-welcome-detail-mode))
            (switch-to-buffer buf)))

        (defun decknix-welcome-show-category (button)
          "Show full cheat sheet for the category in BUTTON."
          (decknix-welcome-show-category-by-name (button-get button 'cat-name)))

        (defun decknix-welcome-show-category-by-key (key)
          "Show category cheat sheet for KEY (1-6)."
          (let ((category (seq-find (lambda (c) (string= (plist-get (cdr c) :key) key))
                                    decknix-welcome-categories)))
            (when category
              (decknix-welcome-show-category-by-name (car category)))))

        (defun decknix-welcome-open-file (button)
          "Open the file in BUTTON."
          (let ((file (button-get button 'file)))
            (find-file file)))

        (defun decknix-welcome-run-command (button)
          "Run the command in BUTTON."
          (let ((cmd (button-get button 'command)))
            (when (commandp cmd)
              (call-interactively cmd))))

        ;; === Render quick section (3 items per category) ===
        (defun decknix-welcome-render-quick-section (category)
          "Render a quick keybinding section for CATEGORY with clickable header."
          (let* ((name (car category))
                 (quick-bindings (plist-get (cdr category) :quick))
                 (result ""))
            ;; Header will be a button - we'll handle that in render
            (setq result (concat result "  "))
            (dolist (binding quick-bindings)
              (let ((key (car binding))
                    (desc (cdr binding)))
                (setq result (concat result
                              "    "
                              (propertize (decknix-welcome-pad-right key 12) 'face 'decknix-welcome-key)
                              (propertize desc 'face 'decknix-welcome-description)
                              "\n"))))
            result))

        ;; === Layout configuration ===
        (defvar decknix-welcome-min-width-for-two-cols 100
          "Minimum window width to use two-column layout.")

        (defvar decknix-welcome-col-width 44
          "Width of each column in two-column layout.")

        (defun decknix-welcome-use-two-columns-p ()
          "Return t if window is wide enough for two columns."
          (>= (window-width) decknix-welcome-min-width-for-two-cols))

        ;; === Render single category (for single-column layout) ===
        (defun decknix-welcome-render-category-single (category col-offset)
          "Render a single CATEGORY at COL-OFFSET for single-column layout."
          (let* ((name (car category))
                 (shortcut (plist-get (cdr category) :key))
                 (quick-bindings (plist-get (cdr category) :quick)))
            ;; Header
            (insert (make-string col-offset ?\s))
            (insert (propertize (format "[%s] " shortcut) 'face 'decknix-welcome-key))
            (insert-text-button name
                                'type 'decknix-welcome-category-button
                                'cat-name name)
            (insert " ▸\n")
            ;; Bindings
            (dolist (binding quick-bindings)
              (insert (make-string col-offset ?\s))
              (insert "    ")
              (insert (propertize (decknix-welcome-pad-right (car binding) 12)
                                  'face 'decknix-welcome-key))
              (insert (propertize (cdr binding) 'face 'decknix-welcome-description))
              (insert "\n"))
            (insert "\n")))

        ;; === Main render function ===
        (defun decknix-welcome-render ()
          "Render the welcome buffer content with interactive elements."
          (let ((inhibit-read-only t)
                (win-width (window-width)))
            (erase-buffer)

            ;; Add some top padding
            (insert "\n")

            ;; Insert logo
            (dolist (line decknix-welcome-logo)
              (decknix-welcome-insert-centered line 'decknix-welcome-title))

            ;; Title
            (decknix-welcome-insert-centered "Welcome to Decknix Emacs" 'decknix-welcome-title)
            (decknix-welcome-insert-centered "A modern, batteries-included configuration" 'decknix-welcome-subtitle)
            (insert "\n")

            ;; Feature highlights
            (let ((features-line ""))
              (dolist (feature decknix-welcome-features)
                (setq features-line
                      (concat features-line
                              (propertize (car feature) 'face 'decknix-welcome-feature)
                              " • ")))
              (setq features-line (substring features-line 0 -3))  ; Remove trailing " • "
              (decknix-welcome-insert-centered features-line))
            (insert "\n")

            ;; Render keybindings - responsive layout
            (if (decknix-welcome-use-two-columns-p)
                ;; Two-column layout for wide windows
                (let* ((categories decknix-welcome-categories)
                       (left-cats (seq-take categories 3))
                       (right-cats (seq-drop categories 3))
                       (col-width decknix-welcome-col-width)
                       (total-content-width (+ col-width col-width 4))  ; Two columns + gap
                       (col-offset (max 2 (/ (- win-width total-content-width) 2))))

                  ;; Process each row (pair of left and right categories)
                  (dotimes (row 3)
                    (let ((left-cat (nth row left-cats))
                          (right-cat (nth row right-cats)))

                      ;; Insert category headers as buttons with shortcut keys
                      (insert (make-string col-offset ?\s))
                      (when left-cat
                        (let ((shortcut (plist-get (cdr left-cat) :key)))
                          (insert (propertize (format "[%s] " shortcut) 'face 'decknix-welcome-key))
                          (insert-text-button (car left-cat)
                                              'type 'decknix-welcome-category-button
                                              'cat-name (car left-cat))
                          (insert " ▸")))
                      (let ((left-header-len (if left-cat (+ 4 (length (car left-cat)) 4) 0)))
                        (insert (make-string (max 1 (- col-width left-header-len)) ?\s)))
                      (when right-cat
                        (let ((shortcut (plist-get (cdr right-cat) :key)))
                          (insert (propertize (format "[%s] " shortcut) 'face 'decknix-welcome-key))
                          (insert-text-button (car right-cat)
                                              'type 'decknix-welcome-category-button
                                              'cat-name (car right-cat))
                          (insert " ▸")))
                      (insert "\n")

                      ;; Insert quick bindings for each category
                      (let ((left-bindings (when left-cat (plist-get (cdr left-cat) :quick)))
                            (right-bindings (when right-cat (plist-get (cdr right-cat) :quick)))
                            (max-bindings 3))
                        (dotimes (i max-bindings)
                          (let ((left-binding (nth i left-bindings))
                                (right-binding (nth i right-bindings)))
                            (insert (make-string col-offset ?\s))
                            ;; Left binding
                            (if left-binding
                                (progn
                                  (insert "    ")
                                  (insert (propertize (decknix-welcome-pad-right (car left-binding) 12)
                                                      'face 'decknix-welcome-key))
                                  (insert (propertize (cdr left-binding) 'face 'decknix-welcome-description)))
                              (insert (make-string col-width ?\s)))
                            (let ((left-content-len (if left-binding
                                                        (+ 4 12 (length (cdr left-binding)))
                                                      0)))
                              (insert (make-string (max 1 (- col-width left-content-len)) ?\s)))
                            ;; Right binding
                            (when right-binding
                              (insert "    ")
                              (insert (propertize (decknix-welcome-pad-right (car right-binding) 12)
                                                  'face 'decknix-welcome-key))
                              (insert (propertize (cdr right-binding) 'face 'decknix-welcome-description)))
                            (insert "\n"))))
                      (insert "\n"))))

              ;; Single-column layout for narrow windows
              (let* ((col-width 48)
                     (col-offset (max 2 (/ (- win-width col-width) 2))))
                (dolist (category decknix-welcome-categories)
                  (decknix-welcome-render-category-single category col-offset))))

            ;; Recent commands section
            (when (and ${boolToString cfg.showRecentCommands}
                       (bound-and-true-p extended-command-history))
              (insert "\n")
              (decknix-welcome-insert-centered "─────────── Recent Commands ───────────" 'decknix-welcome-subtitle)
              (let* ((cmds (seq-take (seq-uniq extended-command-history) ${toString cfg.recentCommandsCount}))
                     (max-cmd-len (apply #'max (mapcar #'length cmds)))
                     (content-width (+ 2 max-cmd-len))
                     (col-offset (max 2 (/ (- win-width content-width) 2))))
                (dolist (cmd cmds)
                  (let ((sym (intern-soft cmd)))
                    (insert (make-string col-offset ?\s))
                    (if (and sym (commandp sym))
                        (insert-text-button cmd
                                            'type 'decknix-welcome-command-button
                                            'command sym)
                      (insert (propertize cmd 'face 'decknix-welcome-key)))
                    (insert "\n")))))

            ;; Recent files section
            (when (and ${boolToString cfg.showRecentFiles} (bound-and-true-p recentf-list))
              (insert "\n")
              (decknix-welcome-insert-centered "─────────── Recent Files ───────────" 'decknix-welcome-subtitle)
              (let* ((files (seq-take recentf-list ${toString cfg.recentFilesCount}))
                     (max-display-len 65)
                     (content-width (min max-display-len (- win-width 10)))
                     (col-offset (max 2 (/ (- win-width content-width) 2))))
                (dolist (file files)
                  (let* ((short-file (abbreviate-file-name file))
                         (display (if (> (length short-file) content-width)
                                      (concat "..." (substring short-file (- 3 content-width)))
                                    short-file)))
                    (insert (make-string col-offset ?\s))
                    (insert-text-button display
                                        'type 'decknix-welcome-file-button
                                        'file file)
                    (insert "\n")))))

            ;; Footer
            (insert "\n")
            (decknix-welcome-insert-centered "Press 1-6 for full cheat sheets • r refresh • q quit" 'decknix-welcome-subtitle)
            (decknix-welcome-insert-centered "C-h ? help • C-x b buffers • C-x C-f files • C-c w this screen" 'decknix-welcome-subtitle)

            (goto-char (point-min))))

        ;; === Detail mode for category cheat sheets ===
        (define-derived-mode decknix-welcome-detail-mode special-mode "Decknix-Detail"
          "Major mode for decknix category detail buffers."
          :group 'decknix-welcome
          (setq buffer-read-only t
                cursor-type nil
                truncate-lines t))

        (define-key decknix-welcome-detail-mode-map (kbd "q") 'kill-buffer-and-window)
        (define-key decknix-welcome-detail-mode-map (kbd "w") 'decknix-welcome-open)

        ;; === Main welcome mode ===
        (define-derived-mode decknix-welcome-mode special-mode "Decknix"
          "Major mode for the decknix welcome screen."
          :group 'decknix-welcome
          (setq buffer-read-only t
                cursor-type nil
                truncate-lines t)
          (when (fboundp 'page-break-lines-mode)
            (page-break-lines-mode 1)))

        ;; Category shortcut keybindings (1-6)
        (define-key decknix-welcome-mode-map (kbd "1")
          (lambda () (interactive) (decknix-welcome-show-category-by-key "1")))
        (define-key decknix-welcome-mode-map (kbd "2")
          (lambda () (interactive) (decknix-welcome-show-category-by-key "2")))
        (define-key decknix-welcome-mode-map (kbd "3")
          (lambda () (interactive) (decknix-welcome-show-category-by-key "3")))
        (define-key decknix-welcome-mode-map (kbd "4")
          (lambda () (interactive) (decknix-welcome-show-category-by-key "4")))
        (define-key decknix-welcome-mode-map (kbd "5")
          (lambda () (interactive) (decknix-welcome-show-category-by-key "5")))
        (define-key decknix-welcome-mode-map (kbd "6")
          (lambda () (interactive) (decknix-welcome-show-category-by-key "6")))
        (define-key decknix-welcome-mode-map (kbd "r") 'decknix-welcome-refresh)
        (define-key decknix-welcome-mode-map (kbd "q") 'quit-window)

        (defun decknix-welcome-open ()
          "Open or switch to the decknix welcome buffer."
          (interactive)
          (let ((buf (get-buffer-create decknix-welcome-buffer-name)))
            (switch-to-buffer buf)
            (unless (eq major-mode 'decknix-welcome-mode)
              (decknix-welcome-mode))
            (decknix-welcome-render)))

        (defun decknix-welcome-refresh ()
          "Refresh the welcome screen content."
          (interactive)
          (when (string= (buffer-name) decknix-welcome-buffer-name)
            (decknix-welcome-render)))

        ;; Show welcome screen on startup (unless files are passed)
        (add-hook 'emacs-startup-hook
                  (lambda ()
                    (when (and (not (member "-q" command-line-args))
                               (not (member "--no-splash" command-line-args))
                               (= (length command-line-args) 1))
                      (decknix-welcome-open))))

        ;; Keybinding to open welcome screen
        (global-set-key (kbd "C-c w") 'decknix-welcome-open)

        ;; Refresh on window resize
        (add-hook 'window-configuration-change-hook
                  (lambda ()
                    (when (string= (buffer-name) decknix-welcome-buffer-name)
                      (decknix-welcome-render))))
      '';
    };
  };
}

