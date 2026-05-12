;;; decknix-agent-workspace-persist-test.el --- Tests for workspace-persist policy -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-workspace-persist'
;; (PR B.81).

;;; Code:

(require 'ert)
(require 'decknix-agent-workspace-persist)

;; --- persist-decision ---

(ert-deftest decknix-workspace-persist--no-op-when-already-persisted ()
  "Persisted workspace returns no-op even with a valid candidate ws."
  (should (equal '(:action no-op)
                 (decknix--workspace-persist-decision
                  "/tmp/proj" t nil))))

(ert-deftest decknix-workspace-persist--no-op-when-ws-nil ()
  "Nil workspace returns no-op."
  (should (equal '(:action no-op)
                 (decknix--workspace-persist-decision nil nil nil))))

(ert-deftest decknix-workspace-persist--no-op-when-ws-empty ()
  "Empty-string workspace returns no-op."
  (should (equal '(:action no-op)
                 (decknix--workspace-persist-decision "" nil nil))))

(ert-deftest decknix-workspace-persist--no-op-when-ws-not-string ()
  "Non-string workspace returns no-op (defensive)."
  (should (equal '(:action no-op)
                 (decknix--workspace-persist-decision 42 nil nil))))

(ert-deftest decknix-workspace-persist--install-when-fresh ()
  "Fresh buffer with valid ws and no pending stash: install + stash WS."
  (should (equal '(:action install :stash "/tmp/proj")
                 (decknix--workspace-persist-decision
                  "/tmp/proj" nil nil))))

(ert-deftest decknix-workspace-persist--install-without-stash-when-pending ()
  "Valid ws but a pending workspace already stashed by guided
post-create: install hook only, do not overwrite the stash."
  (should (equal '(:action install :stash nil)
                 (decknix--workspace-persist-decision
                  "/tmp/proj" nil t))))

(ert-deftest decknix-workspace-persist--persisted-wins-over-pending ()
  "Already-persisted dominates pending-set-p."
  (should (equal '(:action no-op)
                 (decknix--workspace-persist-decision
                  "/tmp/proj" t t))))

;; --- ring-first-message ---

(ert-deftest decknix-workspace-persist--ring-empty-returns-nil ()
  "Zero-length ring yields nil regardless of the lookup fn."
  (should-not (decknix--workspace-ring-first-message
               0 (lambda (_idx) "anything"))))

(ert-deftest decknix-workspace-persist--ring-negative-length-returns-nil ()
  "Negative / nil ring length returns nil (defensive)."
  (should-not (decknix--workspace-ring-first-message
               -1 (lambda (_idx) "x")))
  (should-not (decknix--workspace-ring-first-message
               nil (lambda (_idx) "x"))))

(ert-deftest decknix-workspace-persist--ring-bad-fn-returns-nil ()
  "Non-function RING-REF-FN returns nil."
  (should-not (decknix--workspace-ring-first-message 5 nil))
  (should-not (decknix--workspace-ring-first-message 5 "not-a-fn")))

(ert-deftest decknix-workspace-persist--ring-fetches-oldest ()
  "Ring of length N looks up index (1- N) -- the oldest entry."
  (let ((seen-idx nil))
    (decknix--workspace-ring-first-message
     5 (lambda (idx) (setq seen-idx idx) "first message"))
    (should (= 4 seen-idx))))

(ert-deftest decknix-workspace-persist--ring-returns-string ()
  "Non-empty string lookup is returned verbatim."
  (should (equal "hello"
                 (decknix--workspace-ring-first-message
                  3 (lambda (_idx) "hello")))))

(ert-deftest decknix-workspace-persist--ring-empty-string-yields-nil ()
  "Empty-string lookup is treated as no first message."
  (should-not (decknix--workspace-ring-first-message
               3 (lambda (_idx) ""))))

(ert-deftest decknix-workspace-persist--ring-non-string-yields-nil ()
  "Non-string lookup (defensive) yields nil."
  (should-not (decknix--workspace-ring-first-message
               3 (lambda (_idx) nil)))
  (should-not (decknix--workspace-ring-first-message
               3 (lambda (_idx) 42))))

(provide 'decknix-agent-workspace-persist-test)
;;; decknix-agent-workspace-persist-test.el ends here
