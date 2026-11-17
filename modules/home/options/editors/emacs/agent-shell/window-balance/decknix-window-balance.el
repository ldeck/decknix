;;; decknix-window-balance.el --- Balance the main windows, evenly per row and column -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, frames

;;; Commentary:
;;
;; `balance-windows' falls short in two ways here.
;;
;; With the agent sidebar open the frame has a left side window, and
;; balancing the whole frame resizes the sidebar along with everything
;; else.  Only the frame's main window (the area outside the side
;; windows) should be balanced.
;;
;; It also balances each window combination on its own.  Splitting a
;; column, then splitting the lower half again, nests the second split
;; inside the first when `window-combination-limit' is set (or a
;; package made the split that way), so the three rows come out at 1/2,
;; 1/4 and 1/4.  `decknix-balance-main-windows' counts every window
;; stacked along an axis, through nested combinations in the same
;; direction, and gives each the same share.

;;; Code:

(defun decknix--window-units (parent horizontal)
  "Return PARENT's descendants laid out along one axis, in order.
HORIZONTAL non-nil means side by side.  A child that is itself a
combination in the same direction is flattened into its own children,
so a nested split counts as the rows or columns it shows."
  (let (units (child (window-child parent)))
    (while child
      (if (and (not (window-live-p child))
               (eq (and (window-combined-p (window-child child) t) t)
                   (and horizontal t)))
          (setq units (append units (decknix--window-units child horizontal)))
        (setq units (append units (list child))))
      (setq child (window-next-sibling child)))
    units))

(defun decknix--even-split (win)
  "Give every row or column under internal window WIN an equal share.
Recurses into each unit, so nested combinations in the other direction
are evened out too."
  (unless (window-live-p win)
    (let* ((horizontal (window-combined-p (window-child win) t))
           (units (decknix--window-units win horizontal))
           (total (if horizontal (window-total-width win) (window-total-height win)))
           (target (/ total (length units))))
      (dolist (unit (butlast units))
        (let ((delta (- target (if horizontal
                                   (window-total-width unit)
                                 (window-total-height unit)))))
          (unless (zerop delta)
            (ignore-errors (window-resize unit delta horizontal t)))))
      (dolist (unit units) (decknix--even-split unit)))))

(defun decknix--balance-root (&optional frame)
  "Return the window to balance on FRAME: its main window when it has
side windows, else its root window."
  (if (window-with-parameter 'window-side nil frame)
      (window-main-window frame)
    (frame-root-window frame)))

;;;###autoload
(defun decknix-balance-main-windows (&optional all)
  "Balance the frame's main windows, leaving side windows at their size.
Nested splits in the same direction count as one row or column each, so
a 3x2 grid built by nested splits gets equal heights and widths.
With prefix argument ALL, run plain `balance-windows' on every window."
  (interactive "P")
  (if all
      (balance-windows)
    (let ((root (decknix--balance-root)))
      (unless (window-live-p root)
        (balance-windows root)
        (decknix--even-split root)))))

(provide 'decknix-window-balance)
;;; decknix-window-balance.el ends here
