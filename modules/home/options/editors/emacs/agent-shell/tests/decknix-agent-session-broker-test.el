;;; decknix-agent-session-broker-test.el --- Tests for brokered-session helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-session-broker "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests for the PURE layer of the brokered-session foundation: the argv
;; wrap transform, the enable/provider gate, and key generation.  The
;; conv-key store mirrors decknix-agent-session-mode and is covered there.

;;; Code:

(require 'ert)
(require 'decknix-agent-session-broker)

(ert-deftest decknix-broker/wrap-command ()
  "A key wraps the argv as (WRAPPER KEY -- . ARGV)."
  (let ((decknix-agent-broker-attach-command "decknix-agent-broker-attach"))
    (should (equal (decknix--agent-broker-wrap-command '("claude-agent-acp") "s-abc")
                   '("decknix-agent-broker-attach" "s-abc" "--" "claude-agent-acp")))
    (should (equal (decknix--agent-broker-wrap-command
                    '("claude-agent-acp" "--workspace-root" "/w") "k")
                   '("decknix-agent-broker-attach" "k" "--"
                     "claude-agent-acp" "--workspace-root" "/w")))))

(ert-deftest decknix-broker/wrap-command-noop-without-key ()
  "A nil/blank key (or empty argv) leaves the command untouched — never drops it."
  (should (equal (decknix--agent-broker-wrap-command '("claude-agent-acp") nil)
                 '("claude-agent-acp")))
  (should (equal (decknix--agent-broker-wrap-command '("claude-agent-acp") "")
                 '("claude-agent-acp")))
  (should (equal (decknix--agent-broker-wrap-command '("claude-agent-acp") "  ")
                 '("decknix-agent-broker-attach" "  " "--" "claude-agent-acp"))) ; only blank-string check is emptiness
  (should (null (decknix--agent-broker-wrap-command nil "k"))))

(ert-deftest decknix-broker/should-wrap-p ()
  "Wrap only when enabled AND the provider is claude-code."
  (let ((decknix-agent-broker-enable t))
    (should (decknix--agent-broker-should-wrap-p 'claude-code))
    (should-not (decknix--agent-broker-should-wrap-p 'auggie))
    (should-not (decknix--agent-broker-should-wrap-p 'pi)))
  (let ((decknix-agent-broker-enable nil))
    (should-not (decknix--agent-broker-should-wrap-p 'claude-code))))

(ert-deftest decknix-broker/generate-key ()
  "Keys are non-empty, filename-safe, and unique across calls."
  (let ((k1 (decknix--agent-broker-generate-key))
        (k2 (decknix--agent-broker-generate-key)))
    (should (stringp k1))
    (should (> (length k1) 0))
    (should (string-match-p "\\`s-[0-9]+-[0-9a-f]+\\'" k1)) ; no slashes/spaces
    (should-not (equal k1 k2))))

(provide 'decknix-agent-session-broker-test)
;;; decknix-agent-session-broker-test.el ends here
