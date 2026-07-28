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
left untouched.

BEG/END and every overlay's endpoints are clamped to the live buffer
bounds so a stale caller position can never make `make-overlay' signal
`args-out-of-range' (which, mid-redisplay, would loop)."
  (let* ((beg (max (point-min) (min beg (point-max))))
         (end (max beg (min end (point-max))))
         (w (or width (decknix-agent-table--target-width)))
         (text (buffer-substring-no-properties beg end))
         (created '()))
    (decknix-agent-table--clear-overlays beg end)
    (dolist (span (decknix-agent-table-block-offsets text))
      (let* ((bs (substring text (car span) (cdr span)))
             (rendered (decknix-agent-table-format bs w)))
        (unless (string= rendered bs)
          (let ((os (min end (max beg (+ beg (car span)))))
                (oe (min end (max beg (+ beg (cdr span))))))
            (when (< os oe)
              (let ((ov (make-overlay os oe)))
                (overlay-put ov 'decknix-agent-table t)
                (overlay-put ov 'display rendered)
                (overlay-put ov 'evaporate t)
                (push ov created)))))))
    (nreverse created)))

(defun decknix-agent-table-overlay-buffer ()
  "Re-align all GFM tables in the current buffer (whole-buffer pass)."
  (when decknix-agent-table-overlay-enable
    (decknix-agent-table-overlay-region (point-min) (point-max))))

;; ── Debounced, bounded, off-redisplay repaint for streaming output ──────
;;
;; agent-shell renders output by calling `markdown-overlays-put' (itself a
;; whole-buffer rescan) repeatedly during streaming.  Doing a SECOND whole
;; buffer table pass synchronously in an `:after' advice on every render pass
;; is O(buffer) each time — quadratic on a large transcript — and mutates
;; `display' overlays while redisplay/jit timers are mid-flight, which is how a
;; ~1 MB session buffer wedged with `args-out-of-range' loops.  So the advice
;; must only SCHEDULE a repaint: one coalesced, idle-timer pass that (a) runs
;; off the output/redisplay path, (b) rescans only the buffer tail, (c) yields
;; to input via `while-no-input', and (d) is reentrancy-guarded.

(defvar decknix-agent-table-overlay-max-scan 200000
  "Max buffer tail (chars) rescanned on a debounced repaint, or nil for all.
A large, actively-streaming transcript is expensive to rescan whole and churns
overlays under redisplay; the debounced repaint only revisits this many
characters back from `point-max' (snapped to a line start).  Tables above that
window keep their existing overlays.")

(defvar decknix-agent-table-overlay-debounce 0.3
  "Idle seconds used to coalesce table repaints after output settles.")

(defvar decknix-agent-table--repainting nil
  "Non-nil while a debounced repaint runs — reentrancy guard.")

(defvar-local decknix-agent-table--repaint-timer nil
  "Pending per-buffer debounce timer, or nil.")

(defun decknix-agent-table--tail-region ()
  "Return (BEG . END): the tail to rescan, line-snapped, per `...-max-scan'."
  (let ((end (point-max)))
    (cons (if (and (integerp decknix-agent-table-overlay-max-scan)
                   (> (buffer-size) decknix-agent-table-overlay-max-scan))
              (save-excursion
                (goto-char (- end decknix-agent-table-overlay-max-scan))
                (line-beginning-position))
            (point-min))
          end)))

(defun decknix-agent-table-overlay-refresh (&optional buffer)
  "Repaint tables in BUFFER's tail region — abortable + reentrancy-guarded.
Meant to run from the debounce idle timer, NOT the output/redisplay path.
`while-no-input' lets a big scan yield to typing; `ignore-errors' keeps a
transient position race from ever propagating into redisplay."
  (let ((buf (or buffer (current-buffer))))
    (when (and (buffer-live-p buf)
               decknix-agent-table-overlay-enable
               (not decknix-agent-table--repainting))
      (with-current-buffer buf
        (setq decknix-agent-table--repaint-timer nil)
        (let ((decknix-agent-table--repainting t)
              (region (decknix-agent-table--tail-region)))
          (while-no-input
            (ignore-errors
              (decknix-agent-table-overlay-region (car region) (cdr region)))))))))

(defun decknix-agent-table-overlay-schedule (&rest _)
  "Debounced entry point: coalesce rapid render passes into one idle repaint.
Safe from a `markdown-overlays-put' :after advice — it only arms a short idle
timer in the current buffer and returns, so no overlay mutation happens inside
the output / timer / redisplay path."
  (when decknix-agent-table-overlay-enable
    (let ((buf (current-buffer)))
      (when (timerp decknix-agent-table--repaint-timer)
        (cancel-timer decknix-agent-table--repaint-timer))
      (setq decknix-agent-table--repaint-timer
            (run-with-idle-timer decknix-agent-table-overlay-debounce nil
                                 #'decknix-agent-table-overlay-refresh buf)))))

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
