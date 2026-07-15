;;; decknix-agent-heartbeat-watch-test.el --- Tests for stuck-heartbeat watchdog -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification tests for `decknix--agent-hb-stuck-p' -- the pure
;; predicate deciding whether a running busy-heartbeat has leaked (dead
;; or orphaned request) and should be reclaimed.  The watchdog's buffer
;; iteration + heartbeat-stop side effects are exercised live; only the
;; decision is unit-tested here per AGENTS.md Rule 2.

;;; Code:

(require 'ert)
(require 'decknix-agent-heartbeat-watch)

(ert-deftest decknix-hb-watch--stuck-when-running-idle-past-threshold ()
  "Running, unchanged buffer, idle >= threshold -> stuck."
  (should (decknix--agent-hb-stuck-p t 42 42 100.0 700.0 600)))

(ert-deftest decknix-hb-watch--boundary-is-inclusive ()
  "Exactly THRESHOLD seconds idle counts as stuck."
  (should (decknix--agent-hb-stuck-p t 42 42 100.0 700.0 600)))

(ert-deftest decknix-hb-watch--not-stuck-before-threshold ()
  "Idle for less than THRESHOLD -> not yet stuck."
  (should-not (decknix--agent-hb-stuck-p t 42 42 100.0 650.0 600)))

(ert-deftest decknix-hb-watch--not-stuck-when-not-running ()
  "No live heartbeat -> never stuck (nothing to reclaim)."
  (should-not (decknix--agent-hb-stuck-p nil 42 42 100.0 700.0 600)))

(ert-deftest decknix-hb-watch--not-stuck-when-buffer-changed ()
  "Buffer output changed since last check -> working, not stuck."
  (should-not (decknix--agent-hb-stuck-p t 43 42 100.0 700.0 600)))

(ert-deftest decknix-hb-watch--not-stuck-when-idle-since-nil ()
  "No recorded idle start -> cannot be stuck yet."
  (should-not (decknix--agent-hb-stuck-p t 42 42 nil 700.0 600)))

(provide 'decknix-agent-heartbeat-watch-test)
;;; decknix-agent-heartbeat-watch-test.el ends here
