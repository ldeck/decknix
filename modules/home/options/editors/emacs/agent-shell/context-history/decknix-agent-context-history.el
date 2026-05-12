;;; decknix-agent-context-history.el --- Context section paging primitives -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-session-history "0.1"))
;; Keywords: agent, agent-shell, decknix, context

;;; Commentary:
;;
;; Three helpers and two buffer-local caches that drive the inline
;; Context history section restored on `--resume' (#136).  Carved out
;; of `decknix-agent-shell-main' (PR B.68) so the rendering kernel is
;; testable without an interactive session and so the paging
;; commands' kernel can grow here without bloating main-bulk.
;;
;; Buffer-locals (declared with initialiser so let-binding in tests
;; treats them as special variables):
;;
;;   `decknix--agent-history-cache'
;;       Full parsed turn list for the current buffer's session.
;;       Populated on the first `-session-prepopulate' and re-used
;;       by the `[' / `]' paging commands so they never re-read
;;       the on-disk JSON.
;;
;;   `decknix--agent-history-cursor'
;;       0-based index of the topmost turn currently rendered.
;;
;; Functions:
;;
;;   `decknix--agent-context-find-existing'  (pure)
;;       Returns plist describing the existing Context section.
;;
;;   `decknix--agent-context-render-window'  (mutates buffer)
;;       Re-renders the Context section anchored at CURSOR using
;;       the cached turn list.
;;
;;   `decknix--agent-session-prepopulate'    (mutates buffer)
;;       Initial render: extracts turns, seeds the cache + cursor,
;;       calls `-render-window'.
;;
;; Interactive paging commands (`-history-older', `-history-newer')
;; and the keymap on the section header stay in main-bulk per
;; AGENTS.md Rule 2 -- they bind keys / mouse buttons and read
;; user prefix args.

;;; Code:

(require 'cl-lib)

;; Session-history primitives carved earlier.
(declare-function decknix--agent-session-extract-all-turns
                  "decknix-agent-session-history" (session-id))
(declare-function decknix--agent-session-window-clamp
                  "decknix-agent-session-history" (cursor count total))
(declare-function decknix--agent-session-take-window
                  "decknix-agent-session-history" (turns cursor count))

;; Owned by main-bulk -- the keymap is bound to the section header
;; via `keymap' text property and stays in the heredoc per Rule 2.
(defvar decknix--agent-context-header-map)
;; Defcustom in main-bulk; carved code reads it for the window size.
(defvar decknix-agent-session-history-count)

(defvar-local decknix--agent-history-cache nil
  "Cached full turn list for this buffer's session.
Populated on the first `decknix--agent-session-prepopulate' run
and re-used by `decknix-agent-history-older' / `-newer' so paging
the timeline window does not re-read the on-disk session JSON.
nil means the cache has not been populated yet (e.g. fresh buffer
before the resume timer has fired).")

(defvar-local decknix--agent-history-cursor nil
  "Index (0-based, oldest = 0) of the topmost turn currently rendered.
Set by `decknix--agent-session-prepopulate' to land the user at
the bottom of the timeline (most recent N turns) and updated by
`decknix-agent-history-older' / `-newer' as the user pages.  nil
means no Context section has been rendered in this buffer.")

(defun decknix--agent-context-find-existing ()
  "Return a plist describing the existing Context section, or nil.
The plist carries `:header-start' (line BOL of the `▶'/`▼' header),
`:body-start' (first char of the `decknix-context-body' region) and
`:body-end' (one past the last char of that region) so callers can
read the body's `invisible' flag without re-deriving offsets."
  (save-excursion
    (let ((body-start (next-single-property-change
                       (point-min) 'decknix-context-body)))
      (when body-start
        (let ((body-end (next-single-property-change
                         body-start 'decknix-context-body))
              (header-start (save-excursion
                              (goto-char (max (point-min) (1- body-start)))
                              (line-beginning-position))))
          (when body-end
            (list :header-start header-start
                  :body-start body-start
                  :body-end body-end)))))))

(defun decknix--agent-context-render-window (cursor)
  "Re-render the Context section anchored at turn CURSOR (0-based).
Reads from the buffer-local `decknix--agent-history-cache' (must
be populated; see `decknix--agent-session-prepopulate') and slices
out `decknix-agent-session-history-count' turns starting at the
window-clamped CURSOR.

Removes any existing Context section first so the buffer is left
with exactly one.  Updates `decknix--agent-history-cursor' to the
clamped value so subsequent paging starts from the visible window
even when the caller passed an out-of-range cursor.  Preserves
the prior collapsed/expanded state of the section across
re-renders so paging does not auto-expand a collapsed section."
  (let* ((all decknix--agent-history-cache)
         (count decknix-agent-session-history-count)
         (total (length all))
         (clamped (decknix--agent-session-window-clamp cursor count total))
         (window (decknix--agent-session-take-window all clamped count))
         (window-len (length window))
         (display-from (1+ clamped))
         (display-to (+ clamped window-len))
         (existing (decknix--agent-context-find-existing))
         (was-collapsed
          (when existing
            ;; Pre-existing section's invisible flag dictates the
            ;; collapse/expand state we restore after re-render.
            ;; New sections (no existing) start collapsed by
            ;; convention — the prompt stays immediately visible.
            (get-text-property (plist-get existing :body-start)
                               'invisible))))
    (when window
      (let ((inhibit-read-only t))
        (save-excursion
          ;; Drop any existing section so we can replace it.
          (when existing
            (delete-region (plist-get existing :header-start)
                           (plist-get existing :body-end)))
          ;; Position at start of the prompt line.
          (goto-char (point-max))
          (let ((prompt-pos
                 (when (bound-and-true-p comint-prompt-regexp)
                   (re-search-backward comint-prompt-regexp nil t))))
            (if prompt-pos
                (goto-char prompt-pos)
              (goto-char (point-max))))
          (beginning-of-line)
          (let* ((arrow (if (or (null existing) was-collapsed) "▶" "▼"))
                 (label (format "Context (%d–%d / %d)"
                                display-from display-to total)))
            (insert (propertize
                     (format "%s %s\n"
                             arrow
                             (propertize label
                                         'font-lock-face
                                         'font-lock-doc-markup-face))
                     'read-only t
                     'rear-nonsticky t
                     'keymap decknix--agent-context-header-map))
            (let ((body-start (point)))
              (dolist (ex window)
                (let ((user (car ex))
                      (resp (cdr ex)))
                  (insert (propertize
                           (format "\n❯ %s\n"
                                   (truncate-string-to-width
                                    user 500 nil nil "..."))
                           'font-lock-face 'font-lock-keyword-face
                           'read-only t
                           'rear-nonsticky t))
                  (when (and resp (not (string-empty-p resp)))
                    (insert (propertize
                             (format "\n%s\n"
                                     (truncate-string-to-width
                                      resp 2000 nil nil
                                      "\n[...truncated]"))
                             'font-lock-face 'font-lock-doc-face
                             'read-only t
                             'rear-nonsticky t)))))
              (insert (propertize "\n" 'read-only t 'rear-nonsticky t))
              (put-text-property body-start (point)
                                 'decknix-context-body t)
              ;; Restore collapsed/expanded state: new sections
              ;; start collapsed; re-renders preserve the prior
              ;; visibility so paging doesn't yank the user's
              ;; collapse choice out from under them.
              (put-text-property body-start (point)
                                 'invisible
                                 (if existing was-collapsed t))))))
      (setq decknix--agent-history-cursor clamped)
      (cons clamped window-len))))

(defun decknix--agent-session-prepopulate (session-id n)
  "Insert a collapsible Context section with the last N exchanges.
Inserts just before the prompt, matching the ▶/▼ toggle style of
agent-shell's built-in sections (Notices, Agent capabilities, etc.).
User messages shown in `font-lock-keyword-face', assistant responses
in `font-lock-doc-face'.  Section is collapsed by default so the
prompt is immediately visible.  Click or TAB the header to expand;
press `[' / `]' (or `C-c s [' / `C-c s ]') to page older / newer
turns through the same window.

Caches the full parsed turn list in `decknix--agent-history-cache'
and seeds `decknix--agent-history-cursor' so subsequent paging
operates on the cache without re-reading the on-disk JSON."
  (let* ((all (decknix--agent-session-extract-all-turns session-id))
         (total (length all))
         (count n)
         ;; Land at the bottom of the timeline (most recent N turns).
         (cursor (decknix--agent-session-window-clamp
                  (- total count) count total)))
    (when all
      (setq decknix--agent-history-cache all)
      ;; Make N buffer-local so subsequent `[' / `]' paging steps
      ;; by the same window size the user picked at resume time
      ;; (e.g. `C-u 5 C-c A s' overrides the default 2).  The
      ;; render helper reads the current value to compute the
      ;; window slice, so a global setq here would leak into
      ;; other buffers.
      (setq-local decknix-agent-session-history-count count)
      (decknix--agent-context-render-window cursor)
      ;; Move point to the prompt so the buffer is immediately
      ;; ready for input, not stuck at the Context header.
      (goto-char (point-max)))))

(provide 'decknix-agent-context-history)
;;; decknix-agent-context-history.el ends here
