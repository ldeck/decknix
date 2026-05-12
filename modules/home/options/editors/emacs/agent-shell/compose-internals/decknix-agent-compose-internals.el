;;; decknix-agent-compose-internals.el --- Compose buffer helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, compose

;;; Commentary:
;;
;; Internal helpers for the compose buffer (PR B.69), carved out of
;; main-bulk so the target-resolution + completion-at-point logic can
;; be exercised in isolation.  All functions here are non-interactive
;; -- the user-facing entry points (`decknix-agent-compose',
;; `decknix-agent-compose-submit', etc.), the minor-mode and its
;; keymap stay in main-bulk per AGENTS.md Rule 2.
;;
;; Public surface:
;;
;;   `decknix--compose-find-target'                 buffer resolver
;;   `decknix--compose-display-action'              display-buffer spec
;;   `decknix--compose-command-completion-at-point' / completion
;;   `decknix--compose-file-completion-at-point'    @ completion
;;   `decknix--compose-trigger-completion'          post-self-insert
;;   `decknix--compose-setup-completion'            hook installer
;;
;; The buffer-local `decknix--compose-target-buffer' defvar stays in
;; main-bulk because it is read by other compose code that has not
;; yet been carved; the carved file forward-declares it.  External
;; symbols `agent-shell--state', `agent-shell--project-files', and
;; `agent-shell-buffers' from upstream agent-shell are also forward-
;; declared.

;;; Code:

;; Forward declarations -- defined in main-bulk and upstream
;; agent-shell respectively.  These keep the byte-compiler quiet
;; without creating a hard load-order coupling.
(defvar decknix--compose-target-buffer)

(declare-function agent-shell--project-files "agent-shell" ())
(declare-function agent-shell-buffers "agent-shell" ())
(defvar agent-shell--state)

(defun decknix--compose-find-target ()
  "Find the agent-shell buffer to target for compose."
  (cond
   ;; Already in an agent-shell buffer
   ((derived-mode-p 'agent-shell-mode)
    (current-buffer))
   ;; In a compose buffer -- return its target
   (decknix--compose-target-buffer
    decknix--compose-target-buffer)
   ;; Find the most recent agent-shell buffer
   ((and (fboundp 'agent-shell-buffers)
         (agent-shell-buffers))
    (car (agent-shell-buffers)))
   (t (user-error
       "No agent-shell buffer found. Start one with C-c A a"))))

(defun decknix--compose-display-action ()
  "Return a display-buffer action for the compose window.
Uses a bottom side-window so it never steals the workspace sidebar
or other side-windows."
  '((display-buffer-in-side-window)
    (side . bottom)
    (slot . 0)
    (window-height . 10)
    (preserve-size . (nil . t))))

(defun decknix--compose-command-completion-at-point ()
  "Complete slash commands in the compose buffer.
Looks up available commands from the target agent-shell buffer."
  (when-let* ((target (and (boundp 'decknix--compose-target-buffer)
                           decknix--compose-target-buffer))
              ((buffer-live-p target))
              (bounds (save-excursion
                        (let* ((end (progn (skip-chars-forward "[:alnum:]_-") (point)))
                               (start (progn (skip-chars-backward "[:alnum:]_-") (point))))
                          (when (eq (char-before start) ?/)
                            (list start end)))))
              (commands (with-current-buffer target
                          (when (boundp 'agent-shell--state)
                            (map-elt agent-shell--state :available-commands))))
              (descriptions (mapcar (lambda (c)
                                      (cons (map-elt c 'name)
                                            (map-elt c 'description)))
                                    commands)))
    (list (nth 0 bounds) (nth 1 bounds)
          (mapcar #'car descriptions)
          :exclusive t
          :annotation-function
          (lambda (name)
            (when-let* ((desc (map-elt descriptions name)))
              (concat "  " desc)))
          :company-kind (lambda (_) 'function)
          :exit-function (lambda (_string _status) (insert " ")))))

(defun decknix--compose-file-completion-at-point ()
  "Complete project files after @ in the compose buffer.
Uses the target agent-shell buffer's project context."
  (when-let* ((target (and (boundp 'decknix--compose-target-buffer)
                           decknix--compose-target-buffer))
              ((buffer-live-p target))
              (bounds (save-excursion
                        (let* ((end (progn (skip-chars-forward "[:alnum:]/_.-") (point)))
                               (start (progn (skip-chars-backward "[:alnum:]/_.-") (point))))
                          (when (eq (char-before start) ?@)
                            (list start end)))))
              (files (with-current-buffer target
                       (when (fboundp 'agent-shell--project-files)
                         (agent-shell--project-files)))))
    (list (nth 0 bounds) (nth 1 bounds)
          files
          :exclusive 'no
          :company-kind (lambda (f) (if (string-suffix-p "/" f) 'folder 'file))
          :exit-function (lambda (_string _status) (insert " ")))))

(defun decknix--compose-trigger-completion ()
  "Trigger completion in compose buffer when / or @ is typed.
Only triggers at line start or after whitespace."
  (when (and (memq (char-before) '(?/ ?@))
             (or (= (point) (1+ (line-beginning-position)))
                 (memq (char-before (1- (point))) '(?\s ?\t ?\n))))
    (cond
     ((and (eq (char-before) ?/)
           (decknix--compose-command-completion-at-point))
      (completion-at-point))
     ((eq (char-before) ?@)
      (completion-at-point)))))

(defun decknix--compose-setup-completion ()
  "Set up slash command and file completion in the compose buffer."
  (add-hook 'completion-at-point-functions
            #'decknix--compose-file-completion-at-point nil t)
  (add-hook 'completion-at-point-functions
            #'decknix--compose-command-completion-at-point nil t)
  (add-hook 'post-self-insert-hook
            #'decknix--compose-trigger-completion nil t))

(provide 'decknix-agent-compose-internals)

;;; decknix-agent-compose-internals.el ends here
