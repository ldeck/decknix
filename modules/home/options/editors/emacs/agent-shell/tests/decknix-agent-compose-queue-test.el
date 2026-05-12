;;; decknix-agent-compose-queue-test.el --- Tests for compose-queue policy -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-compose-queue'
;; (PR B.79).  Verifies the action-resolver's decision table
;; matches the original `decknix--compose-queue-poll' nesting.

;;; Code:

(require 'ert)
(require 'decknix-agent-compose-queue)

(ert-deftest decknix-compose-queue--dead-buffer-cancels ()
  "Dead buffer always returns `cancel-timer', regardless of other inputs."
  (should (equal '(:action cancel-timer)
                 (decknix--compose-queue-action "p" nil nil t)))
  (should (equal '(:action cancel-timer)
                 (decknix--compose-queue-action nil nil t t)))
  (should (equal '(:action cancel-timer)
                 (decknix--compose-queue-action "p" nil t nil))))

(ert-deftest decknix-compose-queue--no-queue-waits ()
  "Live buffer with nothing queued waits even when idle."
  (should (equal '(:action wait)
                 (decknix--compose-queue-action nil t nil t))))

(ert-deftest decknix-compose-queue--busy-waits ()
  "Live buffer with queued prompt but agent busy waits."
  (should (equal '(:action wait)
                 (decknix--compose-queue-action "p" t t t))))

(ert-deftest decknix-compose-queue--no-process-waits ()
  "Live buffer with queued prompt but dead process waits."
  (should (equal '(:action wait)
                 (decknix--compose-queue-action "p" t nil nil))))

(ert-deftest decknix-compose-queue--idle-and-queued-submits ()
  "Live buffer + queued + idle + live process -> submit with the input."
  (should (equal '(:action submit :input "hello world")
                 (decknix--compose-queue-action
                  "hello world" t nil t))))

(ert-deftest decknix-compose-queue--submit-preserves-input-string ()
  "Submit action returns the exact input string (not mutated)."
  (let* ((input "multi\nline\nprompt")
         (result (decknix--compose-queue-action input t nil t)))
    (should (eq input (plist-get result :input)))))

(ert-deftest decknix-compose-queue--empty-string-queue-still-submits ()
  "Empty-string queue is treated as queued (caller's responsibility to filter).
Documents the boundary: the policy doesn't second-guess the queue
contents, so an empty queued prompt would still trigger submit."
  (should (equal '(:action submit :input "")
                 (decknix--compose-queue-action "" t nil t))))

(provide 'decknix-agent-compose-queue-test)
;;; decknix-agent-compose-queue-test.el ends here
