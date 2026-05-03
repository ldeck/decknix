;;; decknix-sidebar-width.el --- Sidebar width cycling state + commands -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, sidebar, ui

;;; Commentary:
;;
;; Treemacs-style sidebar width cycling extracted from
;; `decknix-agent-shell-workspace' (workspace-bulk).  The `W' key in
;; the sidebar transient cycles through three width modes:
;;
;;   default  -- the upstream `agent-shell-workspace-sidebar-width'
;;   fit      -- the longest line in the sidebar buffer + 2 cols
;;   wide     -- 2x the default width
;;
;; Three entry points:
;;
;;   `decknix--sidebar-width-state'
;;       Defvar holding the current cycle state symbol
;;       (`default', `fit', or `wide').  Persisted across sessions
;;       via `decknix--sidebar-state-file' in workspace-bulk.
;;   `decknix--sidebar-apply-width'
;;       Reapply the saved width state to the sidebar window.
;;       Wired into the heredoc as advice on the sidebar opener so
;;       the previous-session width is restored at startup.
;;   `decknix-sidebar-cycle-width'
;;       Interactive command bound to `W' in the toggles transient.
;;       Advances the cycle one step and resizes the window.
;;
;; The two upstream package vars (`agent-shell-workspace-sidebar-
;; buffer-name' and `agent-shell-workspace-sidebar-width') are
;; forward-declared because they're defined by the upstream
;; `agent-shell-workspace' package which is loaded before this
;; module via the heredoc's `require' chain.

;;; Code:

;; -- Forward declarations: defined in upstream `agent-shell-workspace' --
(defvar agent-shell-workspace-sidebar-buffer-name)
(defvar agent-shell-workspace-sidebar-width)

(defvar decknix--sidebar-width-state 'default
  "Current sidebar width state: default, fit, or wide.")

;; FIXME(arch-debt): the fit-to-content measurement loop is
;; duplicated between `decknix--sidebar-apply-width' and
;; `decknix-sidebar-cycle-width'.  Carving it into a shared helper
;; is a refactor opportunity for a follow-up; this slice preserves
;; the original implementation verbatim.
(defun decknix--sidebar-apply-width ()
  "Apply the saved width state to the sidebar window.
Called after the sidebar opens to restore the width from the
previous session."
  (let ((win (get-buffer-window
              agent-shell-workspace-sidebar-buffer-name))
        (default-w agent-shell-workspace-sidebar-width))
    (when (and win (window-live-p win)
               (not (eq decknix--sidebar-width-state 'default)))
      (pcase decknix--sidebar-width-state
        ('fit
         ;; Fit to content: measure longest line
         (let ((max-len 0))
           (with-current-buffer (window-buffer win)
             (save-excursion
               (goto-char (point-min))
               (while (not (eobp))
                 (setq max-len
                       (max max-len (- (line-end-position)
                                       (line-beginning-position))))
                 (forward-line 1))))
           (let ((fit-w (max default-w (+ max-len 2))))
             (window-resize win (- fit-w (window-width win)) t))))
        ('wide
         (let ((wide-w (* 2 default-w)))
           (window-resize win (- wide-w (window-width win)) t)))))))

(defun decknix-sidebar-cycle-width ()
  "Cycle sidebar width: default → fit-to-content → wide → default.
Like treemacs `W' / extra-wide-toggle."
  (interactive)
  (let* ((win (get-buffer-window
               agent-shell-workspace-sidebar-buffer-name))
         (default-w agent-shell-workspace-sidebar-width)
         (wide-w (* 2 default-w)))
    (when (and win (window-live-p win))
      (pcase decknix--sidebar-width-state
        ('default
         ;; Fit to content: measure longest line
         (let ((max-len 0))
           (with-current-buffer (window-buffer win)
             (save-excursion
               (goto-char (point-min))
               (while (not (eobp))
                 (setq max-len
                       (max max-len (- (line-end-position)
                                       (line-beginning-position))))
                 (forward-line 1))))
           (let ((fit-w (max default-w (+ max-len 2))))
             (window-resize win (- fit-w (window-width win)) t)))
         (setq decknix--sidebar-width-state 'fit)
         (message "Sidebar: fit-to-content"))
        ('fit
         (window-resize win (- wide-w (window-width win)) t)
         (setq decknix--sidebar-width-state 'wide)
         (message "Sidebar: wide (%d)" wide-w))
        ('wide
         (window-resize win (- default-w (window-width win)) t)
         (setq decknix--sidebar-width-state 'default)
         (message "Sidebar: default (%d)" default-w))))))

(provide 'decknix-sidebar-width)
;;; decknix-sidebar-width.el ends here
