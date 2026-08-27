;;; decknix-agent-net-error-test.el --- Tests for transient network-failure sensing -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification tests for ldeck/decknix#162 — a session whose turn died
;; on a transient network/API failure ("API Error: Unable to connect to
;; API (ECONNRESET)") must be OBSERVABLE as `error' rather than sitting
;; indistinguishable from a healthy idle session, and every such session
;; must be resettable/retryable in one action once the link is back.
;;
;; Only the pure judgement is tested here: the detection predicate, the
;; status refinement, and the retry partition.  The advice/dispatch
;; wiring lives in the heredoc per AGENTS.md Rule 2.
;;
;; The single most important property under test is the FALSE-POSITIVE
;; guard: an agent that merely *discusses* ECONNRESET (a code review, a
;; postmortem, this very issue) must not be flagged.  Only a reported
;; error that the turn ENDED on counts.

;;; Code:

(require 'ert)
(require 'decknix-agent-net-error)

;; ---------------------------------------------------------------------
;; Detection — what a dead turn looks like
;; ---------------------------------------------------------------------

(ert-deftest decknix-net-error--nil-and-empty ()
  "Nothing to scan reports no failure."
  (should-not (decknix--agent-net-error-p nil))
  (should-not (decknix--agent-net-error-p ""))
  (should-not (decknix--agent-net-error-p "   \n\n \t ")))

(ert-deftest decknix-net-error--the-observed-failure ()
  "The exact line that wedged a real session (#162) is detected."
  (should (decknix--agent-net-error-p
           "API Error: Unable to connect to API (ECONNRESET)")))

(ert-deftest decknix-net-error--returns-the-offending-line ()
  "Detection returns the matched line so callers can report it."
  (should (equal (decknix--agent-net-error-p
                  "API Error: Unable to connect to API (ECONNRESET)")
                 "API Error: Unable to connect to API (ECONNRESET)")))

(ert-deftest decknix-net-error--dns-and-refused ()
  "The other transient link failures are the same class of dead turn."
  (should (decknix--agent-net-error-p
           "API Error: Unable to connect to API (ENOTFOUND)"))
  (should (decknix--agent-net-error-p
           "API Error: Unable to connect to API (ECONNREFUSED)"))
  (should (decknix--agent-net-error-p
           "API Error: Unable to connect to API (ETIMEDOUT)"))
  (should (decknix--agent-net-error-p
           "API Error: Connection error (EAI_AGAIN)")))

(ert-deftest decknix-net-error--socket-hang-up-and-fetch-failed ()
  "Node-side transport failures carry no errno but are the same fault."
  (should (decknix--agent-net-error-p "API Error: socket hang up"))
  (should (decknix--agent-net-error-p "Request failed: fetch failed")))

(ert-deftest decknix-net-error--transient-http-status ()
  "A 5xx / 429 / 408 from the API is transient — retrying is the fix."
  (should (decknix--agent-net-error-p "API Error: 529 Overloaded"))
  (should (decknix--agent-net-error-p "API Error: 503 Service Unavailable"))
  (should (decknix--agent-net-error-p "API Error: 429 rate_limit_error"))
  ;; A 4xx that is NOT transient must not be swept in: retrying a 401
  ;; forever is exactly the wedge we are trying to end.
  (should-not (decknix--agent-net-error-p "API Error: 401 authentication_error"))
  (should-not (decknix--agent-net-error-p "API Error: 400 invalid_request_error")))

(ert-deftest decknix-net-error--leading-decoration-tolerated ()
  "agent-shell decorates its error fragments; the line still matches."
  (should (decknix--agent-net-error-p "  ⚠ API Error: Unable to connect to API (ECONNRESET)"))
  (should (decknix--agent-net-error-p "> API Error: socket hang up")))

;; ---------------------------------------------------------------------
;; False positives — the guard that makes this safe to act on
;; ---------------------------------------------------------------------

(ert-deftest decknix-net-error--prose-mentioning-errno-is-not-a-failure ()
  "Talking ABOUT a network error is not having one.

This is the load-bearing guard: the session that motivated #162 spent
its final turns discussing ECONNRESET, and a bare errno search would
flag every agent that reviews retry code, writes a postmortem, or reads
this very issue — then bulk-send `continue' into healthy sessions."
  (should-not (decknix--agent-net-error-p
               "The retry path handles ECONNRESET by backing off."))
  (should-not (decknix--agent-net-error-p
               "I added ENOTFOUND and ECONNREFUSED to the pattern list."))
  (should-not (decknix--agent-net-error-p
               "Why did we see socket hang up here?")))

(ert-deftest decknix-net-error--fenced-code-is-not-a-failure ()
  "An errno inside a code fence is source, not an incident."
  (should-not (decknix--agent-net-error-p
               "Here is the matcher:\n```\nAPI Error: Unable to connect to API (ECONNRESET)\n```\n")))

(ert-deftest decknix-net-error--must-end-the-turn ()
  "An error the turn RECOVERED from is not a dead turn.

A failure followed by real work means the agent carried on; only a turn
that stopped on the error is stuck and wants a retry."
  (should-not (decknix--agent-net-error-p
               (concat "API Error: Unable to connect to API (ECONNRESET)\n"
                       "Retrying...\n"
                       "Done — the fix is committed as abc1234.\n"
                       "All 42 tests pass and the build is green.\n"
                       "Next I will update the README.\n"))))

(ert-deftest decknix-net-error--trailing-blank-lines-tolerated ()
  "Trailing whitespace after the error does not hide it."
  (should (decknix--agent-net-error-p
           "API Error: Unable to connect to API (ECONNRESET)\n\n   \n")))

(ert-deftest decknix-net-error--scans-only-the-tail ()
  "Only the last few lines are considered, so a long turn is O(1) to judge."
  (let ((decknix-agent-net-error-tail-lines 3))
    (should (decknix--agent-net-error-p
             "line a\nline b\nAPI Error: socket hang up\n"))
    (should-not (decknix--agent-net-error-p
                 "API Error: socket hang up\nline b\nline c\nline d\n"))))

;; ---------------------------------------------------------------------
;; Status refinement — how a dead session reports itself
;; ---------------------------------------------------------------------

(ert-deftest decknix-net-error--refines-settled-statuses ()
  "A flagged session reports `netfail' instead of looking healthy.
`working' is included deliberately: the observed wedge left the shell
reporting a turn still in flight that was never coming back."
  (dolist (raw '("ready" "finished" "asking" "working" "idle" "unknown"))
    (should (equal (decknix-agent-net-error-refine-status raw t)
                   decknix-agent-net-error-status))))

(ert-deftest decknix-net-error--never-refines-without-the-flag ()
  "An unflagged session is returned untouched."
  (dolist (raw '("ready" "finished" "asking" "working" "waiting" "killed"))
    (should (equal (decknix-agent-net-error-refine-status raw nil) raw))))

(ert-deftest decknix-net-error--leaves-waiting-and-killed-alone ()
  "`waiting' and `killed' are truths a retry cannot change.

`waiting' is a live permission prompt you must answer — relabelling it
would hide a real block.  `killed' is a dead process: it needs a
restart, not a `continue'."
  (should (equal (decknix-agent-net-error-refine-status "waiting" t) "waiting"))
  (should (equal (decknix-agent-net-error-refine-status "killed" t) "killed")))

(ert-deftest decknix-net-error--classifies-as-error-state ()
  "`netfail' is wired to the classifier's `error' state, not left unmapped."
  (skip-unless (fboundp 'decknix-session-classify-status))
  (should (eq (decknix-session-state
               (decknix-session-classify-status decknix-agent-net-error-status))
              'error)))

(ert-deftest decknix-net-error--display-face-is-loud ()
  "A dead session paints with the error face, not the default."
  (should (eq (decknix-agent-net-error-display-face
               decknix-agent-net-error-status 'success)
              'error))
  (should (eq (decknix-agent-net-error-display-face "ready" 'success)
              'success)))

;; ---------------------------------------------------------------------
;; Retry partition — which buffers a bulk reset acts on
;; ---------------------------------------------------------------------

(ert-deftest decknix-net-error--retry-plan-picks-flagged-only ()
  "By default only the sessions that actually failed are retried."
  (let ((a (generate-new-buffer " *net-a*"))
        (b (generate-new-buffer " *net-b*")))
    (unwind-protect
        (should (equal (decknix--agent-net-error-retry-plan
                        (list (cons a t) (cons b nil)) nil)
                       (list a)))
      (kill-buffer a)
      (kill-buffer b))))

(ert-deftest decknix-net-error--retry-plan-all-includes-unflagged ()
  "With ALL, every live session is retried — the escape hatch for a
failure whose evidence has already scrolled away."
  (let ((a (generate-new-buffer " *net-a*"))
        (b (generate-new-buffer " *net-b*")))
    (unwind-protect
        (should (equal (decknix--agent-net-error-retry-plan
                        (list (cons a t) (cons b nil)) t)
                       (list a b)))
      (kill-buffer a)
      (kill-buffer b))))

(ert-deftest decknix-net-error--retry-plan-drops-dead-buffers ()
  "A killed buffer is never dispatched to, flagged or not."
  (let ((a (generate-new-buffer " *net-a*"))
        (dead (generate-new-buffer " *net-dead*")))
    (kill-buffer dead)
    (unwind-protect
        (progn
          (should (equal (decknix--agent-net-error-retry-plan
                          (list (cons a t) (cons dead t)) nil)
                         (list a)))
          (should (equal (decknix--agent-net-error-retry-plan
                          (list (cons a nil) (cons dead nil)) t)
                         (list a))))
      (kill-buffer a))))

;; ---------------------------------------------------------------------
;; Retry stagger — do not re-saturate a link that just came back
;; ---------------------------------------------------------------------

(ert-deftest decknix-net-error--retry-schedule-spaces-dispatch ()
  "Each successive session waits one more stagger interval.

The reset leaves every target idle, so an unstaggered dispatch puts all
of them on the wire at once, each re-uploading a full context — and a
bulk retry runs on a link that has only just come back, so every session
that times out lands straight back in the state being cleared."
  (should (equal (decknix--agent-net-error-retry-schedule '(a b c) 2)
                 '((a . 0) (b . 2) (c . 4))))
  ;; The first is always immediate — recovery should feel instant.
  (should (= 0 (cdr (car (decknix--agent-net-error-retry-schedule '(a b) 1.5))))))

(ert-deftest decknix-net-error--retry-schedule-zero-is-immediate ()
  "A stagger of 0 (or a nonsense value) dispatches everything at once."
  (dolist (stagger '(0 -1 nil "x"))
    (should (equal (decknix--agent-net-error-retry-schedule '(a b c) stagger)
                   '((a . 0) (b . 0) (c . 0))))))

(ert-deftest decknix-net-error--retry-schedule-empty ()
  "Nothing to dispatch schedules nothing."
  (should-not (decknix--agent-net-error-retry-schedule nil 1.5)))

(ert-deftest decknix-net-error--retry-plan-empty ()
  "Nothing flagged means nothing to do — never a spurious broadcast."
  (should-not (decknix--agent-net-error-retry-plan nil nil))
  (should-not (decknix--agent-net-error-retry-plan
               (list (cons (current-buffer) nil)) nil)))

;; ---------------------------------------------------------------------
;; Buffer-level capture — mark / clear / collect
;; ---------------------------------------------------------------------

(ert-deftest decknix-net-error--mark-and-clear-round-trip ()
  "Marking records the offending line; clearing removes it."
  (let ((buf (generate-new-buffer " *net-mark*")))
    (unwind-protect
        (progn
          (should-not (decknix-agent-net-error-flagged-p buf))
          (decknix-agent-net-error-mark buf "API Error: socket hang up")
          (should (decknix-agent-net-error-flagged-p buf))
          (should (equal (decknix-agent-net-error-reason buf)
                         "API Error: socket hang up"))
          (decknix-agent-net-error-clear buf)
          (should-not (decknix-agent-net-error-flagged-p buf))
          (should-not (decknix-agent-net-error-reason buf)))
      (kill-buffer buf))))

(ert-deftest decknix-net-error--dead-buffer-is-never-flagged ()
  "Probing a killed buffer answers nil rather than erroring."
  (let ((buf (generate-new-buffer " *net-dead*")))
    (kill-buffer buf)
    (should-not (decknix-agent-net-error-flagged-p buf))
    (should-not (decknix-agent-net-error-reason buf))
    ;; Marking a dead buffer is a silent no-op, not an error.
    (should-not (decknix-agent-net-error-mark buf "API Error: socket hang up"))))

(ert-deftest decknix-net-error--scan-buffer-flags-from-its-own-text ()
  "Scanning reads the buffer tail, so a failure is caught even when the
streaming seam missed it (the bulk command rescans before acting)."
  (let ((buf (generate-new-buffer " *net-scan*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "working on it...\n")
          (insert "API Error: Unable to connect to API (ECONNRESET)\n")
          (should (decknix-agent-net-error-scan-buffer buf))
          (should (decknix-agent-net-error-flagged-p buf)))
      (kill-buffer buf))))

(ert-deftest decknix-net-error--scan-buffer-clears-a-recovered-session ()
  "A rescan after the session carried on drops a stale flag, so the
bulk retry never re-prompts a session that already recovered."
  (let ((buf (generate-new-buffer " *net-scan*")))
    (unwind-protect
        (with-current-buffer buf
          (decknix-agent-net-error-mark buf "API Error: socket hang up")
          (insert "All good now — the build is green.\n")
          (should-not (decknix-agent-net-error-scan-buffer buf))
          (should-not (decknix-agent-net-error-flagged-p buf)))
      (kill-buffer buf))))

(ert-deftest decknix-net-error--previous-turns-failure-is-not-this-turns ()
  "A failure from an EARLIER turn must not re-flag a recovered session.

The scan reads the buffer, so without a per-turn floor the last turn's
error line stays inside the trailing window: a session that failed, was
retried, and answered briefly would be flagged again and re-prompted on
every bulk retry — an unbounded loop against a session that is fine.
`decknix-agent-net-error-mark-turn-start' is what bounds the scan to the
output of the turn actually being judged."
  (let ((buf (generate-new-buffer " *net-turn*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "API Error: Unable to connect to API (ECONNRESET)\n")
          (should (decknix-agent-net-error-scan-buffer buf))
          ;; The link is back: a new turn starts, and answers tersely.
          (decknix-agent-net-error-mark-turn-start buf)
          (insert "Done.\n")
          (should-not (decknix-agent-net-error-scan-buffer buf))
          (should-not (decknix-agent-net-error-flagged-p buf)))
      (kill-buffer buf))))

(ert-deftest decknix-net-error--turn-floor-still-catches-this-turns-failure ()
  "Bounding the scan to the turn must not blind it to that turn's own death."
  (let ((buf (generate-new-buffer " *net-turn*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "Earlier work, all fine.\n")
          (decknix-agent-net-error-mark-turn-start buf)
          (insert "API Error: Unable to connect to API (ECONNRESET)\n")
          (should (decknix-agent-net-error-scan-buffer buf))
          (should (decknix-agent-net-error-flagged-p buf)))
      (kill-buffer buf))))

(ert-deftest decknix-net-error--turn-floor-survives-a-truncated-buffer ()
  "A floor left beyond `point-max' (buffer erased/rewound) never errors."
  (let ((buf (generate-new-buffer " *net-turn*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "some output that is later discarded\n")
          (decknix-agent-net-error-mark-turn-start buf)
          (erase-buffer)
          (insert "API Error: socket hang up\n")
          (should (decknix-agent-net-error-scan-buffer buf)))
      (kill-buffer buf))))

(provide 'decknix-agent-net-error-test)
;;; decknix-agent-net-error-test.el ends here
