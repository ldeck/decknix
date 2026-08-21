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
(require 'subr-x)
(require 'rx)

(declare-function agent-shell--state "ext:agent-shell")
(declare-function agent-shell--content-block-to-markdown "ext:agent-shell" (content))

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
  (rx (or (seq "waiting on your " (or "choice" "answer" "call" "decision" "reply"))
          (seq "your option" (? "s") " " (or "were" "are"))))
  "Prose shapes for a turn restating a choice it is already blocked on.

Derived from running `decknix--agent-question-p' over twelve real
transcripts: a RESUMED session tends to re-state its pending question as
prose rather than re-emit a decision block, and both of the predicate's
misses had this shape.

Deliberately narrow.  \"Waiting on your next instruction\" closed five of
those twelve transcripts and every one was genuinely idle, so the verb
list must stay specific -- a bare \"waiting on your\" would misreport all
five as blocked.")

(defun decknix--agent-question-p (text)
  "Return non-nil when TEXT ends a turn by soliciting an answer.

Markers, all scanned within the trailing
`decknix-agent-turn-signals-question-window' characters of TEXT once
fenced code has been stripped:

  - a `CHOOSE ONE' decision block (mandated by the workspace AGENTS.md
    for any message offering the user options, so it is an exact marker
    rather than a guess);
  - a closing `Reply with ...' instruction, that block's final line;
  - any line ending in a question mark;
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
               (string-match-p "\\?[ \t]*$" tail)
               (string-match-p decknix--agent-question-restated-regexp tail))
           t))))

(defun decknix--agent-plan-progress (entries)
  "Return a progress plist for ACP plan ENTRIES, or nil when there are none.

Plist is (:total N :completed N :in-progress N :pending N).  ENTRIES may
be a vector (as decoded from JSON) or a list.  An unrecognised or missing
status counts as PENDING, never as completed -- over-reporting completion
would claim finished work that is not."
  (let ((items (cond ((vectorp entries) (append entries nil))
                     ((listp entries) entries)
                     (t nil))))
    (when items
      (let ((total 0) (done 0) (doing 0) (todo 0))
        (dolist (entry items)
          (setq total (1+ total))
          (pcase (map-elt entry 'status)
            ("completed"   (setq done (1+ done)))
            ("in_progress" (setq doing (1+ doing)))
            (_             (setq todo (1+ todo)))))
        (list :total total :completed done
              :in-progress doing :pending todo)))))

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

(defconst decknix-agent-turn-askable-statuses '("ready" "finished")
  "Statuses that may be refined to `asking'.
Only a settled turn qualifies: `working' has not finished asking yet, and
`waiting' (a permission prompt) is the more specific block already.")

(defun decknix-agent-turn-status (raw-status facts)
  "Refine RAW-STATUS to \"asking\" when turn-end FACTS show a question.
Any other status is returned unchanged -- a live, blocked or dead session
is never relabelled by how it happened to sign off."
  (if (and (plist-get facts :question)
           (member raw-status decknix-agent-turn-askable-statuses))
      "asking"
    raw-status))

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

(defun decknix-agent-turn-facts (&optional buffer)
  "Return the turn-end facts plist for BUFFER (default `current-buffer')."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (list :question (buffer-local-value 'decknix--agent-turn-question buf)
            :plan (buffer-local-value 'decknix--agent-turn-plan buf)
            :stop-reason (buffer-local-value 'decknix--agent-turn-stop-reason buf)))))

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
                    (decknix--agent-turn-chunk-text notification))))
            ("plan"
             (setq decknix--agent-turn-plan
                   (decknix--agent-plan-progress
                    (map-nested-elt notification '(params update entries)))))
            ("user_message_chunk"
             ;; A new turn begins: last turn's ask is answered by definition.
             (decknix-agent-turn-reset))
            (_ nil)))))))

(defun decknix-agent-turn-reset ()
  "Clear turn-end facts in the current buffer at the start of a new turn.
The plan is deliberately KEPT: it spans turns, and a session that stops
mid-plan should still read as having work outstanding."
  (setq decknix--agent-turn-message-tail nil
        decknix--agent-turn-question nil
        decknix--agent-turn-stop-reason nil))

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
         (setq decknix--agent-turn-stop-reason (map-elt data :stop-reason))
         (setq decknix--agent-turn-question
               (decknix--agent-question-p decknix--agent-turn-message-tail))
         (setq decknix--agent-turn-message-tail nil))
        ('input-submitted (decknix-agent-turn-reset))
        (_ nil)))))

(defun decknix--agent-turn-status-advice (orig-fn buffer)
  "Around-advice for `agent-shell-workspace--buffer-status': add `asking'.
Refines ORIG-FN's status for BUFFER when that session's last turn ended
on a question.  Never invents urgency for a live, blocked or dead
session -- see `decknix-agent-turn-status'."
  (let ((raw (funcall orig-fn buffer)))
    (if (buffer-live-p buffer)
        (decknix-agent-turn-status raw (decknix-agent-turn-facts buffer))
      raw)))

(provide 'decknix-agent-turn-signals)
;;; decknix-agent-turn-signals.el ends here
