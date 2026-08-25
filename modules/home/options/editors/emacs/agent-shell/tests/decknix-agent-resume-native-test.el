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
(require 'cl-lib)
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

;; --- every fragment lands ABOVE the live prompt (#read-only-stall) ---
;;
;; Regression guard.  `decknix--agent-resume-native-send' used to write
;; its bootstrapping fragments with a bare `agent-shell--update-fragment'
;; plus `:namespace-id "bootstrapping"'.  That is NOT equivalent to the
;; `agent-shell--update-bootstrapping-fragment' helper: the helper also
;; pins `:above-last-prompt t', and without it a fragment is inserted
;; inline at `point-max' -- below the live prompt, tagged `field output'.
;;
;; One such fragment is terminal.  `agent-shell--live-input-prompt-p' is
;; false as soon as ANY `field'-`output' text sits past the prompt, so
;; every later bootstrapping fragment (the config-options dump, "Setting
;; session mode ... Done") also falls through to the inline path and
;; piles up below the prompt.  The session reports ready, `point-max' is
;; read-only output, and the prompt is stranded ~25kB up the buffer with
;; nothing to type into.
;;
;; These tests assert routing, not rendering: the helper is the contract.

(defun decknix-resume-native-test--capture-fragment-calls (thunk)
  "Run THUNK with fragment writers stubbed; return (BOOTSTRAP . RAW).
BOOTSTRAP is the list of `:block-id's sent through
`agent-shell--update-bootstrapping-fragment'; RAW is the list sent
through the bare `agent-shell--update-fragment' (which must stay empty)."
  (let ((bootstrap nil)
        (raw nil))
    (cl-letf (((symbol-function 'agent-shell--update-bootstrapping-fragment)
               (lambda (&rest args) (push (plist-get args :block-id) bootstrap)))
              ((symbol-function 'agent-shell--update-fragment)
               (lambda (&rest args) (push (plist-get args :block-id) raw)))
              ((symbol-function 'agent-shell--make-status-kind-label)
               (lambda (&rest _) "OK"))
              ((symbol-function 'agent-shell--set-session-from-response)
               (lambda (&rest _) nil))
              ((symbol-function 'agent-shell--finalize-session-init)
               (lambda (&rest _) nil))
              ((symbol-function 'agent-shell--resolve-path) #'identity)
              ((symbol-function 'agent-shell-cwd) (lambda () "/tmp"))
              ((symbol-function 'agent-shell--mcp-servers) (lambda () nil))
              ((symbol-function 'acp-make-session-resume-request)
               (lambda (&rest _) 'request)))
      (funcall thunk))
    (cons (nreverse bootstrap) (nreverse raw))))

(ert-deftest decknix-resume-native--start-fragment-goes-above-prompt ()
  "The \"Resuming session...\" fragment routes through the bootstrapping helper.
Bare `agent-shell--update-fragment' would land it below the live prompt."
  (with-temp-buffer
    (let* ((buf (current-buffer))
           (captured
            (decknix-resume-native-test--capture-fragment-calls
             (lambda ()
               (cl-letf (((symbol-function 'agent-shell--state)
                          (lambda () (list (cons :buffer buf) (cons :client 'c))))
                         ((symbol-function 'acp-send-request) (lambda (&rest _) nil)))
                 (decknix--agent-resume-native-send "sid-1" nil #'ignore))))))
      (should (member "starting" (car captured)))
      (should-not (cdr captured)))))

(ert-deftest decknix-resume-native--resumed-fragment-goes-above-prompt ()
  "The \"✓ Resuming session\" success fragment also routes through the helper.
This is the exact fragment that stranded the prompt: it is the FIRST
thing written after the replayed transcript, so misplacing it drags the
entire remaining bootstrap below the prompt with it."
  (with-temp-buffer
    (let* ((buf (current-buffer))
           (on-success nil)
           (captured
            (decknix-resume-native-test--capture-fragment-calls
             (lambda ()
               (cl-letf (((symbol-function 'agent-shell--state)
                          (lambda () (list (cons :buffer buf) (cons :client 'c))))
                         ((symbol-function 'acp-send-request)
                          (lambda (&rest args)
                            (setq on-success (plist-get args :on-success)))))
                 (decknix--agent-resume-native-send "sid-1" nil #'ignore)
                 (should on-success)
                 (funcall on-success 'response))))))
      (should (member "resumed_session" (car captured)))
      (should-not (cdr captured)))))

(ert-deftest decknix-resume-native--failure-fragment-goes-above-prompt ()
  "The resume-failure notice routes through the helper too."
  (with-temp-buffer
    (let* ((buf (current-buffer))
           (on-failure nil)
           (fell-back nil)
           (captured
            (decknix-resume-native-test--capture-fragment-calls
             (lambda ()
               (cl-letf (((symbol-function 'agent-shell--state)
                          (lambda () (list (cons :buffer buf) (cons :client 'c))))
                         ((symbol-function 'acp-send-request)
                          (lambda (&rest args)
                            (setq on-failure (plist-get args :on-failure)))))
                 (decknix--agent-resume-native-send
                  "sid-1" nil (lambda (&rest _) (setq fell-back t)))
                 (should on-failure)
                 (funcall on-failure 'err 'raw))))))
      (should (member "starting" (car captured)))
      (should fell-back)
      (should-not (cdr captured)))))

(provide 'decknix-agent-resume-native-test)
;;; decknix-agent-resume-native-test.el ends here
