;;; decknix-agent-context-viewer-test.el --- Tests for the context viewer -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-context-viewer "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests for `decknix-agent-context-viewer'.
;;
;; Regression: the open path calls `decknix-agent-context-viewer-goto-last'
;; inside `with-current-buffer' (before the buffer is shown via
;; `display-buffer'), so the viewer buffer is current but the selected
;; window still displays a different buffer.  In that state `recenter'
;; signals "'recenter'ing a window that does not display current-buffer",
;; which surfaced when viewing a restored session's context (C-c s c).

;;; Code:

(require 'ert)
(require 'decknix-agent-context-viewer)

(defun decknix-agent-context-viewer-test--make-viewer ()
  "Return a fresh viewer-like buffer with three turn points set.
The buffer holds three lines; `decknix--context-viewer-turn-points'
maps to the BOL of each line (1, 6, 11)."
  (let ((buf (generate-new-buffer " *ctx-viewer-test*")))
    (with-current-buffer buf
      (insert "AAAA\nBBBB\nCCCC\n")
      (setq-local decknix--context-viewer-turn-points
                  (vector (point-min) 6 11)))
    buf))

(ert-deftest decknix-agent-context-viewer-goto-turn--safe-when-not-displayed ()
  "`goto-turn' must not signal when the buffer is current but not
displayed in the selected window, and must still move point."
  (let ((viewer (decknix-agent-context-viewer-test--make-viewer)))
    (unwind-protect
        (with-current-buffer viewer
          ;; Precondition: the selected window does NOT display VIEWER.
          (should-not (eq (window-buffer (selected-window)) (current-buffer)))
          (decknix-agent-context-viewer-goto-turn 2)
          (should (= (point) 6)))
      (kill-buffer viewer))))

(ert-deftest decknix-agent-context-viewer-goto-last--safe-when-not-displayed ()
  "`goto-last' must not signal when the buffer is current but not
displayed in the selected window, and must land on the final turn."
  (let ((viewer (decknix-agent-context-viewer-test--make-viewer)))
    (unwind-protect
        (with-current-buffer viewer
          (should-not (eq (window-buffer (selected-window)) (current-buffer)))
          (decknix-agent-context-viewer-goto-last)
          (should (= (point) 11)))
      (kill-buffer viewer))))

;; -- display placement: stay on THIS tab ------------------------------
;;
;; Reported: `C-c s c' switched from the "Agents" tab to "*decknix*" and
;; opened the viewer there, so dismissing it meant navigating back and
;; the sidebar was out of view throughout.
;;
;; A first attempt blamed FRAMES (the sidebar is a dedicated side window
;; and several frames are open) and added `reusable-frames nil' +
;; `inhibit-switch-frame t'.  That was the wrong axis, and an `:around'
;; probe on `display-buffer' during a real `C-c s c' proved it:
;;
;;   tab 1 -> 0   frame unchanged   win-frame = same frame
;;   action = ((display-buffer-reuse-window display-buffer-at-bottom)
;;             (reusable-frames) (inhibit-switch-frame . t) ...)
;;
;; The TAB moved inside `display-buffer' while the frame never did.  The
;; culprit was `display-buffer-reuse-window' -- added in that same
;; attempt to avoid stacking a second viewer -- which finds a stale
;; viewer window left on another tab and pulls selection to it.
;;
;; The rule these tests pin: use a placement that cannot hunt.  Splitting
;; the SELECTED window cannot leave the current tab or frame.

(ert-deftest decknix-context-viewer/display-action-never-leaves-this-tab ()
  "The display action never hunts for a window elsewhere."
  (let ((captured nil))
    (cl-letf (((symbol-function 'display-buffer)
               (lambda (_buf action) (setq captured action) nil))
              ((symbol-function 'decknix--context-viewer-turns)
               (lambda (_) '(((role . "user") (text . "hi")))))
              ((symbol-function 'decknix--context-viewer-render)
               (lambda (_) nil))
              ((symbol-function 'decknix-agent-context-viewer-mode)
               (lambda () nil)))
      (with-temp-buffer
        (decknix-agent-context-viewer-open (current-buffer))
        (should captured)
        (let ((fns (car captured)))
          ;; Nothing that HUNTS for an existing window: that is what
          ;; changed the TAB (measured: tab 1->0 inside `display-buffer',
          ;; frame unchanged).  `reuse-window' would find a stale viewer
          ;; left on another tab and pull selection there.
          (should-not (memq 'display-buffer-reuse-window fns))
          (should-not (memq 'display-buffer-use-some-window fns))
          (should-not (memq 'display-buffer-at-bottom fns)))))))

(ert-deftest decknix-context-viewer/display-action-prefers-bottom ()
  "Placement splits the selected window, so it cannot change tab."
  (let ((captured nil))
    (cl-letf (((symbol-function 'display-buffer)
               (lambda (_buf action) (setq captured action) nil))
              ((symbol-function 'decknix--context-viewer-turns)
               (lambda (_) '(((role . "user") (text . "hi")))))
              ((symbol-function 'decknix--context-viewer-render)
               (lambda (_) nil))
              ((symbol-function 'decknix-agent-context-viewer-mode)
               (lambda () nil)))
      (with-temp-buffer
        (decknix-agent-context-viewer-open (current-buffer))
        (let ((fns (car captured)))
          ;; Splitting the SELECTED window cannot select another tab or
          ;; frame by construction -- the only placement that guarantees
          ;; the viewer lands where the user is looking.
          (should (memq 'display-buffer-below-selected fns)))))))

(provide 'decknix-agent-context-viewer-test)
;;; decknix-agent-context-viewer-test.el ends here
