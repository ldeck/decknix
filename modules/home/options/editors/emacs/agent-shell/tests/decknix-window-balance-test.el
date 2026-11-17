;;; decknix-window-balance-test.el --- Tests for decknix-window-balance -*- lexical-binding: t -*-

;;; Commentary:
;;
;; A 3x2 grid built by nested splits, which plain `balance-windows'
;; leaves at 1/2, 1/4, 1/4 per column, and a left side window standing in
;; for the agent sidebar, whose width balancing must not touch.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-window-balance)

(defmacro decknix-window-balance-test--fresh-frame (&rest body)
  "Run BODY on a 120x64 frame with a single window, restoring it after."
  (declare (indent 0))
  `(let ((side (get-buffer-create "*decknix-balance-side*")))
     (unwind-protect
         (progn
           (set-frame-size (selected-frame) 120 64)
           (ignore-errors (delete-other-windows))
           (delete-other-windows)
           ,@body)
       (ignore-errors (delete-window (get-buffer-window side)))
       (ignore-errors (delete-other-windows))
       (kill-buffer side))))

(defun decknix-window-balance-test--grid ()
  "Split the current window into two columns of three nested rows each.
Return the six windows."
  (let ((window-combination-limit t)
        (left (selected-window))
        (right (split-window-right)))
    (cl-loop for col in (list left right)
             append (let* ((mid (split-window col nil 'below))
                           (bottom (split-window mid nil 'below)))
                      (list col mid bottom)))))

(defun decknix-window-balance-test--spread (values)
  (- (apply #'max values) (apply #'min values)))

(ert-deftest decknix-window-balance--nested-grid-premise ()
  "Guards the premise: plain balancing leaves nested rows uneven."
  (decknix-window-balance-test--fresh-frame
    (let ((wins (decknix-window-balance-test--grid)))
      (balance-windows)
      (should (> (decknix-window-balance-test--spread
                  (mapcar #'window-total-height wins))
                 2)))))

(ert-deftest decknix-window-balance--nested-grid-is-even ()
  (decknix-window-balance-test--fresh-frame
    (let ((wins (decknix-window-balance-test--grid)))
      (decknix-balance-main-windows)
      (should (<= (decknix-window-balance-test--spread
                   (mapcar #'window-total-height wins))
                  1))
      (should (<= (decknix-window-balance-test--spread
                   (mapcar #'window-total-width wins))
                  1)))))

(ert-deftest decknix-window-balance--side-window-keeps-its-width ()
  (decknix-window-balance-test--fresh-frame
    (let ((wins (decknix-window-balance-test--grid))
          (side-win (display-buffer-in-side-window
                     side '((side . left) (window-width . 20)))))
      (let ((before (window-total-width side-win)))
        (decknix-balance-main-windows)
        (should (= before (window-total-width side-win)))
        (should (<= (decknix-window-balance-test--spread
                     (mapcar #'window-total-height wins))
                    1))
        (should (<= (decknix-window-balance-test--spread
                     (mapcar #'window-total-width wins))
                    1))))))

(ert-deftest decknix-window-balance--single-main-window-is-a-no-op ()
  (decknix-window-balance-test--fresh-frame
    (let ((side-win (display-buffer-in-side-window
                     side '((side . left) (window-width . 20)))))
      (let ((before (window-total-width side-win)))
        (decknix-balance-main-windows)
        (should (= before (window-total-width side-win)))))))

(ert-deftest decknix-window-balance--prefix-balances-everything ()
  (decknix-window-balance-test--fresh-frame
    (let ((called nil))
      (cl-letf (((symbol-function 'balance-windows)
                 (lambda (&rest args) (setq called (or args t)))))
        (decknix-balance-main-windows t))
      (should (eq called t)))))

(provide 'decknix-window-balance-test)
;;; decknix-window-balance-test.el ends here
