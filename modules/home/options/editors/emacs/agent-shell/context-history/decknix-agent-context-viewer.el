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
(defvar decknix--agent-auggie-session-id)
(declare-function decknix--agent-context-toggle
                  "decknix-agent-shell-main-session")
(declare-function decknix--agent-session-extract-all-turns
                  "decknix-agent-session-history" (session-id))

(defun decknix--context-viewer-turns (src)
  "Return the freshest (PROMPT . ANSWER) turns for source buffer SRC.
Re-extracts from SRC's live session transcript via its session id so the
CURRENT session's turns (and new ones since resume) show, not just the
snapshot prepopulated at resume time; falls back to the prepopulated
`decknix--agent-history-cache' when extraction is unavailable/empty."
  (or (let ((sid (and (buffer-live-p src)
                      (buffer-local-value 'decknix--agent-auggie-session-id src))))
        (and sid (fboundp 'decknix--agent-session-extract-all-turns)
             (ignore-errors (decknix--agent-session-extract-all-turns sid))))
      (and (buffer-live-p src)
           (buffer-local-value 'decknix--agent-history-cache src))))

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

(defun decknix--context-viewer-format-stamp (timestamp)
  "Return TIMESTAMP rendered for a turn separator, or an empty string.

Local time, because the question a reader is asking is \"was this before
or after lunch\" and the transcript writes UTC (`...T03:44:35.770Z').
Date and minute only: seconds and milliseconds are noise at the
granularity of a turn.

Returns \"\" rather than nil for anything unparseable, so a transcript
predating timestamps -- or a provider whose field name we have not
verified -- renders exactly as it did before rather than breaking the
separator."
  (if (not (stringp timestamp))
      ""
    (condition-case nil
        (format "  %s" (format-time-string "%Y-%m-%d %H:%M"
                                           (date-to-time timestamp)))
      (error ""))))

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
             (stamp (and (fboundp 'decknix--agent-turn-record-timestamp)
                         (decknix--agent-turn-record-timestamp turn)))
             (when-str (if (fboundp 'decknix--context-viewer-format-stamp)
                           (decknix--context-viewer-format-stamp stamp)
                         ""))
             (head (format "%d / %d%s" num total when-str))
             (sep (propertize
                   (format "\n─── Turn %s %s\n"
                           head
                           (make-string (max 0 (- 52 (length head))) ?─))
                   'face '(:inherit font-lock-comment-face :weight bold)
                   'decknix-turn-number num
                   'decknix-turn-timestamp stamp)))
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
      (let ((cache (decknix--context-viewer-turns
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
         (cache (decknix--context-viewer-turns src))
         (bname (format "*Agent Context: %s*" (buffer-name src)))
         (viewer (get-buffer-create bname)))
    (if (null cache)
        (message "No context history for this session (press C-c s [ or ] to page)")
      (with-current-buffer viewer
        (setq-local decknix--context-viewer-source src)
        (decknix-agent-context-viewer-mode)
        (decknix--context-viewer-render cache))
      ;; Pin placement to the SELECTED frame.  The sidebar is a dedicated
      ;; side window, and `display-buffer-at-bottom' alone cannot always
      ;; place a window against a side-window layout; when it fails,
      ;; `display-buffer' falls through to `display-buffer-fallback-action',
      ;; which happily reuses a window on ANOTHER FRAME -- so the viewer
      ;; appeared "on a different tab", the sidebar went out of view, and
      ;; dismissing it meant navigating back.
      ;;
      ;; `reusable-frames' nil confines the reuse lookup to this frame and
      ;; `inhibit-switch-frame' stops another frame being raised.
      ;; `display-buffer-reuse-window' leads so re-invoking reuses the
      ;; viewer already open here instead of stacking a second one.
      ;; Split the SELECTED window, and nothing else.
      ;;
      ;; Anything that HUNTS for an existing window can leave the current
      ;; tab.  Measured with an `:around' probe on `display-buffer' during
      ;; a real `C-c s c':
      ;;
      ;;   tab 1 -> 0   frame unchanged   win-frame = same frame
      ;;   action = ((display-buffer-reuse-window display-buffer-at-bottom)
      ;;             (reusable-frames) (inhibit-switch-frame . t) ...)
      ;;
      ;; The tab moved INSIDE `display-buffer' while the frame never did,
      ;; so the earlier `reusable-frames'/`inhibit-switch-frame' pair was
      ;; on the wrong axis entirely -- and `display-buffer-reuse-window',
      ;; added at the same time to avoid stacking a second viewer, is what
      ;; found the stale viewer window left on tab 0 and pulled selection
      ;; there.
      ;;
      ;; `display-buffer-below-selected' splits the selected window, so it
      ;; cannot select another tab or frame by construction.  Re-invoking
      ;; now reuses the viewer only when it is already the window below
      ;; (the split lands on the same spot); a copy stranded on another tab
      ;; is left where it is rather than dragging the user to it.
      (let ((win (display-buffer
                  viewer
                  '((display-buffer-below-selected)
                    (window-height . 0.4)
                    (inhibit-same-window . t)))))
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
