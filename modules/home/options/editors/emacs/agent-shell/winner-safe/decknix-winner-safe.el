;;; decknix-winner-safe.el --- Winner undo that skips layouts it cannot restore -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, frames

;;; Commentary:
;;
;; Walking window history with `winner-undo' kept failing with
;;
;;   delete-window: Attempt to delete main window of frame ...
;;
;; and doing nothing, so getting back to a usable layout took several
;; presses.  `winner-set' restores a saved layout and then deletes every
;; window whose buffer has since died.  Agent buffers die constantly --
;; restarts, detaches, every switch -- so most saved layouts contain some.
;; With the sidebar open the frame has a side window, the last ordinary
;; window is its MAIN window, and deleting that signals an error.
;;
;; Winner already knows what to do with a layout it cannot restore:
;; `winner-undo-this' discards it and tries the next one.  The error
;; escaped before it could, aborting the command after the history
;; pointer had already moved.  Treating the error as "cannot restore"
;; lets winner purge the dead entry and land on the next usable layout in
;; one press.

;;; Code:

(require 'winner)

(defun decknix--winner-set-safely (orig conf)
  "Call ORIG `winner-set' on CONF, answering nil if it cannot be restored."
  (condition-case nil
      (funcall orig conf)
    (error nil)))

;;;###autoload
(defun decknix-winner-safe-enable ()
  "Make `winner-undo' skip layouts that can no longer be restored."
  (advice-add 'winner-set :around #'decknix--winner-set-safely))

(defun decknix-winner-safe-disable ()
  "Undo `decknix-winner-safe-enable'."
  (advice-remove 'winner-set #'decknix--winner-set-safely))

(provide 'decknix-winner-safe)
;;; decknix-winner-safe.el ends here
