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

;; --- method resolution: `session/resume' OR `session/load' ---
;;
;; `resume-native-p' only ever asked about `session/resume', so a bridge
;; advertising `session/load' instead (pi) was treated as incapable and
;; fell through to the primer.  It is not incapable, it is differently
;; capable: `loadSession' calls `restoreSession', which spawns the pi CLI
;; with `--session <path>', so the MODEL really does get its context
;; back.  The resolver names which of the two calls to make.

(ert-deftest decknix-resume-method--prefers-resume-when-both ()
  "`session/resume' wins when a bridge advertises both.
It restores context WITHOUT replaying the transcript to the client, so it
composes with our own buffer prepopulation.  `session/load' replays, and
would double-render."
  (should (eq 'resume (decknix--agent-resume-native-method "sid" t t))))

(ert-deftest decknix-resume-method--load-when-only-load ()
  "Load capability alone still restores context natively (the pi case)."
  (should (eq 'load (decknix--agent-resume-native-method "sid" nil t))))

(ert-deftest decknix-resume-method--resume-when-only-resume ()
  "Resume capability alone -> resume (the claude-code case, unchanged)."
  (should (eq 'resume (decknix--agent-resume-native-method "sid" t nil))))

(ert-deftest decknix-resume-method--nil-without-any-capability ()
  "Neither capability -> nil, so the caller falls back to the primer."
  (should-not (decknix--agent-resume-native-method "sid" nil nil)))

(ert-deftest decknix-resume-method--nil-without-sid ()
  "No target id -> nothing to restore, whatever the bridge advertises."
  (should-not (decknix--agent-resume-native-method nil t t))
  (should-not (decknix--agent-resume-native-method "" t t)))

;; --- who replays history, us or the bridge ---
;;
;; Exactly one side must render the transcript.  Verified against pi-acp
;; 0.0.31: `loadSession' walks `proc.getMessages()' and emits a
;; `user_message_chunk' / assistant chunk per stored message, so on the
;; load path the BRIDGE renders and we must not.

(ert-deftest decknix-resume-replays--load-means-bridge-renders ()
  "On the load path the bridge replays, so we skip prepopulation."
  (should (decknix--agent-resume-bridge-replays-p 'load)))

(ert-deftest decknix-resume-replays--resume-means-we-render ()
  "On the resume path nothing is replayed to us, so we prepopulate."
  (should-not (decknix--agent-resume-bridge-replays-p 'resume)))

(ert-deftest decknix-resume-replays--no-native-means-we-render ()
  "No native restore at all -> the buffer would be empty; we prepopulate."
  (should-not (decknix--agent-resume-bridge-replays-p nil)))

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
               (lambda (&rest _) 'request))
              ;; The success path also arms the prompt-focus
              ;; subscription; stub it so these tests stay about
              ;; fragment routing alone.
              ((symbol-function 'agent-shell-subscribe-to)
               (lambda (&rest _) 'token))
              ((symbol-function 'agent-shell-unsubscribe)
               (lambda (&rest _) nil)))
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

(ert-deftest decknix-resume-native--resumed-fragment-written-after-finalize ()
  "The `✓ Resuming session' marker is written AFTER session-init finalizes.

Ordering is load-bearing, not cosmetic.  `agent-shell--finalize-session-init'
is what writes the setup sections (config options, models, modes,
commands), and those are folded into the collapsed `Agent shell setup'
group.  `agent-shell-ui' groups only fragments that follow the header
CONTIGUOUSLY, so writing this marker BEFORE finalize drops it into the
middle of that run: it then has to join the group, or split it in two.

Deferring the write past finalize puts the marker below the whole run,
which is what lets it stay visible at top level -- the thing the user
asked for.  A future edit that moves it back above finalize must fail
here rather than silently swallowing the marker into the group."
  (with-temp-buffer
    (let* ((buf (current-buffer))
           (order nil)
           (on-success nil))
      (cl-letf (((symbol-function 'agent-shell--state)
                 (lambda () (list (cons :buffer buf) (cons :client 'c))))
                ((symbol-function 'agent-shell--update-bootstrapping-fragment)
                 (lambda (&rest args) (push (plist-get args :block-id) order)))
                ((symbol-function 'agent-shell--update-fragment)
                 (lambda (&rest _) nil))
                ((symbol-function 'agent-shell--make-status-kind-label)
                 (lambda (&rest _) "OK"))
                ((symbol-function 'agent-shell--set-session-from-response)
                 (lambda (&rest _) nil))
                ((symbol-function 'agent-shell--finalize-session-init)
                 (lambda (&rest _) (push 'FINALIZE order)))
                ((symbol-function 'agent-shell--resolve-path) #'identity)
                ((symbol-function 'agent-shell-cwd) (lambda () "/tmp"))
                ((symbol-function 'agent-shell--mcp-servers) (lambda () nil))
                ((symbol-function 'acp-make-session-resume-request)
                 (lambda (&rest _) 'request))
                ((symbol-function 'agent-shell-subscribe-to) (lambda (&rest _) 'token))
                ((symbol-function 'agent-shell-unsubscribe) (lambda (&rest _) nil))
                ((symbol-function 'acp-send-request)
                 (lambda (&rest args) (setq on-success (plist-get args :on-success)))))
        (decknix--agent-resume-native-send "sid-1" nil #'ignore)
        (funcall on-success 'response))
      (let* ((seq (nreverse order))
             (finalize-at (seq-position seq 'FINALIZE))
             (marker-at (seq-position seq "resumed_session")))
        (should finalize-at)
        (should marker-at)
        (should (> marker-at finalize-at))))))

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

;; --- point lands ON the live prompt after a resume -----------------
;;
;; Upstream moves point to the prompt only when it had to CREATE one:
;;
;;   (unless comint-last-prompt
;;     (shell-maker-finish-output ...)
;;     (goto-char (point-max)))        ; <- inside the `unless'
;;   (agent-shell--emit-event :event 'prompt-ready)
;;
;; A resumed buffer already carries the early prompt emitted at shell
;; creation, so the branch is skipped and point is never moved.  On a
;; fresh session that is invisible -- the buffer is one screenful, so
;; wherever point sits, the prompt is right there.  On a resumed session
;; the transcript and the whole bootstrap sit between them: point stays
;; parked at the stale `<shell-maker-failed-command>' marker near the top
;; while the live prompt is tens of kB below.
;;
;; Observed: session 575e74dd, marker at 735, live prompt at 35010-35020.
;; The cursor sits in read-only output, so typing raises "Buffer is
;; read-only" and the session reads as ready-but-with-no-prompt.
;;
;; Point is the contract here, not scrolling. Emacs scrolls a window to
;; follow its point on the next redisplay, so putting point right is both
;; necessary and sufficient; forcing `window-start' as well would fight
;; the display engine.

(ert-deftest decknix-resume-focus--moves-point-to-the-prompt ()
  "Point lands at the live prompt, not wherever the resume left it."
  (with-temp-buffer
    (insert "banner\n<shell-maker-failed-command>\ntranscript\nClaude> ")
    (goto-char 3)
    (decknix--agent-resume-focus-prompt (current-buffer))
    (should (= (point) (point-max)))))

(ert-deftest decknix-resume-focus--tolerates-a-killed-buffer ()
  "A session closed mid-bootstrap must not error out of event dispatch."
  (let ((buf (generate-new-buffer " *decknix-focus-test*")))
    (kill-buffer buf)
    (should (progn (decknix--agent-resume-focus-prompt buf) t))))

(ert-deftest decknix-resume-focus--subscribes-to-init-finished ()
  "Focus waits for `init-finished', the LAST init event.
`prompt-ready' fires with set-model and set-session-mode still to come,
and each of those writes another fragment."
  (with-temp-buffer
    (let ((subscribed nil))
      (cl-letf (((symbol-function 'agent-shell-subscribe-to)
                 (lambda (&rest args)
                   (setq subscribed (plist-get args :event))
                   'token)))
        (decknix--agent-resume-focus-prompt-on-init (current-buffer)))
      (should (eq 'init-finished subscribed)))))

(ert-deftest decknix-resume-focus--fires-once-then-unsubscribes ()
  "One focus per session; a later `init-finished' must not yank point back."
  (with-temp-buffer
    (let ((handler nil) (unsubscribed nil) (focused 0))
      (cl-letf (((symbol-function 'agent-shell-subscribe-to)
                 (lambda (&rest args)
                   (setq handler (plist-get args :on-event))
                   'token))
                ((symbol-function 'agent-shell-unsubscribe)
                 (lambda (&rest _) (setq unsubscribed t)))
                ((symbol-function 'decknix--agent-resume-focus-prompt)
                 (lambda (&rest _) (cl-incf focused))))
        (decknix--agent-resume-focus-prompt-on-init (current-buffer))
        (should handler)
        (funcall handler '((:event . init-finished)))
        (funcall handler '((:event . init-finished)))
        (should (= 1 focused))
        (should unsubscribed)))))

(provide 'decknix-agent-resume-native-test)
;;; decknix-agent-resume-native-test.el ends here
