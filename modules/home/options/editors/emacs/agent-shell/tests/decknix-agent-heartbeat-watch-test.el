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

(ert-deftest decknix-hb--effective-threshold ()
  "Zero tool calls -> the shorter hung window; a tool in flight -> the stuck one."
  ;; no tool calls: hung window (but never longer than stuck)
  (should (= 180 (decknix--agent-hb-effective-threshold 0 600 180)))
  (should (= 200 (decknix--agent-hb-effective-threshold 0 200 999))) ; capped at stuck
  ;; tool(s) in flight: keep the generous stuck window
  (should (= 600 (decknix--agent-hb-effective-threshold 3 600 180)))
  (should (= 600 (decknix--agent-hb-effective-threshold 1 600 180))))

(ert-deftest decknix-hb--normalize-turn-end-noop-outside-agent-shell ()
  "Turn-end normalisation is a safe no-op outside an agent-shell buffer.
It must never touch state in a non-agent buffer (the advice fires on every
`agent-shell-heartbeat-stop', but the guard keeps it scoped)."
  (with-temp-buffer
    (setq-local shell-maker--busy t)
    ;; not derived from agent-shell-mode -> the guard should skip everything
    (decknix--agent-normalize-turn-end)
    (should (eq shell-maker--busy t))))

(provide 'decknix-agent-heartbeat-watch-test)
;;; decknix-agent-heartbeat-watch-test.el ends here
