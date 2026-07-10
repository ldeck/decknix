;;; decknix-agent-subagent-state-test.el --- Tests for sub-agent state -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification tests for `decknix-agent-subagent-state' — the pure
;; layer that derives a Claude sub-agent's coarse liveness state from
;; its transcript mtime plus parent liveness (#144).  All boundaries
;; are exercised with an injected NOW so no wall clock is touched.

;;; Code:

(require 'ert)
(require 'decknix-agent-subagent-state)

;; A fixed reference clock (arbitrary; well clear of the epoch).
(defconst decknix-subagent-test--now 1000000.0)

(defun decknix-subagent-test--agent (age-seconds)
  "Return a sub-agent alist whose `modified' is AGE-SECONDS before NOW.
The ISO-8601 string round-trips through `date-to-time' back to the
same instant the state function reads, so age arithmetic is exact."
  (let ((t- (seconds-to-time (- decknix-subagent-test--now age-seconds))))
    `((sessionId . "sub-1")
      (modified . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z" t-)))))

;; --- mtime parse ---

(ert-deftest decknix-subagent--mtime-nil-when-missing ()
  "Absent or unparseable `modified' yields nil (caller treats as done)."
  (should-not (decknix--agent-subagent-mtime nil))
  (should-not (decknix--agent-subagent-mtime '((sessionId . "x"))))
  (should-not (decknix--agent-subagent-mtime '((modified . ""))))
  (should-not (decknix--agent-subagent-mtime '((modified . "not-a-date")))))

(ert-deftest decknix-subagent--mtime-parses-iso ()
  "A valid ISO-8601 `modified' parses to a float-time."
  (should (floatp (decknix--agent-subagent-mtime
                   (decknix-subagent-test--agent 5)))))

;; --- state ladder ---

(ert-deftest decknix-subagent--fresh-and-parent-live-is-running ()
  "Written within the running window under a live parent -> running."
  (should (eq 'running
              (decknix--agent-subagent-state
               (decknix-subagent-test--agent 5)
               decknix-subagent-test--now t))))

(ert-deftest decknix-subagent--fresh-but-parent-dead-caps-at-active ()
  "A fresh mtime with no live parent cannot be running -> active."
  (should (eq 'active
              (decknix--agent-subagent-state
               (decknix-subagent-test--agent 5)
               decknix-subagent-test--now nil))))

(ert-deftest decknix-subagent--mid-window-is-active ()
  "Past the running window but within the active window -> active."
  (should (eq 'active
              (decknix--agent-subagent-state
               (decknix-subagent-test--agent 120)
               decknix-subagent-test--now t))))

(ert-deftest decknix-subagent--old-is-done ()
  "Older than the active window -> done, regardless of parent liveness."
  (should (eq 'done
              (decknix--agent-subagent-state
               (decknix-subagent-test--agent 5000)
               decknix-subagent-test--now t)))
  (should (eq 'done
              (decknix--agent-subagent-state
               (decknix-subagent-test--agent 5000)
               decknix-subagent-test--now nil))))

(ert-deftest decknix-subagent--unknown-mtime-is-done ()
  "A sub-agent with no parseable `modified' is treated as done."
  (should (eq 'done
              (decknix--agent-subagent-state
               '((sessionId . "x")) decknix-subagent-test--now t))))

(ert-deftest decknix-subagent--future-mtime-is-running ()
  "Clock skew (mtime slightly in the future) counts as freshest."
  (should (eq 'running
              (decknix--agent-subagent-state
               (decknix-subagent-test--agent -3)
               decknix-subagent-test--now t))))

;; --- thresholds are configurable ---

(ert-deftest decknix-subagent--windows-are-customisable ()
  "Boundaries follow the defcustoms, not hardcoded constants."
  (let ((decknix-agent-subagent-running-window 1)
        (decknix-agent-subagent-active-window 10))
    ;; 5s old now exceeds the 1s running window -> active, and...
    (should (eq 'active
                (decknix--agent-subagent-state
                 (decknix-subagent-test--agent 5)
                 decknix-subagent-test--now t)))
    ;; ...20s old exceeds the 10s active window -> done.
    (should (eq 'done
                (decknix--agent-subagent-state
                 (decknix-subagent-test--agent 20)
                 decknix-subagent-test--now t)))))

;; --- attention mapping (drives the row face) ---

(ert-deftest decknix-subagent--attention-mapping ()
  "State maps to the progress-layer attention symbol for the face."
  (should (eq 'green (decknix--agent-subagent-attention 'running)))
  (should (eq 'amber (decknix--agent-subagent-attention 'active)))
  (should (eq 'red   (decknix--agent-subagent-attention 'failed)))
  (should (eq 'none  (decknix--agent-subagent-attention 'done)))
  (should (eq 'none  (decknix--agent-subagent-attention nil)))
  (should (eq 'none  (decknix--agent-subagent-attention 'bogus))))

(provide 'decknix-agent-subagent-state-test)
;;; decknix-agent-subagent-state-test.el ends here
