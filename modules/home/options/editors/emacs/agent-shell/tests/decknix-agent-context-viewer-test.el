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

(provide 'decknix-agent-context-viewer-test)
;;; decknix-agent-context-viewer-test.el ends here
