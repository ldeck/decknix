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

;; --- the default is ON (pins a deliberate decision) ---

(ert-deftest decknix-resume-native--enabled-by-default ()
  "Resume restores context natively unless explicitly opted out.
Pinned because the opposite default shipped once, on the belief that the
`session/new' + continuation-primer path was faster.  It is not: the
primer is submitted the instant the session reports ready and tells the
model to re-read the transcript, so a whole model turn (and its tool
calls) elapses before the user can type.  Native resume costs one request
and no generation.  A future edit flipping this back should have to
delete this test and argue with the docstring first."
  (should (eq t (default-value 'decknix-agent-resume-load-full-context))))

(ert-deftest decknix-resume-native--toggle-flips-and-restores ()
  "Toggling is a pure inversion, so the sidebar label can trust it."
  (let ((decknix-agent-resume-load-full-context t))
    (decknix-agent-toggle-resume-full-context)
    (should-not decknix-agent-resume-load-full-context)
    (decknix-agent-toggle-resume-full-context)
    (should (eq t decknix-agent-resume-load-full-context))))

(provide 'decknix-agent-resume-native-test)
;;; decknix-agent-resume-native-test.el ends here
