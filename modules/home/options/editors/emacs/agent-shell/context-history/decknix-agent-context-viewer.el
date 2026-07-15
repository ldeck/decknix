;;; decknix-agent-context-viewer.el --- Context history viewer buffer -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-context-history "0.1"))
;; Keywords: agent, agent-shell, decknix, context

;;; Commentary:
;;
;; Viewer buffer for the agent context history (#136 follow-up).
;; Opens as a bottom window showing ALL turns from the session's
;; history cache, with point on the most recent turn so the user
;; can immediately see where the conversation was.
;;
;; Entry point: `decknix-agent-context-viewer-open-or-toggle'.
;; With no prefix arg: open/refresh the viewer.
;; With C-u prefix arg: fall back to the legacy inline toggle.
;;
;; Keymap (viewer buffer):
;;   n / p       next / prev turn
;;   M-< / M->   first / last turn
;;   s           consult-line (or isearch as fallback)
;;   /           isearch-forward
;;   g           refresh from source buffer's cache
;;   j           jump to source agent-shell buffer
;;   q           quit-window

;;; Code:

(require 'cl-lib)

;; Forward declarations — defined in context-history and main-bulk.
(defvar decknix--agent-history-cache)
(declare-function decknix--agent-context-toggle
                  "decknix-agent-shell-main-session")

;;; Buffer-local state -------------------------------------------------

(defvar-local decknix--context-viewer-source nil
  "The agent-shell buffer this viewer was opened from.")

(defvar-local decknix--context-viewer-turn-points nil
  "Vector of buffer positions; element N is the BOL of turn N+1.")

;;; Mode ---------------------------------------------------------------

(define-derived-mode decknix-agent-context-viewer-mode special-mode
  "AgentContext"
  "Major mode for the agent context history viewer.
Shows all turns from the resumed session's history cache in a
read-only bottom window.  Use n/p to navigate, s to search."
  :interactive nil
  (setq truncate-lines nil
        buffer-read-only t)
  ;; Redisplay perf: rendered turns are LTR and can be long/heavily
  ;; propertized — force LTR + skip bidi bracket-pair resolution so
  ;; window relayout stays cheap (see agent-shell-mode-hook).
  (setq-local bidi-paragraph-direction 'left-to-right)
  (setq-local bidi-inhibit-bpa t)
  ;; Disable bidi reordering outright (LTR content) — the piece that
  ;; actually removes the per-line redisplay cost; direction + bpa alone
  ;; leave the reordering machinery running.
  (setq-local bidi-display-reordering nil))

;;; Rendering ----------------------------------------------------------

(defun decknix--context-viewer-render (cache)
  "Render all turns from CACHE into the current viewer buffer.
Sets `decknix--context-viewer-turn-points' so navigation works."
  (let* ((inhibit-read-only t)
         (total (length cache))
         (pts (make-vector total nil))
         (i 0))
    (erase-buffer)
    (dolist (turn cache)
      (let* ((num (1+ i))
             (user (car turn))
             (resp (cdr turn))
             (sep (propertize
                   (format "\n─── Turn %d / %d %s\n"
                           num total
                           (make-string
                            (max 0 (- 52 (length (format "%d / %d" num total))))
                            ?─))
                   'face '(:inherit font-lock-comment-face :weight bold)
                   'decknix-turn-number num)))
        (aset pts i (point))
        (insert sep)
        (insert (propertize (format "\n❯ %s\n" user)
                            'face 'font-lock-keyword-face))
        (when (and resp (not (string-empty-p resp)))
          (insert (propertize (format "\n%s\n" resp)
                              'face 'font-lock-doc-face)))
        (setq i (1+ i))))
    (setq decknix--context-viewer-turn-points pts)))

;;; Navigation ---------------------------------------------------------

(defun decknix-agent-context-viewer-goto-turn (n)
  "Move point to turn N (1-based) and recenter."
  (interactive "nJump to turn: ")
  (let* ((pts decknix--context-viewer-turn-points)
         (len (if pts (length pts) 0)))
    (when (and pts (> n 0) (<= n len))
      (goto-char (aref pts (1- n)))
      ;; Only recenter when the viewer buffer is actually shown in the
      ;; selected window.  `decknix-agent-context-viewer-open' positions
      ;; point inside `with-current-buffer' before `display-buffer', so
      ;; recentring there would signal "'recenter'ing a window that does
      ;; not display current-buffer" (surfaced via C-c s c on a restored
      ;; session).  The open path now recentres after `select-window'.
      (when (eq (window-buffer (selected-window)) (current-buffer))
        (recenter 2)))))

(defun decknix-agent-context-viewer-goto-first ()
  "Move point to the first (oldest) turn."
  (interactive)
  (decknix-agent-context-viewer-goto-turn 1))

(defun decknix-agent-context-viewer-goto-last ()
  "Move point to the most recent (last) turn."
  (interactive)
  (when decknix--context-viewer-turn-points
    (decknix-agent-context-viewer-goto-turn
     (length decknix--context-viewer-turn-points))))

(defun decknix--context-viewer-current-turn ()
  "Return the 1-based turn number at point, or nil."
  (let* ((pts decknix--context-viewer-turn-points)
         (n (if pts (length pts) 0)))
    (when (and pts (> n 0))
      (cl-loop for i from 0 below n
               when (and (>= (point) (aref pts i))
                         (or (= i (1- n))
                             (< (point) (aref pts (1+ i)))))
               return (1+ i)))))

(defun decknix-agent-context-viewer-next-turn ()
  "Advance to the next turn, or stay at the last."
  (interactive)
  (let* ((cur (decknix--context-viewer-current-turn))
         (total (if decknix--context-viewer-turn-points
                    (length decknix--context-viewer-turn-points) 0)))
    (decknix-agent-context-viewer-goto-turn
     (min total (if cur (1+ cur) 1)))))

(defun decknix-agent-context-viewer-prev-turn ()
  "Go back to the previous turn, or stay at the first."
  (interactive)
  (let ((cur (decknix--context-viewer-current-turn)))
    (decknix-agent-context-viewer-goto-turn
     (max 1 (if cur (1- cur) 1)))))

;;; Utilities ----------------------------------------------------------

(defun decknix-agent-context-viewer-refresh ()
  "Re-render from the source buffer's current history cache."
  (interactive)
  (if (and decknix--context-viewer-source
           (buffer-live-p decknix--context-viewer-source))
      (let ((cache (buffer-local-value
                    'decknix--agent-history-cache
                    decknix--context-viewer-source)))
        (if cache
            (progn (decknix--context-viewer-render cache)
                   (decknix-agent-context-viewer-goto-last)
                   (message "Context viewer: %d turns" (length cache)))
          (message "No context history for this session")))
    (message "Source agent-shell buffer is no longer live")))

(defun decknix-agent-context-viewer-jump-source ()
  "Switch to the source agent-shell buffer."
  (interactive)
  (if (and decknix--context-viewer-source
           (buffer-live-p decknix--context-viewer-source))
      (pop-to-buffer decknix--context-viewer-source)
    (message "Source buffer is no longer live")))

(defun decknix-agent-context-viewer-search ()
  "Search in the viewer (consult-line if available, else isearch)."
  (interactive)
  (if (fboundp 'consult-line)
      (call-interactively #'consult-line)
    (call-interactively #'isearch-forward)))

;;; Keymap -------------------------------------------------------------

(let ((map decknix-agent-context-viewer-mode-map))
  (define-key map (kbd "n")   #'decknix-agent-context-viewer-next-turn)
  (define-key map (kbd "p")   #'decknix-agent-context-viewer-prev-turn)
  (define-key map (kbd "M-<") #'decknix-agent-context-viewer-goto-first)
  (define-key map (kbd "M->") #'decknix-agent-context-viewer-goto-last)
  (define-key map (kbd "s")   #'decknix-agent-context-viewer-search)
  (define-key map (kbd "/")   #'isearch-forward)
  (define-key map (kbd "g")   #'decknix-agent-context-viewer-refresh)
  (define-key map (kbd "j")   #'decknix-agent-context-viewer-jump-source)
  (define-key map (kbd "q")   #'quit-window))

;;; Entry point --------------------------------------------------------

(defun decknix-agent-context-viewer-open (&optional source-buf)
  "Open the context viewer for SOURCE-BUF (default: current buffer).
Opens in a bottom window and positions point at the most recent turn."
  (let* ((src (or source-buf (current-buffer)))
         (cache (buffer-local-value 'decknix--agent-history-cache src))
         (bname (format "*Agent Context: %s*" (buffer-name src)))
         (viewer (get-buffer-create bname)))
    (if (null cache)
        (message "No context history for this session (press C-c s [ or ] to page)")
      (with-current-buffer viewer
        (setq-local decknix--context-viewer-source src)
        (decknix-agent-context-viewer-mode)
        (decknix--context-viewer-render cache))
      (let ((win (display-buffer
                  viewer
                  '((display-buffer-at-bottom)
                    (window-height . 0.4)))))
        (when (window-live-p win)
          (select-window win)
          ;; Position point only after the window displays VIEWER so
          ;; `recenter' (inside goto-last) operates on the right window.
          (decknix-agent-context-viewer-goto-last))))))

;;;###autoload
(defun decknix-agent-context-viewer-open-or-toggle (&optional arg)
  "Open the context viewer, or with prefix ARG toggle the inline section."
  (interactive "P")
  (if arg
      (call-interactively #'decknix--agent-context-toggle)
    (decknix-agent-context-viewer-open)))

(provide 'decknix-agent-context-viewer)
;;; decknix-agent-context-viewer.el ends here
