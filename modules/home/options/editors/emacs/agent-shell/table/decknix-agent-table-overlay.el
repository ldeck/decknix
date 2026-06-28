;;; decknix-agent-table-overlay.el --- Auto-align GFM tables via overlays -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-table "0.1"))
;; Keywords: agent, agent-shell, decknix, markdown, table

;;; Commentary:
;;
;; Display-overlay layer over the pure `decknix-agent-table' core.  It
;; finds every GFM table block in a region and lays a `display' property
;; over it carrying the aligned (or, when too wide, reflowed) rendering.
;; The underlying buffer text is never modified, so `M-w' still yields raw
;; markdown and the `C-c x' copy-as-format converters reparse correctly.
;;
;; Two consumers, both wired in the heredoc (AGENTS.md Rule 2):
;;   - agent-shell output: `:after' advice on `markdown-overlays-put'
;;     re-paints the whole buffer after each render pass.
;;   - review / markdown buffers: `decknix-agent-table-overlay-mode', a
;;     jit-lock-driven minor mode, paints visible regions incrementally.

;;; Code:

(require 'decknix-agent-table)

(defvar decknix-agent-table-overlay-enable t
  "When non-nil, auto-align GFM tables via display overlays.
Seeded from `programs.emacs.decknix.agentShell.tableOverlay.enable'.")

(declare-function jit-lock-register "jit-lock")
(declare-function jit-lock-unregister "jit-lock")

(defun decknix-agent-table--target-width ()
  "Best-effort usable width for the current buffer's table rendering."
  (let ((win (get-buffer-window (current-buffer))))
    (cond (win (window-body-width win))
          ((and (integerp fill-column) (> fill-column 0)) fill-column)
          (t 80))))

(defun decknix-agent-table--clear-overlays (beg end)
  "Delete decknix table display overlays between BEG and END."
  (dolist (o (overlays-in beg end))
    (when (overlay-get o 'decknix-agent-table)
      (delete-overlay o))))

(defun decknix-agent-table-overlay-region (beg end &optional width)
  "Align every GFM table block within BEG..END using display overlays.
WIDTH defaults to the buffer's usable width; a narrower width reflows
wide tables.  Returns the list of overlays created.  The buffer text is
left untouched."
  (let* ((w (or width (decknix-agent-table--target-width)))
         (text (buffer-substring-no-properties beg end))
         (created '()))
    (decknix-agent-table--clear-overlays beg end)
    (dolist (span (decknix-agent-table-block-offsets text))
      (let* ((bs (substring text (car span) (cdr span)))
             (rendered (decknix-agent-table-format bs w)))
        (unless (string= rendered bs)
          (let ((ov (make-overlay (+ beg (car span)) (+ beg (cdr span)))))
            (overlay-put ov 'decknix-agent-table t)
            (overlay-put ov 'display rendered)
            (overlay-put ov 'evaporate t)
            (push ov created)))))
    (nreverse created)))

(defun decknix-agent-table-overlay-buffer ()
  "Re-align all GFM tables in the current buffer (whole-buffer pass)."
  (when decknix-agent-table-overlay-enable
    (decknix-agent-table-overlay-region (point-min) (point-max))))

(defun decknix-agent-table--jit (start end)
  "jit-lock function: align tables in the lines spanning START..END."
  (when decknix-agent-table-overlay-enable
    (let ((b (save-excursion (goto-char start) (line-beginning-position)))
          (e (save-excursion (goto-char end) (line-end-position))))
      (decknix-agent-table-overlay-region b e))))

(define-minor-mode decknix-agent-table-overlay-mode
  "Visually align GFM tables via display overlays (buffer text unchanged).
Incremental, jit-lock-driven; suitable for review / markdown buffers."
  :lighter " ⊞"
  (if decknix-agent-table-overlay-mode
      (progn
        (require 'jit-lock)
        (jit-lock-register #'decknix-agent-table--jit)
        (decknix-agent-table-overlay-buffer))
    (ignore-errors (jit-lock-unregister #'decknix-agent-table--jit))
    (decknix-agent-table--clear-overlays (point-min) (point-max))))

(provide 'decknix-agent-table-overlay)
;;; decknix-agent-table-overlay.el ends here
