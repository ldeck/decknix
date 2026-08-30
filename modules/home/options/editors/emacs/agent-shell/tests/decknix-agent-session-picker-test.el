;;; decknix-agent-session-picker-test.el --- Tests for bulk saved-session restore pacing -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for the session-picker dispatch path that bulk-
;; restores saved sessions.  The picker is allowed to resume one saved
;; session immediately, but multi-select restore must hand each selected
;; session to the spawn queue so Claude/Pi bridge startup and transcript
;; rehydration happen in a paced FIFO drip instead of a CPU-thrashing
;; thundering herd.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-picker-selections)
(require 'decknix-agent-shell-main-session)

(defvar agent-shell-display-action nil)
(defvar decknix--session-picker-saved-map nil)
(defvar decknix--session-picker-live-map nil)
(defvar decknix--session-picker-previous-map nil)

(ert-deftest decknix-session-picker-dispatch--saved-session-is-enqueued-not-run-inline ()
  "Bulk restore routes saved sessions through the spawn queue."
  (let* ((cand "session-123")
         (session '((sessionId . "sid-123")
                    (firstUserMessage . "hello world")
                    (__workspace . "/tmp/ws")))
         (decknix--session-picker-saved-map (let ((h (make-hash-table :test 'equal)))
                                              (puthash cand session h)
                                              h))
         (decknix--session-picker-live-map nil)
         (decknix--session-picker-previous-map nil)
         (enqueued nil)
         (resumed nil))
    (cl-letf (((symbol-function 'decknix-agent-spawn-enqueue)
               (lambda (thunk)
                 (setq enqueued thunk)
                 0))
              ((symbol-function 'decknix--agent-session-resume)
               (lambda (&rest args)
                 (setq resumed args)
                 'resumed))
              ((symbol-function 'decknix--agent-conversation-key)
               (lambda (_) "conv-key"))
              ((symbol-function 'decknix--agent-session-display-name)
               (lambda (_) "session name"))
              ((symbol-function 'window-main-window)
               (lambda (&rest _) nil))
              ((symbol-function 'selected-frame)
               (lambda () 'frame))
              ((symbol-function 'window-live-p)
               (lambda (&rest _) nil))
              ((symbol-function 'select-window)
               (lambda (&rest _) nil)))
      (decknix--session-picker-dispatch cand)
      (should (functionp enqueued))
      (should-not resumed)
      (funcall enqueued)
      (should (equal '("sid-123" 2 "session name" "/tmp/ws" "conv-key")
                     resumed)))))

(provide 'decknix-agent-session-picker-test)
;;; decknix-agent-session-picker-test.el ends here
