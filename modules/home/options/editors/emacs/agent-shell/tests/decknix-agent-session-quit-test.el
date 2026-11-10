;;; decknix-agent-session-quit-test.el --- Windows after a session quits -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Auto-close (`C-c s x') quits a session from a timer, so the selected
;; window is wherever you went after arming it: usually the Review Board
;; the session was opened from.  The quit used to switch that window to
;; the next session, and `kill-buffer' put the board in the window the
;; session had been split into, so the two swapped places.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-shell-main-session)

(defvar decknix--agent-broker-key nil)

(unless (fboundp 'agent-shell-mode)
  (define-derived-mode agent-shell-mode fundamental-mode "Agent"))

(defmacro decknix-quit-test--with-layout (&rest body)
  "Run BODY with a board, a review session and another session, all live.
`board', `review' and `other' are bound; quitting confirms itself and no
broker is stopped."
  `(save-window-excursion
     (let* ((pop-up-windows t)
            (board (get-buffer-create "*Review Board*"))
            (review (generate-new-buffer "*Claude: acme/widgets review*"))
            (other (generate-new-buffer "*Claude: acme/other*"))
            (sessions (list review other)))
       (dolist (b (list review other))
         (with-current-buffer b (agent-shell-mode)))
       (unwind-protect
           (cl-letf (((symbol-function 'agent-shell-buffers)
                      (lambda () (seq-filter #'buffer-live-p sessions)))
                     ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                     ((symbol-function 'decknix--agent-broker-stop-p) #'ignore))
             (set-frame-size (selected-frame) 200 60)
             (delete-other-windows)
             (switch-to-buffer board)
             ,@body)
         (dolist (b (list board review other))
           (when (buffer-live-p b) (kill-buffer b)))))))

(defun decknix-quit-test--shown ()
  "Buffers on screen, in window order."
  (mapcar #'window-buffer (window-list nil 'nomini (frame-first-window))))

(defun decknix-quit-test--quit-from-timer (session)
  "Quit SESSION the way the auto-close timer does: current, not selected."
  (with-current-buffer session
    (call-interactively #'decknix-agent-session-quit)))

(ert-deftest decknix-quit--auto-close-leaves-the-board-where-it-was ()
  "Opened from the board with `j', armed, then back to the board."
  (decknix-quit-test--with-layout
   (let ((board-win (selected-window)))
     (pop-to-buffer review)
     (select-window board-win)
     (decknix-quit-test--quit-from-timer review)
     (should-not (buffer-live-p review))
     (should (equal (list board) (decknix-quit-test--shown)))
     (should (eq board-win (selected-window))))))

(ert-deftest decknix-quit--auto-close-in-a-window-of-its-own-history ()
  "The session's window had shown another session first: it gets it back,
and the board's window is untouched."
  (decknix-quit-test--with-layout
   (let ((board-win (selected-window))
         (win (split-window-right)))
     (set-window-buffer win other)
     (set-window-buffer win review)
     (decknix-quit-test--quit-from-timer review)
     (should (equal (list board other) (decknix-quit-test--shown)))
     (should (eq board-win (selected-window))))))

(ert-deftest decknix-quit--a-session-off-screen-moves-no-window ()
  (decknix-quit-test--with-layout
   (decknix-quit-test--quit-from-timer review)
   (should (equal (list board) (decknix-quit-test--shown)))))

(ert-deftest decknix-quit--quitting-a-session-opened-over-the-board-gives-it-back ()
  "`C-c s q' in a session that replaced the board gives the board back."
  (decknix-quit-test--with-layout
   (switch-to-buffer review)
   (call-interactively #'decknix-agent-session-quit)
   (should (equal (list board) (decknix-quit-test--shown)))))

(provide 'decknix-agent-session-quit-test)
;;; decknix-agent-session-quit-test.el ends here
