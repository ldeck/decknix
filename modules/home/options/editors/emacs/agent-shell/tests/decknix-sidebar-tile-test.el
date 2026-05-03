;;; decknix-sidebar-tile-test.el --- Tests for sidebar tile-cycle helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-sidebar-tile "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the tile-cycle module extracted
;; from the workspace heredoc.  Stubs the upstream agent-shell tile
;; primitives via `cl-letf' so the tests exercise the pure logic
;; (cycle progression, target capping, idempotent re-engagement)
;; without ever opening a real sidebar window.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Stub the upstream symbols before the tile module loads so the
;; declare-functions resolve at byte-compile time.  Tests rebind
;; them via cl-letf where they need a specific behaviour.
(unless (fboundp 'agent-shell-buffers)
  (defun agent-shell-buffers () nil))
(unless (fboundp 'agent-shell-workspace--tile)
  (defun agent-shell-workspace--tile (_buffers) nil))
(unless (fboundp 'agent-shell-workspace--untile)
  (defun agent-shell-workspace--untile () nil))
(unless (fboundp 'agent-shell-workspace-sidebar-refresh)
  (defun agent-shell-workspace-sidebar-refresh () nil))
(defvar agent-shell-workspace-sidebar-buffer-name " *agent-shell-sidebar-test*")

(require 'decknix-sidebar-tile)

(defmacro decknix-sidebar-tile-test--with-state (&rest body)
  "Evaluate BODY with `decknix--sidebar-tile-count' reset to 0."
  (declare (indent 0))
  `(let ((decknix--sidebar-tile-count 0))
     ,@body))

;; -- defaults ------------------------------------------------------

(ert-deftest decknix-sidebar-tile--defaults ()
  "Tile count defaults to 0 (off)."
  (decknix-sidebar-tile-test--with-state
    (should (= decknix--sidebar-tile-count 0))))

;; -- cycle progression --------------------------------------------

(ert-deftest decknix-sidebar-tile--cycle-progression ()
  "Cycle walks 0 -> 2 -> 3 -> 4 -> 0 deterministically.
Wrapped in cl-letf so the tile/untile/refresh side-effects no-op."
  (decknix-sidebar-tile-test--with-state
    (cl-letf (((symbol-function 'agent-shell-buffers)
               (lambda () nil))
              ((symbol-function 'agent-shell-workspace--tile)
               (lambda (_bufs) nil))
              ((symbol-function 'agent-shell-workspace--untile)
               (lambda () nil))
              ((symbol-function 'agent-shell-workspace-sidebar-refresh)
               (lambda () nil)))
      (call-interactively #'decknix-sidebar-tile-cycle)
      (should (= decknix--sidebar-tile-count 2))
      (call-interactively #'decknix-sidebar-tile-cycle)
      (should (= decknix--sidebar-tile-count 3))
      (call-interactively #'decknix-sidebar-tile-cycle)
      (should (= decknix--sidebar-tile-count 4))
      (call-interactively #'decknix-sidebar-tile-cycle)
      (should (= decknix--sidebar-tile-count 0)))))

;; -- current-count reader -----------------------------------------

(ert-deftest decknix-sidebar-tile--current-count-no-buffer ()
  "Current count is 0 when the sidebar buffer doesn't exist."
  (let ((agent-shell-workspace-sidebar-buffer-name
         " *no-such-sidebar-buffer*"))
    (should (= 0 (decknix--sidebar-tile-current-count)))))

(ert-deftest decknix-sidebar-tile--current-count-not-tiled ()
  "Current count is 0 when the sidebar exists but is not tiled."
  (let* ((bn " *tile-test-sidebar*")
         (agent-shell-workspace-sidebar-buffer-name bn)
         (sb (get-buffer-create bn)))
    (unwind-protect
        (progn
          (with-current-buffer sb
            (setq-local agent-shell-workspace--tiled nil))
          (should (= 0 (decknix--sidebar-tile-current-count))))
      (when (buffer-live-p sb) (kill-buffer sb)))))

(ert-deftest decknix-sidebar-tile--current-count-tiled ()
  "Current count returns the length of `--tiled-buffers' when tiled."
  (let* ((bn " *tile-test-sidebar*")
         (agent-shell-workspace-sidebar-buffer-name bn)
         (sb (get-buffer-create bn)))
    (unwind-protect
        (progn
          (with-current-buffer sb
            (setq-local agent-shell-workspace--tiled t)
            (setq-local agent-shell-workspace--tiled-buffers
                        (list 'a 'b 'c)))
          (should (= 3 (decknix--sidebar-tile-current-count))))
      (when (buffer-live-p sb) (kill-buffer sb)))))

;; -- apply caps ---------------------------------------------------

(ert-deftest decknix-sidebar-tile--apply-caps-at-live-count ()
  "Apply caps at the live buffer count when N exceeds it."
  (let ((b1 (generate-new-buffer " *tile-bufA*"))
        (b2 (generate-new-buffer " *tile-bufB*"))
        (called-with nil))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-buffers)
                   (lambda () (list b1 b2)))
                  ((symbol-function 'agent-shell-workspace--tile)
                   (lambda (bufs) (setq called-with bufs))))
          ;; Asking for 4 with only 2 live buffers -> tile 2.
          (should (= 2 (decknix--sidebar-tile-apply 4)))
          (should (= 2 (length called-with))))
      (kill-buffer b1) (kill-buffer b2))))

(ert-deftest decknix-sidebar-tile--apply-no-tile-when-under-two ()
  "Apply does NOT call `--tile' when the target ends up <2."
  (let ((b1 (generate-new-buffer " *tile-bufA*"))
        (called nil))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-buffers)
                   (lambda () (list b1)))
                  ((symbol-function 'agent-shell-workspace--tile)
                   (lambda (_bufs) (setq called t))))
          ;; Asking for 4 with only 1 live buffer -> 1 returned, no tile call.
          (should (= 1 (decknix--sidebar-tile-apply 4)))
          (should-not called))
      (kill-buffer b1))))

;; -- maybe-apply-tile-pref hook -----------------------------------

(ert-deftest decknix-sidebar-tile--maybe-apply-noop-when-zero ()
  "The auto-engage hook is a no-op when desired count is 0."
  (let ((decknix--sidebar-tile-count 0)
        (called nil))
    (cl-letf (((symbol-function 'agent-shell-buffers)
               (lambda () (list 'a 'b 'c)))
              ((symbol-function 'decknix--sidebar-tile-apply)
               (lambda (_n) (setq called t) 0)))
      (decknix--sidebar-maybe-apply-tile-pref)
      (should-not called))))

(ert-deftest decknix-sidebar-tile--maybe-apply-engages-on-mismatch ()
  "Hook calls `apply' when current layout differs from desired count."
  (let ((b1 (generate-new-buffer " *tile-bufA*"))
        (b2 (generate-new-buffer " *tile-bufB*"))
        (decknix--sidebar-tile-count 2)
        (apply-arg nil))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-buffers)
                   (lambda () (list b1 b2)))
                  ((symbol-function 'decknix--sidebar-tile-current-count)
                   (lambda () 0))
                  ((symbol-function 'decknix--sidebar-tile-apply)
                   (lambda (n) (setq apply-arg n) n)))
          (decknix--sidebar-maybe-apply-tile-pref)
          (should (= 2 apply-arg)))
      (kill-buffer b1) (kill-buffer b2))))

(ert-deftest decknix-sidebar-tile--maybe-apply-noop-when-matched ()
  "Hook is a no-op when current layout already matches desired count."
  (let ((b1 (generate-new-buffer " *tile-bufA*"))
        (b2 (generate-new-buffer " *tile-bufB*"))
        (decknix--sidebar-tile-count 2)
        (called nil))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-buffers)
                   (lambda () (list b1 b2)))
                  ((symbol-function 'decknix--sidebar-tile-current-count)
                   (lambda () 2))
                  ((symbol-function 'decknix--sidebar-tile-apply)
                   (lambda (_n) (setq called t) 0)))
          (decknix--sidebar-maybe-apply-tile-pref)
          (should-not called))
      (kill-buffer b1) (kill-buffer b2))))

(provide 'decknix-sidebar-tile-test)
;;; decknix-sidebar-tile-test.el ends here
