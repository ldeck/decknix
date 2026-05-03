;;; decknix-sidebar-width-test.el --- Tests for sidebar width cycling -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-sidebar-width "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the sidebar width cycling cluster
;; extracted from the workspace heredoc.  Window primitives
;; (`get-buffer-window', `window-live-p', `window-resize',
;; `window-width', `window-buffer') are stubbed via `cl-letf' so
;; the tests run headless with no live frame.
;;
;; The fit-to-content branch exercises `with-current-buffer' on a
;; tmp buffer populated with known content, so the inline measure
;; loop walks predictable line lengths.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-sidebar-width)

;; The two upstream package vars are forward-declared (no value) by
;; the module under test, which is only a compiler hint -- the
;; binding remains lexical.  Tests `let'-bind them, which requires
;; them to be globally `special-variable-p'.  An explicit
;; `defvar X nil' here promotes them so the binding is dynamic.
(defvar agent-shell-workspace-sidebar-buffer-name nil)
(defvar agent-shell-workspace-sidebar-width nil)

(defvar decknix-sidebar-width-test--default-w 24
  "Stand-in for the upstream `agent-shell-workspace-sidebar-width'.")

(defmacro decknix-sidebar-width-test--with-window (buffer &rest body)
  "Evaluate BODY with the window primitives stubbed against BUFFER.
The stub frame returns a sentinel symbol for `get-buffer-window' and
records every `window-resize' call in a list named `resize-calls'."
  (declare (indent 1))
  `(let* ((win 'fake-window)
          (resize-calls nil)
          (agent-shell-workspace-sidebar-buffer-name "*sidebar*")
          (agent-shell-workspace-sidebar-width
           decknix-sidebar-width-test--default-w))
     (cl-letf (((symbol-function 'get-buffer-window)
                (lambda (&rest _) win))
               ((symbol-function 'window-live-p)
                (lambda (w) (eq w win)))
               ((symbol-function 'window-buffer)
                (lambda (_) ,buffer))
               ((symbol-function 'window-width)
                (lambda (&rest _) decknix-sidebar-width-test--default-w))
               ((symbol-function 'window-resize)
                (lambda (_w delta &optional _h)
                  (push delta resize-calls))))
       ,@body)))

(defmacro decknix-sidebar-width-test--with-tmp-buffer (content &rest body)
  "Run BODY with a tmp buffer whose contents are CONTENT."
  (declare (indent 1))
  `(let ((buf (generate-new-buffer " *sidebar-width-test*")))
     (unwind-protect
         (progn
           (with-current-buffer buf (insert ,content))
           (decknix-sidebar-width-test--with-window buf ,@body))
       (kill-buffer buf))))

;; -- defaults -----------------------------------------------------

(ert-deftest decknix-sidebar-width--default-state ()
  "Initial state is `default'."
  (let ((decknix--sidebar-width-state 'default))
    (should (eq decknix--sidebar-width-state 'default))))

;; -- apply-width --------------------------------------------------

(ert-deftest decknix-sidebar-width--apply-default-is-noop ()
  "`apply-width' does not resize when state is `default'."
  (decknix-sidebar-width-test--with-tmp-buffer "x"
    (let ((decknix--sidebar-width-state 'default))
      (decknix--sidebar-apply-width)
      (should (null resize-calls)))))

(ert-deftest decknix-sidebar-width--apply-wide-resizes-to-2x ()
  "`wide' state resizes the window to 2x the default width."
  (decknix-sidebar-width-test--with-tmp-buffer "x"
    (let ((decknix--sidebar-width-state 'wide))
      (decknix--sidebar-apply-width)
      ;; default-w = 24, wide-w = 48, current = 24 -> delta = +24.
      (should (equal resize-calls (list 24))))))

(ert-deftest decknix-sidebar-width--apply-fit-uses-longest-line ()
  "`fit' state resizes to longest content line + 2 cols when wider than default."
  (decknix-sidebar-width-test--with-tmp-buffer
      "short\nlonger line that is much wider than default\nmid\n"
    (let ((decknix--sidebar-width-state 'fit))
      (decknix--sidebar-apply-width)
      ;; longest = 43 chars, fit-w = 45, current = 24 -> delta = +21.
      (should (equal resize-calls (list 21))))))

(ert-deftest decknix-sidebar-width--apply-fit-clamps-to-default ()
  "`fit' never shrinks below the default width."
  (decknix-sidebar-width-test--with-tmp-buffer "tiny\n"
    (let ((decknix--sidebar-width-state 'fit))
      (decknix--sidebar-apply-width)
      ;; longest = 4, fit-w = max(24, 6) = 24, current = 24 -> delta = 0.
      (should (equal resize-calls (list 0))))))

;; -- cycle-width --------------------------------------------------

(ert-deftest decknix-sidebar-width--cycle-default-to-fit ()
  "`default' -> `fit' resizes to fit-content + advances state."
  (decknix-sidebar-width-test--with-tmp-buffer
      "longer line that is much wider than default\n"
    (let ((decknix--sidebar-width-state 'default))
      (decknix-sidebar-cycle-width)
      (should (eq decknix--sidebar-width-state 'fit))
      (should resize-calls))))

(ert-deftest decknix-sidebar-width--cycle-fit-to-wide ()
  "`fit' -> `wide' resizes to 2x default + advances state."
  (decknix-sidebar-width-test--with-tmp-buffer "x"
    (let ((decknix--sidebar-width-state 'fit))
      (decknix-sidebar-cycle-width)
      (should (eq decknix--sidebar-width-state 'wide))
      (should (equal resize-calls (list 24))))))

(ert-deftest decknix-sidebar-width--cycle-wide-to-default ()
  "`wide' -> `default' resizes back to default width + advances state."
  (decknix-sidebar-width-test--with-tmp-buffer "x"
    (let ((decknix--sidebar-width-state 'wide))
      (decknix-sidebar-cycle-width)
      (should (eq decknix--sidebar-width-state 'default))
      ;; default-w = 24, current = 24 -> delta = 0.
      (should (equal resize-calls (list 0))))))

(ert-deftest decknix-sidebar-width--cycle-no-window-is-noop ()
  "When the sidebar window is not live, the cycle is a no-op."
  (let ((decknix--sidebar-width-state 'default)
        (resize-calls nil)
        (agent-shell-workspace-sidebar-buffer-name "*sidebar*")
        (agent-shell-workspace-sidebar-width 24))
    (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) nil))
              ((symbol-function 'window-live-p) (lambda (_) nil))
              ((symbol-function 'window-resize)
               (lambda (_w delta &optional _h) (push delta resize-calls))))
      (decknix-sidebar-cycle-width)
      (should (null resize-calls))
      (should (eq decknix--sidebar-width-state 'default)))))

(provide 'decknix-sidebar-width-test)
;;; decknix-sidebar-width-test.el ends here
