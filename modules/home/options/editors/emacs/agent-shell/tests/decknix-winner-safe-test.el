;;; decknix-winner-safe-test.el --- Tests for decknix-winner-safe -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Reproduces the reported failure: a side window, as the sidebar is, and a
;; saved layout whose main window shows a buffer that has since been killed.

;;; Code:

(require 'ert)
(require 'decknix-winner-safe)

(defmacro decknix-winner-test--with-layout (&rest body)
  "Run BODY with `conf' a saved layout whose main window's buffer is dead."
  `(let ((side-buf (get-buffer-create "*decknix-side*"))
         (dead (get-buffer-create "*decknix-dead*"))
         (live (get-buffer-create "*decknix-live*")))
     (unwind-protect
         (progn
           (delete-other-windows)
           (switch-to-buffer dead)
           (display-buffer-in-side-window side-buf '((side . left) (window-width . 20)))
           (let ((conf (winner-conf)))
             (kill-buffer dead)
             (switch-to-buffer live)
             ,@body))
       (decknix-winner-safe-disable)
       (ignore-errors (delete-other-windows))
       (dolist (b (list side-buf dead live)) (when (buffer-live-p b) (kill-buffer b))))))

(ert-deftest decknix-winner-safe--the-unprotected-restore-signals ()
  "Guards the premise: without the fix this is the reported error."
  (decknix-winner-test--with-layout
   (decknix-winner-safe-disable)
   (should (condition-case err (progn (winner-set conf) nil)
             (error (string-match-p "main window" (error-message-string err)))))))

(ert-deftest decknix-winner-safe--an-unrestorable-layout-reports-nil ()
  "nil is what tells `winner-undo-this' to discard it and try the next."
  (decknix-winner-test--with-layout
   (decknix-winner-safe-enable)
   (should-not (winner-set conf))))

(ert-deftest decknix-winner-safe--undo-skips-the-dead-layout-to-a-usable-one ()
  "One press lands on the next restorable layout instead of erroring."
  (let ((good-buf (get-buffer-create "*decknix-good*")))
    (unwind-protect
        (decknix-winner-test--with-layout
         (switch-to-buffer good-buf)
         (let ((good (winner-conf)))
           (switch-to-buffer live)
           (decknix-winner-safe-enable)
           (let ((winner-pending-undo-ring (make-ring 5))
                 (winner-undo-counter 1)
                 (winner-undone-data (list (winner-win-data))))
             (ring-insert winner-pending-undo-ring good)
             (ring-insert winner-pending-undo-ring conf)
             (ring-insert winner-pending-undo-ring (winner-conf))
             (should (winner-undo-this))
             (should (eq good-buf (window-buffer (window-main-window))))
             (should (= 2 (ring-length winner-pending-undo-ring))))))
      (kill-buffer good-buf))))

(provide 'decknix-winner-safe-test)
;;; decknix-winner-safe-test.el ends here
