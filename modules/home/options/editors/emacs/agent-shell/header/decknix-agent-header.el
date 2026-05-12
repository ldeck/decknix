;;; decknix-agent-header.el --- Unified header-line for agent-shell buffers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, header-line

;;; Commentary:
;;
;; Pure presentation + tiny timer plumbing for the per-buffer
;; header-line shown in every agent-shell buffer.  Merges
;; agent-shell's upstream header (agent name, model, mode,
;; workspace, busy animation) with decknix-specific extras
;; (status icon + label, conversation tags, context-panel items).
;;
;; Carved out of `decknix-agent-shell-main' (main-bulk) into the
;; `agent-shell/header/' cluster so the ~150-line block of icon
;; tables, face mappings, and refresh-timer scaffolding lives in
;; its own byte-compiled unit.  The agent-shell startup hook that
;; seeds `decknix--header-update' / `-start-timer' / `-stop-timer'
;; stays in the heredoc per AGENTS.md Rule 2 (top-level
;; side-effects belong in main).
;;
;; Public surface:
;;
;;   `decknix--header-timer'             buffer-local refresh timer
;;   `decknix--header-prev-status'       buffer-local transition memo
;;
;;   `decknix--header-detect-status'     -> "ready" | "working" | ...
;;   `decknix--header-status-icon' (s)   -> "●" | "◐" | ...
;;   `decknix--header-status-face' (s)   -> face spec
;;   `decknix--header-tags'              -> list of tag strings
;;   `decknix--header-workspace-short'   -> abbreviated workspace path
;;   `decknix--header-upstream'          -> agent-shell text header
;;   `decknix--header-build'             -> joined header string
;;
;;   `decknix--header-update'            sets `header-line-format'
;;   `decknix--header-start-timer'       starts the 2-second refresh
;;   `decknix--header-stop-timer'        cancels the refresh
;;
;; Status transitions: `working|waiting -> ready' is rendered as
;; `finished' until the user returns to the buffer; once focus
;; lands the icon collapses back to plain `ready'.

;;; Code:

;; -- Forward declarations ----------------------------------------

;; Upstream agent-shell / shell-maker symbols touched at runtime.
(declare-function agent-shell-workspace--buffer-status
                  "agent-shell-workspace" (buffer))
(declare-function agent-shell--make-header "agent-shell" (state))
(declare-function agent-shell--state "agent-shell")
(defvar agent-shell-header-style)
(defvar shell-maker--busy)

;; Sibling carved modules.
(declare-function decknix--agent-tags-for-conv-key
                  "decknix-agent-tags-read" (conv-key))
(declare-function decknix--agent-tags-for-session
                  "decknix-agent-tags-read" (session-id))

;; Symbols owned by main-bulk (buffer-local defvars / contextual
;; helpers).  Forward-declared as `defvar' without value so the
;; byte-compile pass resolves the reference; the actual binding
;; lives in `decknix-agent-shell-main' or in
;; `decknix-agent-shell-context' (loaded conditionally).
(defvar decknix--agent-conv-key)
(defvar decknix--agent-auggie-session-id)
(defvar decknix--agent-session-workspace)
(declare-function decknix--context-header-string
                  "decknix-agent-shell-context")

;; == Header-line state ===========================================

(defvar-local decknix--header-timer nil
  "Buffer-local timer for refreshing the header-line.")

(defvar-local decknix--header-prev-status nil
  "Previous raw status string, used to detect transitions.")

;; == Status detection + icon / face tables =======================

(defun decknix--header-detect-status ()
  "Return the current agent status as a string.
Uses agent-shell-workspace's detection when available (richer states),
otherwise falls back to shell-maker--busy."
  (cond
   ;; Rich detection from agent-shell-workspace
   ((fboundp 'agent-shell-workspace--buffer-status)
    (agent-shell-workspace--buffer-status (current-buffer)))
   ;; Fallback: shell-maker busy flag
   ((bound-and-true-p shell-maker--busy) "working")
   ;; Check if process is alive
   ((and (get-buffer-process (current-buffer))
         (process-live-p (get-buffer-process (current-buffer))))
    "ready")
   ((not (get-buffer-process (current-buffer))) "killed")
   (t "unknown")))

(defun decknix--header-status-icon (status)
  "Return a status icon string for STATUS."
  (pcase status
    ("ready"        "●")
    ("finished"     "✔")
    ("working"      "◐")
    ("waiting"      "◉")
    ("initializing" "○")
    ("killed"       "✕")
    (_              "?")))

(defun decknix--header-status-face (status)
  "Return a face for STATUS."
  (pcase status
    ("ready"        'success)
    ("finished"     '(:foreground "cyan" :weight bold))
    ("working"      'warning)
    ("waiting"      '(:foreground "red" :weight bold))
    ("initializing" 'font-lock-comment-face)
    ("killed"       'error)
    (_              'shadow)))

(defun decknix--header-tags ()
  "Return the tag list for the current buffer's conversation, or nil.
Fast path: uses `decknix--agent-conv-key' (set during post-create) to
look up tags directly, bypassing the session-list cache.  Falls back to
the session-id-based lookup if conv-key is not set yet."
  (or
   ;; Fast path: conv-key available (set during quickaction or
   ;; deferred prompt-ready) -- no session-list cache dependency.
   (when (bound-and-true-p decknix--agent-conv-key)
     (decknix--agent-tags-for-conv-key decknix--agent-conv-key))
   ;; Slow path: look up via session-id -> session-list -> conv-key
   (when (and (boundp 'decknix--agent-auggie-session-id)
              decknix--agent-auggie-session-id)
     (decknix--agent-tags-for-session
      decknix--agent-auggie-session-id))))


(defun decknix--header-workspace-short ()
  "Return an abbreviated workspace path for the header-line."
  (when (and (boundp 'decknix--agent-session-workspace)
             decknix--agent-session-workspace
             (not (string-empty-p decknix--agent-session-workspace)))
    (abbreviate-file-name decknix--agent-session-workspace)))

(defun decknix--header-upstream ()
  "Return agent-shell's text header string.
This embeds the upstream header (agent name, model, mode, workspace,
session ID, context/usage indicator, busy animation) so we inherit
any improvements to agent-shell--make-header automatically."
  (ignore-errors
    (when (fboundp 'agent-shell--make-header)
      (let ((agent-shell-header-style 'text))
        (agent-shell--make-header (agent-shell--state))))))

(defun decknix--header-build ()
  "Build the unified header-line string for the current agent-shell buffer.
Embeds agent-shell's full header (agent name, model, mode, workspace,
busy animation) and appends decknix extras (status icon, tags, context panel)."
  (let* ((raw-status (decknix--header-detect-status))
         ;; Track transitions: working -> ready = finished
         (status (cond
                  ((and (member decknix--header-prev-status
                                '("working" "waiting"))
                        (string= raw-status "ready"))
                   "finished")
                  (t raw-status)))
         (icon (decknix--header-status-icon status))
         (face (decknix--header-status-face status))
         (upstream (decknix--header-upstream))
         (tags (decknix--header-tags))
         (parts nil))
    ;; Clear "finished" once user returns to the buffer
    (when (and (string= status "finished")
               (eq (current-buffer) (window-buffer (selected-window))))
      (setq status raw-status))
    ;; Update previous status for next cycle
    (when (member raw-status '("working" "waiting"))
      (setq decknix--header-prev-status raw-status))
    (when (not (member raw-status '("working" "waiting")))
      (setq decknix--header-prev-status nil))
    ;; 1. Status icon + label
    (push (propertize (format " %s %s" icon status)
                      'face face)
          parts)
    ;; 2. Tags (stable width -- before animated upstream)
    (when tags
      (push (propertize
             (mapconcat (lambda (tg) (format "#%s" tg)) tags " ")
             'face 'font-lock-type-face)
            parts))
    ;; 3. Context panel items (stable -- before animated upstream)
    (when (fboundp 'decknix--context-header-string)
      (let ((ctx (decknix--context-header-string)))
        (when ctx (push ctx parts))))
    ;; 4. Agent-shell upstream header (agent, model, mode,
    ;;    workspace, session-id, usage, busy animation)
    ;; Placed last so the animated busy indicator expands/contracts
    ;; at the right edge without shifting stable elements.
    (when (and upstream (not (string-empty-p upstream)))
      (push (string-trim upstream) parts))
    ;; Join with separator
    (mapconcat #'identity (nreverse parts) "  │  ")))

(defun decknix--header-update ()
  "Update the header-line-format for the current agent-shell buffer."
  (when (derived-mode-p 'agent-shell-mode)
    (setq-local header-line-format
                (list (decknix--header-build)))
    (force-mode-line-update)))

(defun decknix--header-start-timer ()
  "Start a buffer-local 2-second timer to refresh the header-line.
Lexical-binding makes the BUF capture work without the
`(eval `(lambda ...) t)' workaround the dynamic-binding heredoc
required for the same shape."
  (when decknix--header-timer
    (cancel-timer decknix--header-timer))
  (let ((buf (current-buffer)))
    (setq decknix--header-timer
          (run-with-timer
           1 2
           (lambda ()
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (decknix--header-update))))))))

(defun decknix--header-stop-timer ()
  "Stop the header-line refresh timer."
  (when decknix--header-timer
    (cancel-timer decknix--header-timer)
    (setq decknix--header-timer nil)))

(provide 'decknix-agent-header)
;;; decknix-agent-header.el ends here
