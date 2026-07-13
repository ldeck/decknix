;;; decknix-agent-resume-native-test.el --- Tests for native ACP resume -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification tests for `decknix--agent-resume-native-p' — the pure
;; predicate deciding whether a resumed session should be restored
;; natively over ACP `session/resume' (rather than started fresh via
;; `session/new').  The orchestration (the `:around' advice and the ACP
;; request) is exercised live; only the decision layer is unit-tested
;; here per AGENTS.md Rule 2.

;;; Code:

(require 'ert)
(require 'decknix-agent-resume-native)

;; --- true only when BOTH a target id and the resume capability hold ---

(ert-deftest decknix-resume-native--t-with-sid-and-cap ()
  "A pending session id plus advertised resume capability -> resume natively."
  (should (decknix--agent-resume-native-p "sid-1" t)))

(ert-deftest decknix-resume-native--nil-without-cap ()
  "No advertised `session/resume' capability -> never resume natively."
  (should-not (decknix--agent-resume-native-p "sid-1" nil)))

(ert-deftest decknix-resume-native--nil-without-sid ()
  "No pending target id -> nothing to resume, fall through to `session/new'."
  (should-not (decknix--agent-resume-native-p nil t))
  (should-not (decknix--agent-resume-native-p "" t)))

(ert-deftest decknix-resume-native--nil-when-neither ()
  "Neither id nor capability -> nil."
  (should-not (decknix--agent-resume-native-p nil nil)))

;; --- return value is a real boolean, not a truthy leak ---

(ert-deftest decknix-resume-native--returns-boolean ()
  "Predicate normalises to t/nil so callers can rely on `eq'."
  (should (eq t (decknix--agent-resume-native-p "sid" t)))
  (should (eq nil (decknix--agent-resume-native-p "sid" nil))))

(provide 'decknix-agent-resume-native-test)
;;; decknix-agent-resume-native-test.el ends here
