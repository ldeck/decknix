{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.org;
in
{
  options.programs.emacs.decknix.org = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable org-mode enhancements for presentations and beautiful documents.";
    };

    presentation = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable org-tree-slide for interactive presentations.";
      };

      textScale = mkOption {
        type = types.int;
        default = 5;
        description = "Text scale increase during presentations (0-8). Default 5 for Keynote-like size.";
      };

      fullscreen = mkOption {
        type = types.bool;
        default = true;
        description = "Automatically enter fullscreen when starting presentation.";
      };
    };

    modern = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable org-modern for beautiful org styling.";
      };
    };
  };

  config = mkIf cfg.enable {
    programs.emacs = {
      extraPackages = epkgs: with epkgs; [
        org-modern            # Beautiful org styling (bullets, checkboxes, tables)
        visual-fill-column    # Centered text for presentations
        mixed-pitch           # Variable pitch for prose, fixed for code
      ] ++ (optionals cfg.presentation.enable [
        org-present           # Clean presentation mode (better than org-tree-slide)
      ]);

      extraConfig = ''
        ;;; Org-mode Enhancements

        ;; == Org-modern: Beautiful org documents ==
        (with-eval-after-load 'org
          ;; Enable org-modern globally in org buffers
          (global-org-modern-mode 1)

          ;; Org-modern settings for beautiful rendering
          (setq org-modern-star '("◉" "○" "●" "○" "●" "○")
                org-modern-list '((?- . "•") (?+ . "◦") (?* . "‣"))
                org-modern-checkbox '((?X . "☑") (?- . "☐") (?\s . "☐"))
                org-modern-table t
                org-modern-table-vertical 1
                org-modern-table-horizontal 0.2
                org-modern-block-fringe nil
                org-modern-tag t
                org-modern-priority t
                org-modern-todo t
                org-modern-keyword t)

          ;; Hide emphasis markers for cleaner look
          (setq org-hide-emphasis-markers t)

          ;; Fold source blocks and drawers by default
          (setq org-hide-block-startup t
                org-startup-folded 'content)  ; Show headings, hide content

          ;; Better bullet indentation
          (setq org-indent-mode-turns-on-hiding-stars nil
                org-indent-indentation-per-level 2)

          ;; Enable org-indent for cleaner structure
          (add-hook 'org-mode-hook #'org-indent-mode)

          ;; Checkbox statistics - update parent when children change
          (setq org-checkbox-hierarchical-statistics t)

          ;; Better table formatting - use fixed-pitch font for alignment
          (set-face-attribute 'org-table nil :inherit 'fixed-pitch)

          ;; Ensure tables use a monospace font for proper column alignment
          (add-hook 'org-mode-hook
                    (lambda ()
                      (face-remap-add-relative 'org-table :family "Menlo"))))

      '' + optionalString cfg.presentation.enable ''

        ;; == Org-present: Beautiful presentation mode ==
        ;; Inspired by System Crafters: https://systemcrafters.net/emacs-tips/presentations-with-org-present/

        ;; Store pre-presentation state
        (defvar decknix-presentation--saved-state nil
          "Saved state before presentation started.")
        (defvar-local decknix-presentation--focus-mode nil
          "Whether focus mode is enabled (shows only current item).")
        (defvar-local decknix-presentation--on-title-page nil
          "Whether we're on the title page (before first heading).")

        ;; Keybinding to start presentation
        (with-eval-after-load 'org
          (define-key org-mode-map (kbd "<f5>") #'org-present)
          (define-key org-mode-map (kbd "C-c p") #'org-present))

        ;; Hide DECKNIX_ keywords during presentation
        (defun decknix-presentation-hide-keywords ()
          "Hide #+DECKNIX_* keywords in the buffer."
          (save-excursion
            (goto-char (point-min))
            (while (re-search-forward "^#\\+DECKNIX_[^:]+:.*$" nil t)
              (let ((ov (make-overlay (match-beginning 0) (1+ (match-end 0)))))
                (overlay-put ov 'invisible t)
                (overlay-put ov 'decknix-keyword t)))))

        (defun decknix-presentation-show-keywords ()
          "Show #+DECKNIX_* keywords again."
          (remove-overlays (point-min) (point-max) 'decknix-keyword t))

        ;;; ============================================================
        ;;; ORG DOCUMENT OPTIONS FOR PRESENTATION
        ;;; Use in your org file:
        ;;;   #+DECKNIX_SHOW_TITLE: t       (show title in header)
        ;;;   #+DECKNIX_SHOW_SLIDE_NUM: t   (show slide X/Y in bottom right)
        ;;;   #+DECKNIX_THEME: modus-vivendi (theme is already modus-vivendi by default)
        ;;; ============================================================

        ;; Presentation state - cached at start before buffer narrowing
        (defvar-local decknix-presentation--show-title nil
          "Whether to show the document title in the header during presentation.")
        (defvar-local decknix-presentation--show-slide-num nil
          "Whether to show slide number in bottom right during presentation.")
        (defvar-local decknix-presentation--doc-title nil
          "Cached document title for the presentation.")
        (defvar-local decknix-presentation--total-slides 0
          "Cached total number of slides.")
        (defvar-local decknix-presentation--slide-num-overlay nil
          "Overlay for displaying slide number in bottom right corner.")

        (defun decknix-presentation-get-option (key &optional default)
          "Get presentation option KEY from org file, or return DEFAULT.
Looks for #+DECKNIX_KEY: value in the document."
          (save-excursion
            (save-restriction
              (widen)
              (goto-char (point-min))
              (let ((pattern (format "^#\\+DECKNIX_%s:[ \t]*\\(.+\\)$" (upcase key))))
                (if (re-search-forward pattern nil t)
                    (let ((val (string-trim (match-string 1))))
                      (cond ((string= val "t") t)
                            ((string= val "nil") nil)
                            (t val)))
                  default)))))

        (defun decknix-presentation-maybe-load-theme ()
          "Load theme specified in org file if present."
          (let ((theme (decknix-presentation-get-option "THEME" nil)))
            (when (and theme (not (string-empty-p theme)))
              (let ((theme-sym (intern theme)))
                (unless (eq theme-sym (car custom-enabled-themes))
                  (load-theme theme-sym t))))))

        (defun decknix-presentation-cache-info ()
          "Cache presentation info before buffer gets narrowed.
Must be called at presentation start while buffer is still widened."
          ;; Cache the document title
          (setq decknix-presentation--doc-title
                (or (org-get-title) (buffer-name)))
          ;; Count total slides (top-level headings only)
          (setq decknix-presentation--total-slides
                (save-excursion
                  (goto-char (point-min))
                  (let ((count 0))
                    (while (re-search-forward "^\\* " nil t)
                      (setq count (1+ count)))
                    (max count 1)))))

        ;;; ============================================================
        ;;; TITLE HEADER - Shows document title throughout presentation
        ;;; ============================================================

        (defun decknix-presentation-current-slide ()
          "Get current slide number by finding position in widened buffer.
Also sets `decknix-presentation--on-title-page' as a side effect."
          (let ((narrowed-start (point-min)))
            (save-excursion
              (save-restriction
                (widen)
                ;; Check if we're before the first heading (title page)
                (goto-char (point-min))
                (let ((first-heading-pos (when (re-search-forward "^\\* " nil t)
                                           (line-beginning-position))))
                  (setq decknix-presentation--on-title-page
                        (or (null first-heading-pos)
                            (< narrowed-start first-heading-pos))))
                ;; Find which top-level heading contains our narrowed region
                (goto-char (point-min))
                (let ((count 0)
                      (target narrowed-start))
                  (while (and (re-search-forward "^\\* " nil t)
                              (<= (line-beginning-position) target))
                    (setq count (1+ count)))
                  (max count 1))))))

        (defun decknix-presentation-build-header ()
          "Build header line showing document title and page numbers.
On the title page, returns just spacing (no duplicate title)."
          ;; Update title page status
          (decknix-presentation-current-slide)
          ;; On title page, just show spacing - the title is already displayed
          (if decknix-presentation--on-title-page
              " "
            (let* ((title (or decknix-presentation--doc-title "Presentation"))
                   (current (decknix-presentation-current-slide))
                   (total decknix-presentation--total-slides)
                   (page-str (format " %d / %d " current total))
                   (title-str (concat "  " title))
                   (available-width (- (window-body-width)
                                       (length title-str)
                                       (length page-str) 4)))
              (concat
               (propertize title-str 'face '(:inherit shadow :height 0.6))
               (propertize (make-string (max 1 available-width) ?\s) 'face 'default)
               (propertize page-str 'face '(:inherit shadow :height 0.6))
               "  "))))

        (defun decknix-presentation-update-header ()
          "Update the header line format based on current settings."
          (setq header-line-format
                (if decknix-presentation--show-title
                    '(:eval (decknix-presentation-build-header))
                  " "))
          (force-mode-line-update))

        (defun decknix-presentation-toggle-title ()
          "Toggle display of document title in the presentation header.
Use H during presentation to toggle."
          (interactive)
          (setq decknix-presentation--show-title
                (not decknix-presentation--show-title))
          (decknix-presentation-update-header)
          (message "Header: %s"
                   (if decknix-presentation--show-title "showing title" "hidden")))

        ;;; ============================================================
        ;;; SLIDE NUMBER - Mode-line with hierarchical breadcrumb
        ;;; ============================================================

        (defun decknix-presentation--count-siblings-at-level (target-heading-pos)
          "Count siblings at the same level as TARGET-HEADING-POS and return (current . total)."
          (save-excursion
            (goto-char target-heading-pos)
            (let* ((level (org-current-level))
                   (current 0)
                   (total 0))
              ;; Go to first sibling by going up to parent then down
              (if (> level 1)
                  (progn
                    (outline-up-heading 1 t)
                    (org-fold-show-children)
                    ;; Move to first child
                    (outline-next-heading))
                ;; Already at top level, go to beginning
                (goto-char (point-min))
                (unless (org-at-heading-p)
                  (outline-next-heading)))
              ;; Count all siblings at this level
              (while (and (org-at-heading-p)
                          (= (org-current-level) level))
                (setq total (1+ total))
                (when (<= (point) target-heading-pos)
                  (setq current total))
                (unless (outline-get-next-sibling)
                  (goto-char (point-max))))  ; Exit loop
              (cons current total))))

        (defun decknix-presentation--get-heading-hierarchy ()
          "Get the current heading's position at each level of hierarchy.
Returns a list of (current . total) pairs from level 2 down to current level."
          (when (org-at-heading-p)
            (let* ((current-level (org-current-level))
                   (result '())
                   (original-pos (point)))
              ;; Start from current position, work up to level 2
              (save-excursion
                (let ((pos original-pos))
                  ;; Collect position info from current level up to level 2
                  (while (and (org-at-heading-p)
                              (> (org-current-level) 1))
                    (let* ((level (org-current-level))
                           (counts (decknix-presentation--count-siblings-at-level (point))))
                      (push counts result)
                      ;; Go up one level
                      (condition-case nil
                          (outline-up-heading 1 t)
                        (error (goto-char (point-min))))))))
              result)))

        (defun decknix-presentation-build-mode-line ()
          "Build hierarchical breadcrumb display for mode-line.
Format: ❱ 2 of 5 ❱❱ 1 of 3 ❱❱❱ 2 of 4"
          (if decknix-presentation--on-title-page
              ""  ; Empty on title page
            (let* ((slide (decknix-presentation-current-slide))
                   (total-slides decknix-presentation--total-slides)
                   (positions (decknix-presentation--get-heading-hierarchy))
                   (parts (list (format "❱ %d of %d" slide total-slides))))
              ;; Add each level of the hierarchy with increasing ❱ symbols
              (dotimes (i (length positions))
                (let* ((pos-pair (nth i positions))
                       (current (car pos-pair))
                       (total (cdr pos-pair))
                       ;; Level 0 = ❱❱, level 1 = ❱❱❱, etc
                       (prefix (make-string (+ 2 i) ?❱)))
                  (when (and (> current 0) (> total 0))
                    (push (format "%s %d of %d" prefix current total) parts))))
              (string-join (nreverse parts) " "))))

        (defun decknix-presentation-update-slide-num ()
          "Update slide number in mode-line.
Hidden on title page since slide 0 doesn't make sense."
          ;; Update mode-line with hierarchical breadcrumb
          (when (and decknix-presentation--show-slide-num
                     (not decknix-presentation--on-title-page))
            (setq mode-line-format
                  '(:eval (concat
                           (propertize " " 'display '(space :align-to 0))
                           (propertize (decknix-presentation-build-mode-line)
                                       'face '(:inherit shadow :height 0.9))))))
          (when (or (not decknix-presentation--show-slide-num)
                    decknix-presentation--on-title-page)
            (setq mode-line-format nil))
          (force-mode-line-update))

        (defun decknix-presentation-remove-slide-num ()
          "Hide slide number display."
          (setq mode-line-format nil)
          (force-mode-line-update))

        (defun decknix-presentation-toggle-slide-num ()
          "Toggle display of slide number.
Use S during presentation to toggle."
          (interactive)
          (setq decknix-presentation--show-slide-num
                (not decknix-presentation--show-slide-num))
          (decknix-presentation-update-slide-num)
          (message "Slide number: %s"
                   (if decknix-presentation--show-slide-num "visible" "hidden")))

        ;;; ============================================================
        ;;; SLIDE PREPARATION - Show subheadings properly
        ;;; ============================================================

        (defun decknix-presentation-style-slide-heading ()
          "Style the slide heading to look like a proper title, not a bullet.
Hides the leading stars and adds title styling."
          ;; Remove any existing slide-heading overlays
          (dolist (ov (overlays-in (point-min) (point-max)))
            (when (overlay-get ov 'decknix-slide-heading)
              (delete-overlay ov)))
          ;; Add overlay to hide stars on slide heading
          (save-excursion
            (goto-char (point-min))
            (when (and (org-at-heading-p)
                       (looking-at "^\\*+ "))
              (let ((ov (make-overlay (match-beginning 0) (match-end 0))))
                (overlay-put ov 'decknix-slide-heading t)
                (overlay-put ov 'display "")  ; Hide the stars and space
                (overlay-put ov 'evaporate t)))))

        (defun decknix-org-present-prepare-slide (buffer-name heading)
          "Prepare slide content - show subheadings without expanding them.
This makes section headings visible immediately, not just when drilling in."
          ;; Show only top-level headlines
          (org-overview)
          ;; Unfold the current entry
          (org-show-entry)
          ;; Show direct subheadings of the slide but don't expand them
          (org-show-children)
          ;; Style the slide heading to look like a title
          (decknix-presentation-style-slide-heading))

        ;;; ============================================================
        ;;; PRESENTATION START HOOK
        ;;; ============================================================

        (defun decknix-org-present-start ()
          "Set up beautiful Keynote-like presentation environment."
          ;; IMPORTANT: Cache presentation info FIRST before any narrowing
          (decknix-presentation-cache-info)

          ;; Save current state for restoration
          (setq decknix-presentation--saved-state
                (list :fullscreen (frame-parameter nil 'fullscreen)
                      :tool-bar tool-bar-mode
                      :menu-bar menu-bar-mode
                      :scroll-bar scroll-bar-mode
                      :fringe-mode fringe-mode
                      :org-indent (bound-and-true-p org-indent-mode)
                      :theme (car custom-enabled-themes)
                      :face-remap face-remapping-alist))

          ;; Maybe load theme from org options
          (decknix-presentation-maybe-load-theme)

          ;; Check display options from org document (default: nil)
          (setq decknix-presentation--show-title
                (decknix-presentation-get-option "SHOW_TITLE" nil))
          (setq decknix-presentation--show-slide-num
                (decknix-presentation-get-option "SHOW_SLIDE_NUM" nil))

          ;; Fullscreen and hide chrome
          ${if cfg.presentation.fullscreen then ''
          (set-frame-parameter nil 'fullscreen 'fullboth)
          '' else ""}
          (tool-bar-mode -1)
          (menu-bar-mode -1)
          (scroll-bar-mode -1)
          (fringe-mode 0)

          ;; ============================================================
          ;; FACE REMAPPING - The secret to beautiful presentations!
          ;; This scales fonts relative to existing theme faces
          ;; ============================================================
          (setq-local face-remapping-alist
                      '(;; Main text: larger, variable pitch
                        (default (:height 1.5) variable-pitch)
                        ;; Header line: tall for spacing
                        (header-line (:height 4.0) variable-pitch)
                        ;; Document title: prominent
                        (org-document-title (:height 1.75) org-document-title)
                        ;; Headings: scaled up
                        (org-level-1 (:height 1.4) org-level-1)
                        (org-level-2 (:height 1.3) org-level-2)
                        (org-level-3 (:height 1.2) org-level-3)
                        ;; Code/diagram elements: fixed-pitch font, smaller to fit
                        (org-code (:height 1.2) fixed-pitch)
                        (org-verbatim (:height 1.2) fixed-pitch)
                        (org-block (:height 1.0) fixed-pitch)
                        (org-block-begin-line (:height 0.7) org-block)
                        ;; Tables need fixed-pitch for alignment
                        (org-table (:height 1.0) fixed-pitch)))

          ;; Hide DECKNIX_ keywords (they show as content on title page)
          (decknix-presentation-hide-keywords)

          ;; Set header line - either blank for spacing or with title/page numbers
          (decknix-presentation-update-header)

          ;; Show slide number in bottom right if enabled
          (when decknix-presentation--show-slide-num
            (decknix-presentation-update-slide-num))

          ;; Display inline images
          (org-display-inline-images)

          ;; IMPORTANT: Don't use visual-line-mode - it breaks ASCII diagrams
          ;; Instead use visual-fill-column without line wrapping for centering
          (visual-fill-column-mode 1)
          (visual-line-mode -1)  ; Disable line wrapping
          (setq visual-fill-column-width 160
                visual-fill-column-center-text t
                truncate-lines t)  ; Truncate instead of wrap

          ;; Disable org-indent to prevent weird indentation
          (org-indent-mode -1)

          ;; Visual cleanup
          (display-line-numbers-mode 0)
          (hl-line-mode 0)
          (setq-local cursor-type 'bar)

          ;; Code blocks: show by default, hide only those marked with :fold
          ;; To hide a specific block, add :fold after BEGIN:
          ;;   #+BEGIN_SRC elisp :fold
          ;; For blocks to show by default, just use normal syntax:
          ;;   #+BEGIN_SRC elisp
          ;;   #+BEGIN_EXAMPLE
          (save-excursion
            (goto-char (point-min))
            ;; Only hide blocks that have :fold or :hidden parameter
            (while (re-search-forward "#\\+BEGIN_\\(SRC\\|EXAMPLE\\).*:fold" nil t)
              (org-fold-hide-block-toggle t))))

        ;;; ============================================================
        ;;; PRESENTATION END HOOK
        ;;; ============================================================

        (defun decknix-org-present-end ()
          "Restore environment after presentation."
          ;; Reset font customizations (preserve variable-pitch if it was on)
          (setq-local face-remapping-alist
                      (or (plist-get decknix-presentation--saved-state :face-remap)
                          '((default variable-pitch default))))

          ;; Clear header line
          (setq header-line-format nil)

          ;; Remove slide number overlay
          (decknix-presentation-remove-slide-num)

          ;; Show DECKNIX_ keywords again
          (decknix-presentation-show-keywords)

          ;; Stop displaying inline images
          (org-remove-inline-images)

          ;; Stop centering
          (visual-fill-column-mode 0)
          (visual-line-mode 0)

          ;; Restore saved state
          (when decknix-presentation--saved-state
            (let ((saved decknix-presentation--saved-state))
              (set-frame-parameter nil 'fullscreen (plist-get saved :fullscreen))
              (if (plist-get saved :tool-bar) (tool-bar-mode 1) (tool-bar-mode -1))
              (if (plist-get saved :menu-bar) (menu-bar-mode 1) (menu-bar-mode -1))
              (scroll-bar-mode 1)
              (fringe-mode nil)
              (when (plist-get saved :org-indent) (org-indent-mode 1))
              ;; Restore original theme if different
              (let ((orig-theme (plist-get saved :theme)))
                (when (and orig-theme (not (eq orig-theme (car custom-enabled-themes))))
                  (load-theme orig-theme t)))))

          ;; Reset visual settings
          (display-line-numbers-mode 1)
          (hl-line-mode 1)
          (setq-local cursor-type t)
          (setq-local truncate-lines nil)

          (setq decknix-presentation--saved-state nil))

        ;;; ============================================================
        ;;; FOCUS MODE AND SUB-ITEM NAVIGATION
        ;;; ============================================================

        (defun decknix-presentation-toggle-focus ()
          "Toggle focus mode - when enabled, only current section content is visible.
Press F to toggle focus mode during presentation."
          (interactive)
          (setq decknix-presentation--focus-mode
                (not decknix-presentation--focus-mode))
          (if decknix-presentation--focus-mode
              (progn
                (org-narrow-to-subtree)
                (message "Focus mode: ON (showing only current section)"))
            (widen)
            (org-present-narrow)
            (message "Focus mode: OFF (showing full slide)")))

        (defun decknix-presentation--on-slide-heading-p ()
          "Check if point is on the slide's main heading (the top-level one).
The slide heading is at the start of the narrowed buffer."
          (save-excursion
            (beginning-of-line)
            (and (org-at-heading-p)
                 (<= (point) (save-excursion
                               (goto-char (point-min))
                               (end-of-line)
                               (point))))))

        (defun decknix-presentation--has-children-p ()
          "Check if current heading has child headings."
          (save-excursion
            (let ((current-level (org-current-level)))
              (org-next-visible-heading 1)
              (and (org-at-heading-p)
                   (> (org-current-level) current-level)))))

        (defun decknix-presentation--smart-recenter ()
          "Recenter keeping slide heading visible at top.
If current point would push slide heading off screen, scroll minimally."
          (let* ((window-start-line (count-lines (point-min) (window-start)))
                 (current-line (count-lines (point-min) (point)))
                 (lines-from-window-top (- current-line window-start-line))
                 (window-height (window-body-height)))
            ;; Only recenter if current position is getting too far down
            ;; Keep at least 3 lines from top, but don't push heading off
            (cond
             ;; If we're past 2/3 of the window, recenter to 1/4 from top
             ((> lines-from-window-top (/ (* window-height 2) 3))
              (recenter (/ window-height 4)))
             ;; If point is very close to top, don't do anything
             ((< lines-from-window-top 2)
              nil)
             ;; Otherwise, leave it alone - don't scroll unnecessarily
             (t nil))))

        (defun decknix-presentation-next-item ()
          "Navigate deeper into the current slide hierarchy.
Use j during presentation.
- If current heading has children: descend into first child
- If no children: go to next sibling
- Recursive: keeps descending into sub-sub-items"
          (interactive)
          (cond
           ;; Not on a heading - go to first heading
           ((not (org-at-heading-p))
            (goto-char (point-min))
            (when (org-at-heading-p)
              (org-fold-show-children)))
           ;; On a heading with children - descend into first child
           ((decknix-presentation--has-children-p)
            (org-fold-show-children)
            (org-next-visible-heading 1)
            (when (org-at-heading-p)
              (org-fold-show-entry)
              (org-fold-show-children)))
           ;; On a heading without children - go to next sibling
           (t
            (org-fold-hide-subtree)
            (org-next-visible-heading 1)
            (when (org-at-heading-p)
              (org-fold-show-entry)
              (org-fold-show-children))))
          (decknix-presentation--smart-recenter)
          (decknix-presentation-update-slide-num))

        (defun decknix-presentation-prev-item ()
          "Navigate up/back in the current slide hierarchy.
Use k during presentation.
- If on slide's main heading: do nothing
- If on a sub-heading: go to previous sibling or parent"
          (interactive)
          (cond
           ;; On the slide's main heading - nowhere to go
           ((decknix-presentation--on-slide-heading-p)
            (message "Already at slide heading"))
           ;; On a heading - go to previous or up
           ((org-at-heading-p)
            (let ((current-level (org-current-level)))
              (org-fold-hide-subtree)
              (org-previous-visible-heading 1)
              (when (org-at-heading-p)
                (org-fold-show-entry)
                (org-fold-show-children))))
           ;; Not on a heading - go to last heading
           (t
            (goto-char (point-max))
            (org-previous-visible-heading 1)
            (when (org-at-heading-p)
              (org-fold-show-entry)
              (org-fold-show-children))))
          (decknix-presentation--smart-recenter)
          (decknix-presentation-update-slide-num))

        (defun decknix-presentation-next-outer ()
          "Go up one level, then to next sibling at that outer level.
Use J (Shift+j) to skip current section and go to next parent-level item."
          (interactive)
          (when (org-at-heading-p)
            (org-fold-hide-subtree)
            ;; Go up one level first
            (condition-case nil
                (progn
                  (outline-up-heading 1 t)
                  ;; Now go to next sibling at this (parent) level
                  (if (outline-get-next-sibling)
                      (progn
                        (org-fold-show-entry)
                        (org-fold-show-children))
                    ;; No next sibling at parent level, stay at parent
                    (org-fold-show-entry)
                    (org-fold-show-children)))
              ;; Error going up - already at slide heading
              (error (message "Already at top level"))))
          (decknix-presentation--smart-recenter)
          (decknix-presentation-update-slide-num))

        (defun decknix-presentation-prev-outer ()
          "Go up one level, then to previous sibling at that outer level.
Use K (Shift+k) to go back to previous parent-level item."
          (interactive)
          (when (org-at-heading-p)
            (org-fold-hide-subtree)
            ;; Go up one level first
            (condition-case nil
                (progn
                  (outline-up-heading 1 t)
                  ;; Now go to previous sibling at this (parent) level
                  (if (outline-get-last-sibling)
                      (progn
                        (org-fold-show-entry)
                        (org-fold-show-children))
                    ;; No previous sibling at parent level, stay at parent
                    (org-fold-show-entry)
                    (org-fold-show-children)))
              ;; Error going up - already at slide heading
              (error (message "Already at top level"))))
          (decknix-presentation--smart-recenter)
          (decknix-presentation-update-slide-num))

        (defun decknix-presentation-expand-all ()
          "Expand all items in current slide. Use e during presentation."
          (interactive)
          (org-fold-show-subtree)
          (message "All items expanded"))

        (defun decknix-presentation-collapse-all ()
          "Collapse all items in current slide. Use c during presentation."
          (interactive)
          (org-overview)
          (org-fold-show-entry)
          (message "All items collapsed"))

        ;;; ============================================================
        ;;; REGISTER HOOKS WITH ORG-PRESENT
        ;;; ============================================================

        (with-eval-after-load 'org-present
          ;; === SLIDE NAVIGATION (between top-level sections) ===
          ;; Only n/p/SPC - arrow keys reserved for cursor movement
          (define-key org-present-mode-keymap (kbd "n") #'org-present-next)
          (define-key org-present-mode-keymap (kbd "p") #'org-present-prev)
          (define-key org-present-mode-keymap (kbd "SPC") #'org-present-next)

          ;; === UNBIND ARROW KEYS (allow normal cursor movement) ===
          (define-key org-present-mode-keymap (kbd "<right>") nil)
          (define-key org-present-mode-keymap (kbd "<left>") nil)
          (define-key org-present-mode-keymap (kbd "<up>") nil)
          (define-key org-present-mode-keymap (kbd "<down>") nil)

          ;; === SUB-ITEM NAVIGATION (within a slide) ===
          ;; j/k: descend into children or move to next/prev (recursive)
          ;; J/K: go up one level, then to next/prev at that outer level
          (define-key org-present-mode-keymap (kbd "j") #'decknix-presentation-next-item)
          (define-key org-present-mode-keymap (kbd "k") #'decknix-presentation-prev-item)
          (define-key org-present-mode-keymap (kbd "J") #'decknix-presentation-next-outer)
          (define-key org-present-mode-keymap (kbd "K") #'decknix-presentation-prev-outer)

          ;; === EXPAND/COLLAPSE ===
          (define-key org-present-mode-keymap (kbd "e") #'decknix-presentation-expand-all)
          (define-key org-present-mode-keymap (kbd "c") #'decknix-presentation-collapse-all)
          (define-key org-present-mode-keymap (kbd "TAB") #'org-cycle)

          ;; === DISPLAY TOGGLES ===
          (define-key org-present-mode-keymap (kbd "H") #'decknix-presentation-toggle-title)
          (define-key org-present-mode-keymap (kbd "S") #'decknix-presentation-toggle-slide-num)
          (define-key org-present-mode-keymap (kbd "F") #'decknix-presentation-toggle-focus)

          ;; === EXIT ===
          (define-key org-present-mode-keymap (kbd "q") #'org-present-quit)
          (define-key org-present-mode-keymap (kbd "<escape>") #'org-present-quit)

          ;; Register our hooks
          (add-hook 'org-present-mode-hook #'decknix-org-present-start)
          (add-hook 'org-present-mode-quit-hook #'decknix-org-present-end)
          ;; Prepare slide content on navigation
          (add-hook 'org-present-after-navigate-functions #'decknix-org-present-prepare-slide)
          ;; Update header and slide number on navigation
          (add-hook 'org-present-after-navigate-functions
                    (lambda (_buffer _heading)
                      (decknix-presentation-update-header)
                      (when decknix-presentation--show-slide-num
                        (decknix-presentation-update-slide-num)))))

        ;; == Mixed-pitch: Variable pitch for prose, fixed for code ==
        (with-eval-after-load 'mixed-pitch
          (setq mixed-pitch-set-height t))

        ;; == Visual-fill-column: Centered text for presentations ==
        (setq visual-fill-column-width 110
              visual-fill-column-center-text t)

      '';
    };
  };
}

