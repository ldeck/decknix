;;; decknix-agent-session-bulk-dispatch-test.el --- Bulk dispatch routing -*- lexical-binding: t -*-

;;; Commentary:
;;
;; `decknix--session-bulk-dispatch' (`C-c s N', the network retry) must
;; queue a busy session rather than offer it an immediate submit, which
;; refuses a busy target silently.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-session-bulk-send)
(require 'decknix-agent-shell-main-session)

(ert-deftest decknix-session-bulk-dispatch--queues-a-busy-session ()
  "A busy session is enqueued; an idle one is submitted now."
  (let ((busy (generate-new-buffer " *test-dispatch-busy*"))
        (idle (generate-new-buffer " *test-dispatch-idle*"))
        sent queued)
    (unwind-protect
        (progn
          (with-current-buffer busy (setq-local shell-maker--busy t))
          (cl-letf (((symbol-function 'decknix--compose-submit-after-wait)
                     (lambda (buf _input) (push buf sent) t))
                    ((symbol-function 'decknix--compose-enqueue-prompt)
                     (lambda (buf _input) (push buf queued))))
            (decknix--session-bulk-dispatch (list busy idle) "continue"))
          (should (equal (list busy) queued))
          (should (equal (list idle) sent)))
      (mapc #'kill-buffer (list busy idle)))))

(provide 'decknix-agent-session-bulk-dispatch-test)
;;; decknix-agent-session-bulk-dispatch-test.el ends here
