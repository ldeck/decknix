;;; decknix-agent-turn-signals.el --- Turn-end signal sensing -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, status, acp

;;; Commentary:
;;
;; The SENSING layer for session lifecycle state.
;;
;; `decknix-session-state.el' already classifies a session into seven
;; lifecycle states (error / needs-input / review / running / idle /
;; done / closing) from a signals plist.  Two of the signals it documents
;; had no feeder at all:
;;
;;   :attention  "the agent flagged it needs you (e.g. asked a question)"
;;   :done       "the work is complete"
;;
;; `:attention' was only ever set from the "waiting" status -- i.e. a
;; PERMISSION prompt.  An agent that ended its turn by asking you a
;; question reported plain "ready", visually identical to one with
;; nothing left to say, so a session blocked on your answer looked idle
;; and got walked away from.  `:done' was reachable only from external
;; hub data (a merged PR), never from the agent's own account of the work.
;;
;; Meanwhile the ACP traffic carries exactly the missing evidence, and
;; agent-shell discards it after rendering:
;;
;;   plan entries   `plan' session updates carry per-entry status
;;                  (pending / in_progress / completed).  Rendered, not
;;                  retained -- so "did it finish what I asked?" was
;;                  unanswerable.
;;   stopReason     end_turn / max_tokens / max_turn_requests / refusal /
;;                  cancelled, delivered on the `turn-complete' event.
;;                  Abnormal reasons render into a buffer fragment and
;;                  then vanish: a turn that DIED looked exactly like one
;;                  that finished.
;;   agent messages the closing message, from which a question is read.
;;
;; This file holds the pure judgement over that evidence plus the
;; buffer-local capture it feeds.  Per AGENTS.md Rule 2 the wiring
;; (`advice-add' on `agent-shell--on-notification',
;; `agent-shell-subscribe-to' for `turn-complete') stays in the heredoc.
;;
;; Question detection is a HEURISTIC, not protocol -- ACP has no "I asked
;; you something" bit.  It is deliberately biased towards false positives:
;; wrongly flagging a session as wanting you costs a glance, while missing
;; one costs however long you leave it sitting there.  See
;; `decknix--agent-question-p' for the markers.

;;; Code:

(require 'map)
(require 'seq)
(require 'subr-x)
(require 'rx)
(require 'decknix-agent-turn-ask)

(declare-function agent-shell--state "ext:agent-shell")
(declare-function agent-shell--content-block-to-markdown "ext:agent-shell" (content))
(defvar shell-maker--busy)

;; ---------------------------------------------------------------------------
;; Tunables
;; ---------------------------------------------------------------------------

(defcustom decknix-agent-turn-signals-question-window 500
  "How many trailing characters of the closing message to scan for a question.
Bounds `asking' to mean \"the turn ENDED on an ask\".  A question far
above the end has normally been superseded by the work that followed it,
so scanning the whole message would leave sessions stuck as `asking'."
  :type 'integer :group 'decknix)

(defcustom decknix-agent-turn-signals-tail-chars 2000
  "Cap on the retained tail of the in-flight agent message, in characters.
The accumulator runs on every streamed chunk, so it must be O(1) per
chunk rather than growing without bound; only the tail is ever read (see
`decknix-agent-turn-signals-question-window')."
  :type 'integer :group 'decknix)

(defcustom decknix-agent-turn-unprompted-quiet-seconds 3
  "Seconds of no new agent text after which an unprompted turn is settled.
An unprompted turn is one this buffer did not start, so no `turn-complete'
ever arrives for it: a background task waking the agent, or a turn the
broker replays after a reattach.  Silence is the only sign it has ended."
  :type 'number :group 'decknix)

;; ---------------------------------------------------------------------------
;; Pure layer -- ERT-tested.
;; ---------------------------------------------------------------------------

(defun decknix--agent-turn-append-tail (acc chunk)
  "Append CHUNK to ACC, retaining only the trailing window.
Truncates to `decknix-agent-turn-signals-tail-chars' so streaming a long
message stays constant-cost per chunk.  Keeps the END of the text: the
question, if any, is at the end."
  (let ((s (concat (or acc "") (or chunk ""))))
    (if (<= (length s) decknix-agent-turn-signals-tail-chars)
        s
      (substring s (- (length s) decknix-agent-turn-signals-tail-chars)))))

(defun decknix--agent-turn-strip-code-fences (text)
  "Return TEXT with fenced code blocks removed.
A `?' inside a fence is code -- a ternary, a glob, a shell snippet -- not
a question put to the user.  Without this nearly every message closing on
an example would falsely read as an ask."
  (replace-regexp-in-string "```[^\0]*?```" "" (or text "")))

(defconst decknix--agent-question-restated-regexp
  (rx (or (seq "waiting " (or "on" "for") " your "
               (or "choice" "answer" "call" "decision" "reply" "pick"))
          (seq "your option" (? "s") " " (or "were" "are"))))
  "Prose shapes for a turn restating a choice it is already blocked on.

Derived from running `decknix--agent-question-p' over twelve real
transcripts: a RESUMED session tends to re-state its pending question as
prose rather than re-emit a decision block, and both of the predicate's
misses had this shape.

Deliberately narrow.  \"Waiting on your next instruction\" closed five of
those twelve transcripts and every one was genuinely idle, so the verb
list must stay specific -- a bare \"waiting on your\" would misreport all
five as blocked.

\"Waiting for your pick\" is the shape a review session uses when a
background task wakes it while it is still blocked on its gate (\"I'm
still waiting for your pick: 1 ... is recommended, or 2, or 3\").")

(defconst decknix--agent-question-line-regexp
  (rx "?" (* (any "*_`")) (* blank)
      (? (or (seq "(" (* (not (any "()\n"))) ")")
             (seq "[" (* (not (any "[]\n"))) "]")))
      (* (any "*_`")) (* blank) eol)
  "A line that ends on a question, allowing what agents put after the mark.

The bare \"ends in `?'\" test missed the confirmation gate
`/review-service-pr' prescribes word for word, \"Ready to submit? (yes /
edit / cancel)\": the line ends in a parenthesis.  Over 350 closing turns
of real review sessions, every gate the predicate missed had that shape,
and 34 sessions were sitting at one reading `ready'.  So a parenthesised
or bracketed hint may follow the mark, as may markdown emphasis closing
round the question (\"**Proceed?**\").")

(defun decknix--agent-question-p (text)
  "Return non-nil when TEXT ends a turn by soliciting an answer.

Markers, all scanned within the trailing
`decknix-agent-turn-signals-question-window' characters of TEXT once
fenced code has been stripped:

  - a `CHOOSE ONE' decision block (mandated by the workspace AGENTS.md
    for any message offering the user options, so it is an exact marker
    rather than a guess);
  - a closing `Reply with ...' instruction, that block's final line;
  - any line ending in a question mark, optionally followed by a hint
    such as \"(yes / edit / cancel)\" (`decknix--agent-question-line-regexp');
  - a restated pending choice (`decknix--agent-question-restated-regexp'),
    the shape a resumed session uses instead of a fresh decision block.

Heuristic by necessity: ACP carries no such flag.  Biased to over-report
per this file's Commentary."
  (when (and text (stringp text))
    (let* ((stripped (decknix--agent-turn-strip-code-fences text))
           (trimmed (string-trim stripped))
           (tail (if (<= (length trimmed) decknix-agent-turn-signals-question-window)
                     trimmed
                   (substring trimmed
                              (- (length trimmed)
                                 decknix-agent-turn-signals-question-window))))
           (case-fold-search t))
      (and (not (string-empty-p tail))
           (or (string-match-p "^[ \t]*choose one[ \t]*$" tail)
               (string-match-p "^[ \t]*reply with\\b" tail)
               (string-match-p decknix--agent-question-line-regexp tail)
               (string-match-p decknix--agent-question-restated-regexp tail))
           t))))

(defun decknix-agent-turn-question-excerpt (text)
  "Return the line of TEXT that best says what the turn is asking, or nil.

The last line ending in a question mark within the trailing
`decknix-agent-turn-signals-question-window', when there is one -- that is
the ask itself.  Otherwise, for a `CHOOSE ONE' block, the line before it,
which states the decision; otherwise the last non-empty line.  Markdown
emphasis, list and heading markers are stripped: this is read in a
narrow sidebar row, not rendered."
  (when (and (stringp text) (not (string-empty-p (string-trim text))))
    (let* ((stripped (decknix--agent-turn-strip-code-fences text))
           (lines (seq-filter (lambda (l) (not (string-empty-p l)))
                              (mapcar #'string-trim (split-string stripped "\n"))))
           (tail (let ((acc nil) (n 0))
                   (dolist (l (reverse lines))
                     (when (< n decknix-agent-turn-signals-question-window)
                       (push l acc)
                       (setq n (+ n (length l) 1))))
                   acc))
           (case-fold-search t)
           (choose (seq-position tail "choose one"
                                 (lambda (l k) (string-match-p (concat "\\`" k "\\'") l))))
           (pick (or (car (last (seq-filter
                                 (lambda (l)
                                   (string-match-p decknix--agent-question-line-regexp l))
                                 tail)))
                     (and choose (> choose 0) (nth (1- choose) tail))
                     (car (last (seq-remove
                                 (lambda (l)
                                   (or (string-match-p "\\`reply with\\b" l)
                                       (string-match-p "\\`choose one\\b" l)
                                       (string-match-p "\\`[-=]+\\'" l)))
                                 tail)))
                     (car (last tail)))))
      (and pick
           (string-trim
            (replace-regexp-in-string
             "\\`\\(?:[#>*-]+\\|[0-9]+[.)]\\)[ \t]*" ""
             (replace-regexp-in-string "\\*\\*\\|__\\|`" "" pick)))))))

(defun decknix-agent-turn-ask (text)
  "Return what the turn closing on TEXT asks, or nil when it asks nothing.

A plist: `:verdict', the review verdict its plan presents (nil outside a
review gate), and `:reply', the answer it expects (see
`decknix-agent-turn-ask-reply')."
  (when (decknix--agent-question-p text)
    (list :verdict (decknix-agent-turn-ask-verdict text)
          :reply (decknix-agent-turn-ask-reply text))))

(defun decknix-agent-turn-answered-gate (closing reply)
  "Return the gate REPLY answered, given the turn's CLOSING text, or nil.

Only a review GATE -- a question whose plan names a verdict -- counts.
Answering anything else leaves no phase to report, and keeping it would
label the next turn `posting' after you merely said \"stop\"."
  (when-let* ((ask (decknix-agent-turn-ask closing))
              ((plist-get ask :verdict)))
    (list :ask ask :reply (or reply ""))))

(defun decknix-agent-turn-unprompted-settlement (closing question tail)
  "Return (CLOSING . QUESTION) once an unprompted turn has ended on TAIL.  Pure.

CLOSING and QUESTION are what the session last settled on.  A turn that
asks replaces them.  One that does not leaves a pending question in
place: nobody has answered it, and a background task reporting that a
log search found nothing does not answer it either.  Otherwise the new
text becomes the closing text, so the board reads what the session said
last.  An empty TAIL changes nothing."
  (cond
   ((not (and (stringp tail) (not (string-empty-p (string-trim tail)))))
    (cons closing question))
   ((decknix--agent-question-p tail) (cons tail t))
   (question (cons closing t))
   (t (cons tail nil))))

(defun decknix--agent-plan-entry-text (entry)
  "Return ENTRY's content as one trimmed line, or nil when it has none."
  (let ((text (map-elt entry 'content)))
    (and (stringp text)
         (let ((line (string-trim (replace-regexp-in-string "[\n\t ]+" " " text))))
           (and (not (string-empty-p line)) line)))))

(defun decknix--agent-plan-progress (entries)
  "Return a progress plist for ACP plan ENTRIES, or nil when there are none.

Plist is (:total N :completed N :in-progress N :pending N :current TEXT
:next TEXT).  :current is the first in-progress entry's text and :next the
first pending entry's, each nil when there is none; the sidebar shows them
under the session.  ENTRIES may be a vector (as decoded from JSON) or a
list.  An unrecognised or missing status counts as PENDING, never as
completed -- over-reporting completion would claim finished work that is
not."
  (let ((items (cond ((vectorp entries) (append entries nil))
                     ((listp entries) entries)
                     (t nil))))
    (when items
      (let ((total 0) (done 0) (doing 0) (todo 0) current next)
        (dolist (entry items)
          (setq total (1+ total))
          (pcase (map-elt entry 'status)
            ("completed"   (setq done (1+ done)))
            ("in_progress" (setq doing (1+ doing))
             (unless current (setq current (decknix--agent-plan-entry-text entry))))
            (_             (setq todo (1+ todo))
             (unless next (setq next (decknix--agent-plan-entry-text entry))))))
        (list :total total :completed done
              :in-progress doing :pending todo
              :current current :next next)))))

(defun decknix--agent-plan-complete-p (progress)
  "Return non-nil when PROGRESS shows every planned entry completed.
An absent or empty plan claims nothing and is never `complete'."
  (let ((total (plist-get progress :total))
        (done (plist-get progress :completed)))
    (and (integerp total) (> total 0) (equal total done) t)))

(defun decknix--agent-plan-label (progress)
  "Return a compact \"DONE/TOTAL\" label for PROGRESS, or nil.
Nil when there is no plan, so callers can omit the badge entirely rather
than render a meaningless \"0/0\"."
  (let ((total (plist-get progress :total))
        (done (plist-get progress :completed)))
    (when (and (integerp total) (> total 0))
      (format "%d/%d" (or done 0) total))))

(defun decknix--agent-stop-reason-signals (stop-reason)
  "Return classifier signals for an ACP STOP-REASON, or nil when unremarkable.

`end_turn' is a clean finish and `cancelled' was your own doing, so both
stay quiet.  `max_tokens', `max_turn_requests' and `refusal' mean the
turn did not complete on its own terms -- today those render into a
buffer fragment and are invisible anywhere else.  An unrecognised reason
stays quiet rather than manufacturing urgency from a schema addition."
  (pcase stop-reason
    ((or "max_tokens" "max_turn_requests" "refusal") '(:attention t))
    (_ nil)))

(defun decknix-agent-turn-signals (facts)
  "Return `decknix-session-classify' signals for turn-end FACTS, or nil.

FACTS is a plist of what the last turn actually did:
  :question     non-nil when the closing message asked something
  :plan         a `decknix--agent-plan-progress' plist
  :stop-reason  the ACP stopReason string

Both `:attention' and `:done' may be emitted at once (a finished plan
that still ends on a question); `decknix-session-classify' already scores
`:attention' above `:done', so the question is never lost."
  (let (signals)
    (when (plist-get facts :question)
      (setq signals (plist-put signals :attention t)))
    (when (decknix--agent-plan-complete-p (plist-get facts :plan))
      (setq signals (plist-put signals :done t)))
    (when (plist-get (decknix--agent-stop-reason-signals
                      (plist-get facts :stop-reason))
                     :attention)
      (setq signals (plist-put signals :attention t)))
    signals))

(defun decknix-agent-turn-restored-facts (turns)
  "Return turn-end FACTS reconstructed from a restored session's TURNS.

TURNS is a list of (USER-MSG . ASSISTANT-RESP) cons cells, oldest first,
as `decknix--agent-session-extract-all-turns' returns.  Pure, so the
reconstruction is testable without a session or a transcript file.

Exists because `asking' did not survive a restart.  The flag behind it,
`decknix--agent-turn-question', is `defvar-local' and is captured from the
LIVE message stream at `turn-complete'; a restart destroys the buffer, so
it resets to nil and nothing recomputes it.  Two sessions blocked on
unanswered questions came back reading `ready' after a `decknix switch'
\(2026-09-10) and so looked idle -- the exact opposite of what `asking'
exists to communicate.

Reconstructed from the TRANSCRIPT rather than from the restored buffer on
purpose: prepopulation truncates, and on both affected sessions the
question itself had been cut, leaving `[...truncated]' and the prompt.
The transcript still holds the last turn whole.

Only the LAST turn is consulted.  An earlier, already-answered question
must not resurrect the flag -- a stale ask is worse than the bug being
fixed, because every restored session would then demand attention it does
not need."
  (let ((last-assistant (cdr (car (last turns)))))
    (list :question (and (decknix--agent-question-p last-assistant) t)
          ;; The closing text too, so a restored session can still say
          ;; WHAT it is asking, not merely that it is.
          :text (and (stringp last-assistant)
                     (decknix--agent-turn-append-tail nil last-assistant))
          ;; Whether the last prompt answered a gate the turn before it
          ;; put, so a session restarted mid-posting still reads as acting
          ;; on your answer rather than starting its review over.
          :answered (let ((prev (cdr (car (last turns 2)))))
                      (and (cdr turns) (stringp prev)
                           (decknix-agent-turn-answered-gate
                            (decknix--agent-turn-append-tail nil prev)
                            (car (car (last turns)))))))))

(defun decknix-agent-turn-broker-facts (buffer)
  "Return turn facts BUFFER\='s broker log can supply, or nil.

Only `:working\='.  Read from the broker rather than the transcript because
the transcript is written at turn END, so a turn still in progress leaves
no trace in it at all."
  (when (and (buffer-live-p buffer)
             (fboundp 'decknix--agent-broker-working-p))
    (list :working (and (decknix--agent-broker-working-p buffer) t))))

(defconst decknix-agent-turn-askable-statuses '("ready" "finished")
  "Statuses that may be refined to `asking'.
Only a settled turn qualifies: `working' has not finished asking yet, and
`waiting' (a permission prompt) is the more specific block already.")

(defun decknix-agent-turn-status (raw-status facts)
  "Refine RAW-STATUS from turn-end FACTS.

`:working\=' wins over `:question\=': a mid-turn agent is working, and a
question only closes a turn, so the two cannot both be current.  Without
this, a session reattached to a still-running broker reported `ready\=' and
read as dormant while its agent was producing output.

Any status outside `decknix-agent-turn-askable-statuses\=' is returned
unchanged -- a live, blocked or dead session is never relabelled by how it
happened to sign off.

`:ended\=' -- this buffer saw the turn complete and has sent nothing
since -- overrules `:working\='.  The broker log is read at most every
`decknix-agent-broker-working-reprobe-seconds\=', so for a few seconds
after a turn ends it still reports the turn in flight, and a board
refreshed in that window kept showing the gate it had just reached as
`working\=' until something else repainted it.  The buffer's own record
of the turn ending cannot lag that way.  The broker remains the only
evidence for a turn this buffer did not start, which is what it is for."
  (cond
   ((not (member raw-status decknix-agent-turn-askable-statuses)) raw-status)
   ((and (plist-get facts :working) (not (plist-get facts :ended))) "working")
   ((plist-get facts :question) "asking")
   (t raw-status)))

;; ---------------------------------------------------------------------------
;; Capture layer -- buffer-local facts fed by the heredoc wiring.
;; ---------------------------------------------------------------------------

(defvar-local decknix--agent-turn-message-tail nil
  "Trailing text of the agent message currently streaming, or nil.")

(defvar-local decknix--agent-turn-question nil
  "Non-nil when the last completed turn ended on a question.")

(defvar-local decknix--agent-turn-plan nil
  "Progress plist for the most recent `plan' update, or nil.")

(defvar-local decknix--agent-turn-stop-reason nil
  "ACP stopReason of the last completed turn, or nil.")

(defvar-local decknix--agent-turn-ended nil
  "Non-nil from this buffer's `turn-complete' until its next turn starts.")

(defvar-local decknix--agent-turn-answered nil
  "The review gate this buffer's last prompt answered, or nil.
A plist (:ask ASK :reply TEXT), see `decknix-agent-turn-answered-gate'.
Set when input is submitted; unlike the closing text it survives the
turn it starts, which is the turn that acts on the answer.")

(defvar-local decknix--agent-turn-ask-memo nil
  "(TEXT . ASK) for the closing text last parsed, compared with `eq'.")

(defvar-local decknix--agent-turn-closing-text nil
  "Trailing text of the last completed turn's message, or nil.
Kept until the next turn starts, so the sidebar can say what a session
that is `asking' actually asked without reading its buffer.")

(defvar-local decknix--agent-turn-unprompted-timer nil
  "Quiet timer settling an unprompted turn in this buffer, or nil.")

(defvar-local decknix--agent-turn-unprompted-seen nil
  "The message tail when the unprompted timer was armed, compared with `eq'.")

(defun decknix-agent-turn-closing-text (&optional buffer)
  "Return the closing text of BUFFER's last turn, or nil.  No I/O."
  (let ((buf (or buffer (current-buffer))))
    (and (buffer-live-p buf)
         (buffer-local-value 'decknix--agent-turn-closing-text buf))))

(defun decknix-agent-turn-closing-ask (&optional buffer)
  "Return what BUFFER's last turn asks, as `decknix-agent-turn-ask'.  No I/O.

Parsed once per closing text: the board and sidebar ask on every
rebuild, and the text only changes at a turn boundary."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((text decknix--agent-turn-closing-text))
          (if (and decknix--agent-turn-ask-memo
                   (eq text (car decknix--agent-turn-ask-memo)))
              (cdr decknix--agent-turn-ask-memo)
            (cdr (setq decknix--agent-turn-ask-memo
                       (cons text (and text (decknix-agent-turn-ask text)))))))))))

(defun decknix-agent-turn-answered (&optional buffer)
  "Return the review gate BUFFER's last prompt answered, or nil.  No I/O."
  (let ((buf (or buffer (current-buffer))))
    (and (buffer-live-p buf)
         (buffer-local-value 'decknix--agent-turn-answered buf))))

(defun decknix-agent-turn-plan (&optional buffer)
  "Return BUFFER's last plan progress plist, or nil.  No I/O."
  (let ((buf (or buffer (current-buffer))))
    (and (buffer-live-p buf)
         (buffer-local-value 'decknix--agent-turn-plan buf))))

(defun decknix-agent-turn-facts (&optional buffer)
  "Return the turn-end facts plist for BUFFER (default `current-buffer')."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (list :question (buffer-local-value 'decknix--agent-turn-question buf)
            :plan (buffer-local-value 'decknix--agent-turn-plan buf)
            :stop-reason (buffer-local-value 'decknix--agent-turn-stop-reason buf)
            :ended (buffer-local-value 'decknix--agent-turn-ended buf)))))

(defun decknix--agent-turn-notification-buffer (state)
  "Return the shell buffer owning STATE, or nil.
Resolved from STATE rather than `current-buffer': notification handlers
run from a process filter, where the current buffer is whatever happened
to be selected.  Trusting it would attribute one session's message to
another."
  (let ((buf (map-elt state :buffer)))
    (and (buffer-live-p buf) buf)))

(defun decknix--agent-turn-chunk-text (notification)
  "Return the text of an agent_message_chunk NOTIFICATION, or nil."
  (let ((content (map-nested-elt notification '(params update content))))
    (when content
      (if (fboundp 'agent-shell--content-block-to-markdown)
          (agent-shell--content-block-to-markdown content)
        (map-elt content 'text)))))

(defun decknix--agent-turn-observe-notification (&rest args)
  "Capture turn-end evidence from an ACP notification.
Installed as `:before' advice on `agent-shell--on-notification', whose
`&key' ARGS carry `:state' and `:acp-notification'.

Cheap by construction: this runs on EVERY streamed chunk, so it does no
more than a bounded string append (`decknix--agent-turn-append-tail')."
  (let* ((state (plist-get args :state))
         (notification (plist-get args :acp-notification))
         (buffer (decknix--agent-turn-notification-buffer state)))
    (when (and buffer (equal (map-elt notification 'method) "session/update"))
      (let ((update-type (map-nested-elt notification '(params update sessionUpdate))))
        (with-current-buffer buffer
          (pcase update-type
            ("agent_message_chunk"
             (setq decknix--agent-turn-message-tail
                   (decknix--agent-turn-append-tail
                    decknix--agent-turn-message-tail
                    (decknix--agent-turn-chunk-text notification)))
             (decknix--agent-turn-note-unprompted buffer))
            ("plan"
             (setq decknix--agent-turn-plan
                   (decknix--agent-plan-progress
                    (map-nested-elt notification '(params update entries)))))
            ;; Record which worktree this session is working in, from the
            ;; paths the tool call reports.  Only these two kinds carry
            ;; `locations', so the common case (a message chunk) does not
            ;; reach the observer at all.
            ((or "tool_call" "tool_call_update")
             (when (fboundp 'decknix-session-assoc-observe)
               (ignore-errors
                 (decknix-session-assoc-observe
                  (map-nested-elt notification '(params update)))))
             ;; And any PR it creates, which stays its work while open.
             (when (fboundp 'decknix-session-assoc-observe-created)
               (ignore-errors
                 (decknix-session-assoc-observe-created
                  (map-nested-elt notification '(params update))))))
            ("user_message_chunk"
             ;; A new turn begins: last turn's ask is answered by definition.
             (decknix-agent-turn-reset))
            (_ nil)))))))

(defun decknix--agent-turn-note-unprompted (buffer)
  "Arm the quiet timer when BUFFER streams agent text it did not ask for.

A turn this buffer started keeps `shell-maker--busy' set until its
`turn-complete', which settles it.  Text arriving while the buffer is not
busy belongs to a turn nothing will settle: a background task waking the
agent, or the broker replaying a turn after a reattach.  Review sessions
reach their gate this way constantly, because the gate often follows a
background CI wait, and the board kept such a session `In progress' until
the next prompt.

Runs on every chunk, so it costs one variable test and one `timerp' once
the timer is armed."
  (unless (or (bound-and-true-p shell-maker--busy)
              (timerp decknix--agent-turn-unprompted-timer))
    (decknix--agent-turn-arm-unprompted buffer)))

(defun decknix--agent-turn-arm-unprompted (buffer)
  "Start BUFFER's quiet timer from the current message tail."
  (setq decknix--agent-turn-unprompted-seen decknix--agent-turn-message-tail
        decknix--agent-turn-unprompted-timer
        (run-with-timer decknix-agent-turn-unprompted-quiet-seconds nil
                        #'decknix--agent-turn-unprompted-check buffer)))

(defun decknix--agent-turn-unprompted-check (buffer)
  "Settle BUFFER's unprompted turn if no text arrived since the timer was armed."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq decknix--agent-turn-unprompted-timer nil)
      (cond
       ((bound-and-true-p shell-maker--busy) nil)
       ((not (eq decknix--agent-turn-message-tail
                 decknix--agent-turn-unprompted-seen))
        (decknix--agent-turn-arm-unprompted buffer))
       (t (decknix-agent-turn-settle-unprompted))))))

(defun decknix--agent-turn-cancel-unprompted ()
  "Drop the current buffer's quiet timer: its own turn boundary settles it."
  (when (timerp decknix--agent-turn-unprompted-timer)
    (cancel-timer decknix--agent-turn-unprompted-timer))
  (setq decknix--agent-turn-unprompted-timer nil))

(defun decknix-agent-turn-settle-unprompted ()
  "Settle the current buffer's unprompted turn from its message tail.

The tail is kept, unlike at `turn-complete': more text from the same run
extends it, and the next settlement reads the whole of it.  `:ended' is
left alone, because a replayed turn may still be running and only the
broker can say whether it has stopped."
  (let ((tail decknix--agent-turn-message-tail))
    (when (and (stringp tail) (not (string-empty-p (string-trim tail))))
      (let ((settled (decknix-agent-turn-unprompted-settlement
                      decknix--agent-turn-closing-text
                      decknix--agent-turn-question
                      tail)))
        (setq decknix--agent-turn-closing-text (car settled)
              decknix--agent-turn-question (cdr settled)))
      (decknix--agent-turn-run-settled-hook))))

(defun decknix-agent-turn-reset ()
  "Clear turn-end facts in the current buffer at the start of a new turn.
The plan is deliberately KEPT: it spans turns, and a session that stops
mid-plan should still read as having work outstanding."
  (decknix--agent-turn-cancel-unprompted)
  (setq decknix--agent-turn-message-tail nil
        decknix--agent-turn-question nil
        decknix--agent-turn-stop-reason nil
        decknix--agent-turn-ended nil
        decknix--agent-turn-closing-text nil))

(defvar decknix-agent-turn-settled-hook nil
  "Hook run in a session buffer when its turn ends or a new one starts.

For views that show session state and are not otherwise told it moved:
the Review Board rebuilds from the reviews feed, which a review reaching
its gate does not touch.  Runs once per turn boundary, never per chunk.")

(defun decknix--agent-turn-run-settled-hook ()
  "Run `decknix-agent-turn-settled-hook', never letting it fail the event.
It runs inside advice on `agent-shell--emit-event', where a signal would
stop the event reaching agent-shell's own subscribers."
  (with-demoted-errors "decknix-agent-turn-settled-hook: %S"
    (run-hooks 'decknix-agent-turn-settled-hook)))

(defun decknix--agent-turn-observe-event (&rest args)
  "Settle turn-end facts from an agent-shell event.
Installed as `:before' advice on `agent-shell--emit-event', whose `&key'
ARGS carry `:event' and `:data'.

Uses `current-buffer' deliberately, and safely: `agent-shell--emit-event'
calls `(agent-shell--state)' with no buffer argument, so the owning shell
buffer is already current by construction -- the same assumption upstream
makes one line later when it dispatches to subscribers.  This is unlike
`agent-shell-heartbeat-stop', which takes no state at all and genuinely
can fire against an unrelated buffer.

Runs once per turn, so the question scan is off any hot path."
  (when (derived-mode-p 'agent-shell-mode)
    (let ((data (plist-get args :data)))
      (pcase (plist-get args :event)
        ('turn-complete
         (when (fboundp 'decknix-session-assoc-end-turn)
           (ignore-errors (decknix-session-assoc-end-turn)))
         (decknix--agent-turn-cancel-unprompted)
         (setq decknix--agent-turn-stop-reason (map-elt data :stop-reason))
         (setq decknix--agent-turn-question
               (decknix--agent-question-p decknix--agent-turn-message-tail))
         (setq decknix--agent-turn-closing-text decknix--agent-turn-message-tail)
         (setq decknix--agent-turn-ended t)
         (decknix--agent-turn-run-settled-hook)
         (setq decknix--agent-turn-message-tail nil))
        ('input-submitted
         ;; Before the reset clears it: the closing text is the question
         ;; this prompt answers.  A second reset in the same turn (an
         ;; echoed user message) finds it gone and leaves the record.
         (when decknix--agent-turn-closing-text
           (setq decknix--agent-turn-answered
                 (decknix-agent-turn-answered-gate
                  decknix--agent-turn-closing-text (map-elt data :prompt))))
         (decknix-agent-turn-reset)
         (decknix--agent-turn-run-settled-hook))
        (_ nil)))))

(defun decknix--agent-turn-status-advice (orig-fn buffer)
  "Around-advice for `agent-shell-workspace--buffer-status': add `asking'.
Refines ORIG-FN's status for BUFFER when that session's last turn ended
on a question.  Never invents urgency for a live, blocked or dead
session -- see `decknix-agent-turn-status'."
  (let ((raw (funcall orig-fn buffer)))
    (if (and (buffer-live-p buffer)
             (member raw decknix-agent-turn-askable-statuses))
        (let ((facts (decknix-agent-turn-facts buffer)))
          (decknix-agent-turn-status
           raw (if (plist-get facts :ended)
                   facts
                 (append (decknix-agent-turn-broker-facts buffer) facts))))
      raw)))

;; ---------------------------------------------------------------------------
;; Quick replies -- answering a closing question from a list of sessions.
;; ---------------------------------------------------------------------------

(declare-function decknix--compose-submit-after-wait
                  "decknix-agent-shell-main-compose" (target input))

(defvar decknix-agent-turn-reply-send-function #'decknix--compose-submit-after-wait
  "Function (BUFFER TEXT) submitting TEXT as BUFFER's next prompt.
Returns non-nil only when it was sent.  The compose path's submit, the
same one a typed prompt and the bulk send use, so a quick reply goes
through `shell-maker-submit' and is refused while the agent is busy.")

(defun decknix-agent-turn-reply-prompt (buffer plan ask)
  "Return the confirmation prompt for sending PLAN's text to BUFFER.  Pure.
Names the session, the exact text, what it means and the verdict at
stake, because the answer is what posts the review."
  (format "Send %S to %s (%s)%s? "
          (plist-get plan :text) (buffer-name buffer) (plist-get plan :label)
          (if-let* ((v (plist-get ask :verdict))) (format ", posting %s" v) "")))

(defun decknix-agent-turn-quick-reply (buffer key)
  "Answer BUFFER's closing question with KEY, after asking you to confirm.

KEY is `yes' or a digit 1-9 (see `decknix-agent-turn-ask-quick-reply').
Refuses, with the reason, a key the question did not offer.  ALWAYS
confirms: these answers trigger the agent's next action, which on a
review gate is posting to GitHub, and a stray key must never do that.
Returns non-nil when the reply was sent."
  (unless (buffer-live-p buffer) (user-error "No session here"))
  (let* ((ask (decknix-agent-turn-closing-ask buffer))
         (plan (decknix-agent-turn-ask-quick-reply ask key)))
    (cond
     ((plist-get plan :error)
      (user-error "%s: %s" (buffer-name buffer) (plist-get plan :error)))
     ((not (y-or-n-p (decknix-agent-turn-reply-prompt buffer plan ask)))
      (message "Not sent") nil)
     ((funcall decknix-agent-turn-reply-send-function buffer (plist-get plan :text))
      (message "Sent %S to %s" (plist-get plan :text) (buffer-name buffer)) t)
     (t (message "%s is busy; nothing sent" (buffer-name buffer)) nil))))

(defun decknix-agent-turn-reply-key (event)
  "Return the quick-reply key for input EVENT: `yes' for y, a digit 1-9, or nil."
  (cond ((memq event '(?y ?Y)) 'yes)
        ((and (integerp event) (<= ?1 event ?9)) (- event ?0))))

(provide 'decknix-agent-turn-signals)
;;; decknix-agent-turn-signals.el ends here
