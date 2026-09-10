;;; decknix-agent-turn-signals-test.el --- Tests for turn-end signal sensing -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification tests for the turn-end SENSING layer — the pure
;; functions that turn what the agent actually did at the end of a turn
;; (its closing message, its plan, its ACP stop reason) into the signals
;; `decknix-session-classify' was always designed to consume but that
;; nothing ever fed.
;;
;; The orchestration (advice on `agent-shell--on-notification', the
;; `turn-complete' subscription) lives in the heredoc per AGENTS.md
;; Rule 2; only the judgement is tested here.

;;; Code:

(require 'ert)
(require 'decknix-agent-turn-signals)

;; ---------------------------------------------------------------------
;; Question detection — "ready" vs "ready AND waiting on your answer"
;; ---------------------------------------------------------------------

(ert-deftest decknix-turn-signals--question-nil-input ()
  "No message (or an empty one) asks nothing."
  (should-not (decknix--agent-question-p nil))
  (should-not (decknix--agent-question-p ""))
  (should-not (decknix--agent-question-p "   \n\n  ")))

(ert-deftest decknix-turn-signals--question-decision-block ()
  "The mandated decision block is an exact marker (workspace AGENTS.md)."
  (should (decknix--agent-question-p
           "Done.\n\nCHOOSE ONE\n----------\n1. proceed\n2. abort\n"))
  ;; Case-insensitive so a stylistic variant still registers.
  (should (decknix--agent-question-p "choose one\n1. a\n2. b")))

(ert-deftest decknix-turn-signals--question-reply-with ()
  "The decision block's closing line is itself sufficient."
  (should (decknix--agent-question-p
           "1. proceed\n2. abort\n\nReply with the number or the name.")))

(ert-deftest decknix-turn-signals--question-trailing-question-mark ()
  "A message that ends on a question is waiting on you."
  (should (decknix--agent-question-p "I fixed it. Want me to push?"))
  (should (decknix--agent-question-p "Shall I proceed?\n")))

(ert-deftest decknix-turn-signals--question-in-tail-window ()
  "A question near the end still counts even with trailing prose.
An agent commonly asks and then adds a closing remark; requiring the
very last line to be the question would miss most real cases."
  (should (decknix--agent-question-p
           "Should I proceed?\n\nI'll wait for your call.")))

(ert-deftest decknix-turn-signals--question-restated-options ()
  "A session restating options it is blocked on is still asking.
Found by running the predicate over 12 real transcripts: a resumed
session commonly re-states the pending choice as prose rather than
re-emitting a decision block, and both misses had this shape."
  (should (decknix--agent-question-p
           "I was waiting on your choice between: **1** spec the taxonomy, **2** ship it."))
  (should (decknix--agent-question-p
           "Your options were: (1) fix the permadiff, (2) dig into the 08- prefix.")))

(ert-deftest decknix-turn-signals--question-generic-standby-is-ready ()
  "Generic standby prose is NOT a question.
\"Waiting on your next instruction\" was the closing line of five of
those twelve transcripts, every one of them genuinely idle.  It is one
word away from the `waiting on your choice' shape above, so it is pinned
here: a broader \"waiting on your\" rule would misreport all five."
  (should-not (decknix--agent-question-p "Waiting on your next instruction."))
  (should-not (decknix--agent-question-p "Ready when you are."))
  (should-not (decknix--agent-question-p "Let me know how you want to proceed.")))

(ert-deftest decknix-turn-signals--question-not-a-statement ()
  "A plain completion report is not a question."
  (should-not (decknix--agent-question-p
               "Fixed the bug, added two tests, and committed as abc1234."))
  (should-not (decknix--agent-question-p "Done.")))

(ert-deftest decknix-turn-signals--question-ignores-code-fences ()
  "A `?' inside a fenced code block is code, not an ask.
Without this, every message ending in a shell snippet or a ternary
would falsely mark the session as blocked on you."
  (should-not (decknix--agent-question-p
               "Here is the fix:\n\n```js\nconst x = a ? b : c;\nfoo(bar?)\n```\n"))
  ;; A real question OUTSIDE the fence still registers.
  (should (decknix--agent-question-p
           "```sh\ngit push?\n```\n\nWant me to run it?")))

(ert-deftest decknix-turn-signals--question-ignores-distant-question ()
  "A question far above the end has already been superseded.
The window keeps `asking' meaning \"the turn ENDED on an ask\"."
  (should-not (decknix--agent-question-p
               (concat "Shall I proceed?\n\n"
                       (make-string 800 ?x)
                       "\n\nAll done, nothing outstanding."))))

;; ---------------------------------------------------------------------
;; Streaming accumulator — bounded, keeps the END
;; ---------------------------------------------------------------------

(ert-deftest decknix-turn-signals--append-tail-under-cap ()
  "Below the cap nothing is lost."
  (should (equal "abc" (decknix--agent-turn-append-tail "ab" "c")))
  (should (equal "c" (decknix--agent-turn-append-tail nil "c")))
  (should (equal "ab" (decknix--agent-turn-append-tail "ab" nil))))

(ert-deftest decknix-turn-signals--append-tail-keeps-the-end ()
  "Over the cap the HEAD is dropped, never the tail.
The accumulator runs per streamed chunk, so it must be bounded; the
question lives at the end, so the end is what must survive."
  (let ((decknix-agent-turn-signals-tail-chars 10))
    (let ((out (decknix--agent-turn-append-tail (make-string 10 ?x) "12345")))
      (should (= 10 (length out)))
      (should (equal "12345" (substring out -5))))))

;; ---------------------------------------------------------------------
;; Plan progress — "did it finish what it was asked?"
;; ---------------------------------------------------------------------

(ert-deftest decknix-turn-signals--plan-nil-when-no-entries ()
  "No plan at all is absence of evidence, not zero progress."
  (should-not (decknix--agent-plan-progress nil))
  (should-not (decknix--agent-plan-progress []))
  (should-not (decknix--agent-plan-progress '())))

(ert-deftest decknix-turn-signals--plan-counts-by-status ()
  "Entries are bucketed by ACP status."
  (let ((p (decknix--agent-plan-progress
            [((content . "a") (status . "completed"))
             ((content . "b") (status . "in_progress"))
             ((content . "c") (status . "pending"))])))
    (should (= 3 (plist-get p :total)))
    (should (= 1 (plist-get p :completed)))
    (should (= 1 (plist-get p :in-progress)))
    (should (= 1 (plist-get p :pending)))))

(ert-deftest decknix-turn-signals--plan-accepts-list-form ()
  "JSON may arrive as a vector or a list; both must count identically."
  (should (equal (decknix--agent-plan-progress
                  [((status . "completed")) ((status . "pending"))])
                 (decknix--agent-plan-progress
                  '(((status . "completed")) ((status . "pending")))))))

(ert-deftest decknix-turn-signals--plan-unknown-status-is-pending ()
  "An unrecognised status counts as outstanding, never as done.
Miscounting it as complete would claim finished work that isn't."
  (let ((p (decknix--agent-plan-progress
            [((status . "completed")) ((status . "wat")) ((status))])))
    (should (= 3 (plist-get p :total)))
    (should (= 1 (plist-get p :completed)))
    (should (= 2 (plist-get p :pending)))))

(ert-deftest decknix-turn-signals--plan-complete-p ()
  "Complete only when there was a plan AND every entry is done."
  (should (decknix--agent-plan-complete-p '(:total 2 :completed 2)))
  (should-not (decknix--agent-plan-complete-p '(:total 3 :completed 2)))
  (should-not (decknix--agent-plan-complete-p nil))
  ;; An empty plan claims nothing.
  (should-not (decknix--agent-plan-complete-p '(:total 0 :completed 0))))

(ert-deftest decknix-turn-signals--plan-label ()
  "Progress renders compactly for the sidebar/header."
  (should (equal "2/5" (decknix--agent-plan-label '(:total 5 :completed 2))))
  (should-not (decknix--agent-plan-label nil))
  (should-not (decknix--agent-plan-label '(:total 0 :completed 0))))

;; ---------------------------------------------------------------------
;; Stop reason — a turn that DIED looks nothing like one that finished
;; ---------------------------------------------------------------------

(ert-deftest decknix-turn-signals--stop-reason-clean ()
  "A natural end of turn needs no attention."
  (should-not (decknix--agent-stop-reason-signals "end_turn"))
  (should-not (decknix--agent-stop-reason-signals nil)))

(ert-deftest decknix-turn-signals--stop-reason-cancelled-is-quiet ()
  "You cancelled it; you already know."
  (should-not (decknix--agent-stop-reason-signals "cancelled")))

(ert-deftest decknix-turn-signals--stop-reason-abnormal-wants-you ()
  "Truncated/refused turns are currently invisible outside the buffer."
  (dolist (reason '("max_tokens" "max_turn_requests" "refusal"))
    (should (plist-get (decknix--agent-stop-reason-signals reason)
                       :attention))))

(ert-deftest decknix-turn-signals--stop-reason-unknown-is-quiet ()
  "An unrecognised reason must not manufacture urgency."
  (should-not (decknix--agent-stop-reason-signals "brand_new_reason")))

;; ---------------------------------------------------------------------
;; Merge — facts to classifier signals
;; ---------------------------------------------------------------------

(ert-deftest decknix-turn-signals--merge-question-sets-attention ()
  "A closing question is the `:attention' feeder the classifier lacked."
  (should (plist-get (decknix-agent-turn-signals '(:question t)) :attention)))

(ert-deftest decknix-turn-signals--merge-complete-plan-sets-done ()
  "A fully-completed plan is the agent's own claim of `done'."
  (should (plist-get (decknix-agent-turn-signals
                      '(:plan (:total 4 :completed 4)))
                     :done)))

(ert-deftest decknix-turn-signals--merge-partial-plan-not-done ()
  "Stopping with work outstanding is not done."
  (should-not (plist-get (decknix-agent-turn-signals
                          '(:plan (:total 4 :completed 1)))
                         :done)))

(ert-deftest decknix-turn-signals--merge-question-outranks-done ()
  "Asked a question with a finished plan -> still needs you.
`decknix-session-classify' scores `:attention' above `:done', so both
may be emitted; this pins that the question is never dropped."
  (let ((s (decknix-agent-turn-signals
            '(:question t :plan (:total 2 :completed 2)))))
    (should (plist-get s :attention))))

(ert-deftest decknix-turn-signals--merge-empty-facts ()
  "No facts -> no signals (classifies as plain idle)."
  (should-not (decknix-agent-turn-signals nil))
  (should-not (decknix-agent-turn-signals '(:stop-reason "end_turn"))))

;; ---------------------------------------------------------------------
;; Status derivation — where `asking' enters the existing vocabulary
;; ---------------------------------------------------------------------

(ert-deftest decknix-turn-signals--status-asking-from-ready ()
  "An idle session that ended on a question reports `asking'."
  (should (equal "asking" (decknix-agent-turn-status "ready" '(:question t))))
  (should (equal "asking" (decknix-agent-turn-status "finished" '(:question t)))))

(ert-deftest decknix-turn-signals--status-never-overrides-live-turn ()
  "A running turn is never relabelled — its question isn't final yet."
  (should (equal "working" (decknix-agent-turn-status "working" '(:question t)))))

(ert-deftest decknix-turn-signals--status-permission-outranks-question ()
  "A pending permission prompt is the more specific block."
  (should (equal "waiting" (decknix-agent-turn-status "waiting" '(:question t)))))

(ert-deftest decknix-turn-signals--status-killed-untouched ()
  "A dead session is dead regardless of how it signed off."
  (should (equal "killed" (decknix-agent-turn-status "killed" '(:question t)))))

(ert-deftest decknix-turn-signals--status-passthrough-without-question ()
  "Without a question the raw status is returned unchanged."
  (dolist (s '("ready" "finished" "working" "waiting" "killed" "initializing"))
    (should (equal s (decknix-agent-turn-status s nil)))))

;; --- `asking' must survive a restart ---------------------------------
;;
;; Observed after a `decknix switch' on 2026-09-10: two sessions that were
;; `asking' before the restart came back `ready'.  Both were still blocked
;; on a question nobody had answered, and both now looked idle in the
;; sidebar -- the one state whose whole job is to say "this needs you".
;;
;; `asking' is a refinement of `ready' driven by `decknix--agent-turn-
;; question', which is `defvar-local' and captured from the LIVE message
;; stream at `turn-complete'.  A restart destroys the buffer, so the flag
;; resets to nil and nothing recomputes it.  The session that kept its
;; `asking' only did so because it asked AFTER the reattach.
;;
;; Recomputing from the restored BUFFER is not enough: prepopulation
;; truncates, and on both affected sessions the question had been cut
;; ("[...truncated]" then the prompt).  The transcript still holds the
;; full last turn, so that is the source.

(ert-deftest decknix-turn-restore--question-from-last-assistant-turn ()
  "A restored session ending on a decision block is `asking' again."
  (should (plist-get
           (decknix-agent-turn-restored-facts
            '(("do the thing" . "Done, all green.")
              ("and then?" . "Ready to push.\n\nCHOOSE ONE\n----------\n1. push\n2. wait\n")))
           :question)))

(ert-deftest decknix-turn-restore--no-question-when-turn-just-reports ()
  "A restored session that merely reported is left `ready'."
  (should-not (plist-get
               (decknix-agent-turn-restored-facts
                '(("do the thing" . "Done. Tests pass and the branch is pushed.")))
               :question)))

(ert-deftest decknix-turn-restore--uses-the-LAST-turn-not-an-earlier-one ()
  "An answered question from an earlier turn must not resurrect `asking'.
The bug this guards is worse than the one it fixes: a stale ask makes
every restored session shout for attention it no longer needs."
  (should-not (plist-get
               (decknix-agent-turn-restored-facts
                '(("start" . "Which one?\n\nCHOOSE ONE\n----------\n1. a\n2. b\n")
                  ("1" . "Done, pushed.")))
               :question)))

(ert-deftest decknix-turn-restore--tolerates-no-transcript ()
  "No turns, or a turn with no assistant text, is not a question."
  (should-not (plist-get (decknix-agent-turn-restored-facts nil) :question))
  (should-not (plist-get (decknix-agent-turn-restored-facts '(("hi" . nil))) :question))
  (should-not (plist-get (decknix-agent-turn-restored-facts '(("hi" . ""))) :question)))

(ert-deftest decknix-turn-restore--question-mark-close-counts ()
  "The other shapes `decknix--agent-question-p' knows still apply."
  (should (plist-get
           (decknix-agent-turn-restored-facts
            '(("check it" . "I can force-push or open a fresh PR. Which do you want?")))
           :question)))

(ert-deftest decknix-turn-restore--facts-shape-matches-the-live-path ()
  "The restored plist must be consumable by `decknix-agent-turn-status'.
Both paths feed the same refiner, so a different shape here would restore
the flag and still render `ready'."
  (should (equal "asking"
                 (decknix-agent-turn-status
                  "ready"
                  (decknix-agent-turn-restored-facts
                   '(("go" . "Ready.\n\nCHOOSE ONE\n----------\n1. yes\n")))))))

(provide 'decknix-agent-turn-signals-test)
;;; decknix-agent-turn-signals-test.el ends here
