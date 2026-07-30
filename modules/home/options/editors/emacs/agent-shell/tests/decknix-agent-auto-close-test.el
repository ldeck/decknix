;;; decknix-agent-auto-close-test.el --- Tests for auto-close -*- lexical-binding: t -*-

;; Author: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-auto-close "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests for the pure + status layer of session auto-close: countdown
;; remaining math, the countdown message, and the `closing' status injection.

;;; Code:

(require 'ert)
(require 'decknix-agent-auto-close)

(ert-deftest decknix-agent-auto-close/remaining ()
  "Remaining is whole seconds to the deadline, floored at 0."
  (should (= 60 (decknix--agent-auto-close-remaining 160.0 100.0)))
  (should (= 1  (decknix--agent-auto-close-remaining 100.6 100.0)))
  (should (= 0  (decknix--agent-auto-close-remaining 100.0 100.0)))
  (should (= 0  (decknix--agent-auto-close-remaining 90.0 100.0)))) ; past -> 0

(ert-deftest decknix-agent-auto-close/message ()
  "The countdown message names the seconds and how to keep it open."
  (let ((m (decknix--agent-auto-close-message 60)))
    (should (string-match-p "60s" m))
    (should (string-match-p "keep the session open" m))))

(ert-deftest decknix-agent-auto-close/closing-p-and-status ()
  "closing-p reflects the buffer phase; buffer-status injects \"closing\"."
  (with-temp-buffer
    (should-not (decknix-agent-closing-p (current-buffer)))
    (setq decknix--agent-auto-close-phase 'closing)
    (should (decknix-agent-closing-p (current-buffer)))
    (should (string= "closing" (decknix-agent-buffer-status (current-buffer))))
    ;; armed (not closing) does NOT report closing
    (setq decknix--agent-auto-close-phase 'armed)
    (should-not (decknix-agent-closing-p (current-buffer)))))

(provide 'decknix-agent-auto-close-test)
;;; decknix-agent-auto-close-test.el ends here
