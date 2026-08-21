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

;; -- Heartbeat owner resolution (turn-end targets the RIGHT buffer) --

(ert-deftest decknix-hb--owner-matches-by-identity ()
  "The owning buffer is the one whose state holds this very heartbeat object.
Identity, not equality: two heartbeats can be `equal' in content while
belonging to different sessions, and clearing the wrong one would wipe an
innocent session's turn state."
  (let* ((hb-a (list (cons :status 'started)))
         (hb-b (list (cons :status 'started)))  ; `equal' to hb-a, not `eq'
         (buf-a (generate-new-buffer " *hb-a*"))
         (buf-b (generate-new-buffer " *hb-b*"))
         (states (list (cons buf-a (list (cons :heartbeat hb-a)))
                       (cons buf-b (list (cons :heartbeat hb-b)))))
         (state-fn (lambda (b) (alist-get b states))))
    (unwind-protect
        (progn
          (should (equal hb-a hb-b))
          (should (eq (decknix--agent-heartbeat-owner
                       hb-a (list buf-a buf-b) state-fn)
                      buf-a))
          (should (eq (decknix--agent-heartbeat-owner
                       hb-b (list buf-a buf-b) state-fn)
                      buf-b)))
      (kill-buffer buf-a)
      (kill-buffer buf-b))))

(ert-deftest decknix-hb--owner-nil-when-unowned-or-missing ()
  "An unowned heartbeat, or none at all, resolves to nil (caller falls back)."
  (let* ((buf (generate-new-buffer " *hb*"))
         (states (list (cons buf (list (cons :heartbeat (list (cons :s 1)))))))
         (state-fn (lambda (b) (alist-get b states))))
    (unwind-protect
        (progn
          (should-not (decknix--agent-heartbeat-owner
                       (list (cons :s 2)) (list buf) state-fn))
          (should-not (decknix--agent-heartbeat-owner nil (list buf) state-fn)))
      (kill-buffer buf))))

(ert-deftest decknix-hb--owner-skips-dead-buffers ()
  "A killed buffer is never returned as the owner."
  (let* ((hb (list (cons :status 'started)))
         (dead (generate-new-buffer " *hb-dead*"))
         (state-fn (lambda (_b) (list (cons :heartbeat hb)))))
    (kill-buffer dead)
    (should-not (decknix--agent-heartbeat-owner hb (list dead) state-fn))))

(ert-deftest decknix-hb--normalize-in-buffer-noop-outside-agent-shell ()
  "The per-buffer clear is scoped to agent-shell buffers."
  (with-temp-buffer
    (setq-local shell-maker--busy t)
    (decknix--agent-normalize-turn-end-in-buffer (current-buffer))
    (should (eq shell-maker--busy t))))

(ert-deftest decknix-hb--normalize-in-buffer-tolerates-dead-buffer ()
  "Clearing a killed buffer is a no-op rather than an error."
  (let ((dead (generate-new-buffer " *hb-dead2*")))
    (kill-buffer dead)
    (should-not (decknix--agent-normalize-turn-end-in-buffer dead))))

(provide 'decknix-agent-heartbeat-watch-test)
;;; decknix-agent-heartbeat-watch-test.el ends here
