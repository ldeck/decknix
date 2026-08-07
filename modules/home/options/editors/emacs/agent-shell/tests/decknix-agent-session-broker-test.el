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


;; -- session-id broker-key lookup (stable reattach link) ----------

(defun decknix-broker-test--entry (sessions broker-key)
  "Build a conversation ENTRY hash with SESSIONS list and BROKER-KEY."
  (let ((h (make-hash-table :test 'equal)))
    (puthash "sessions" sessions h)
    (when broker-key (puthash "brokerKey" broker-key h))
    h))

(defun decknix-broker-test--convs (&rest pairs)
  "Build a conversations hash from (CONV-KEY . ENTRY) PAIRS."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (p pairs) (puthash (car p) (cdr p) h))
    h))

(ert-deftest decknix-broker/scan-session-id--found ()
  "Returns the broker key of the entry listing the session id."
  (let ((convs (decknix-broker-test--convs
                (cons "ck1" (decknix-broker-test--entry '("sid-A") "s-1-aaa"))
                (cons "ck2" (decknix-broker-test--entry '("sid-B") "s-2-bbb")))))
    (should (equal (decknix--agent-broker-scan-key-for-session-id convs "sid-B")
                   "s-2-bbb"))))

(ert-deftest decknix-broker/scan-session-id--none ()
  "Returns nil when no entry lists the session id, or entry has no broker key."
  (let ((convs (decknix-broker-test--convs
                (cons "ck1" (decknix-broker-test--entry '("sid-A") "s-1-aaa"))
                (cons "ck2" (decknix-broker-test--entry '("sid-C") nil)))))
    (should (null (decknix--agent-broker-scan-key-for-session-id convs "sid-Z")))
    (should (null (decknix--agent-broker-scan-key-for-session-id convs "sid-C")))))

(ert-deftest decknix-broker/scan-session-id--prefers-earliest ()
  "The motivating case: a mis-keyed resume left TWO entries for one session.
Prefer the earliest (timestamp-ordered) key — the ORIGINAL broker holding it."
  (let ((convs (decknix-broker-test--convs
                ;; original write-time entry
                (cons "a55c" (decknix-broker-test--entry
                              '("sid-X") "s-20260807171714-075a8b7c41"))
                ;; entry left by the failed resume (later key)
                (cons "7ae0" (decknix-broker-test--entry
                              '("sid-X") "s-20260807172057-b848ec10a0")))))
    (should (equal (decknix--agent-broker-scan-key-for-session-id convs "sid-X")
                   "s-20260807171714-075a8b7c41"))))

(ert-deftest decknix-broker/scan-session-id--nil-convs ()
  "A nil/non-hash convs argument yields nil, not an error."
  (should (null (decknix--agent-broker-scan-key-for-session-id nil "sid")))
  (should (null (decknix--agent-broker-scan-key-for-session-id "x" "sid"))))

(provide 'decknix-agent-session-broker-test)
;;; decknix-agent-session-broker-test.el ends here
