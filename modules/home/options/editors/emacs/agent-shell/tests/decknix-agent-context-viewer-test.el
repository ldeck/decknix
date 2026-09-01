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

;; -- display placement: stay on THIS frame/tab ------------------------
;;
;; Reported: `C-c s c' opened the viewer "against a different tab", so
;; finishing with it meant switching back, and the sidebar was hidden
;; while it was up.
;;
;; Measured cause: the sidebar is a DEDICATED SIDE window (side=left) and
;; the session runs with several frames open.  `display-buffer-at-bottom'
;; alone cannot always place a window against a side-window layout, and
;; when it fails `display-buffer' falls through to
;; `display-buffer-fallback-action' -- which reuses a window on ANOTHER
;; FRAME (or pops one), landing the viewer away from where you are.
;;
;; The action must therefore pin the lookup to the selected frame.

(ert-deftest decknix-context-viewer/display-action-never-leaves-this-frame ()
  "The display action forbids reusing a window on another frame."
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
        (let ((alist (cdr captured)))
          ;; nil reusable-frames = only this frame's windows are candidates.
          (should (assq 'reusable-frames alist))
          (should-not (alist-get 'reusable-frames alist))
          ;; and never raise/switch to a different frame.
          (should (alist-get 'inhibit-switch-frame alist)))))))

(ert-deftest decknix-context-viewer/display-action-prefers-bottom ()
  "Placement is still a bottom window, reusing one on this frame if present."
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
          (should (memq 'display-buffer-at-bottom fns))
          ;; reuse-window first so a viewer already open here is reused
          ;; rather than a second one being stacked below it.
          (should (memq 'display-buffer-reuse-window fns)))))))

(provide 'decknix-agent-context-viewer-test)
;;; decknix-agent-context-viewer-test.el ends here
