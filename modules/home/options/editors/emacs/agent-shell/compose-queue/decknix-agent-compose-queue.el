;;; decknix-agent-compose-queue.el --- Compose-queue policy resolver -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, compose, queue

;;; Commentary:
;;
;; Pure policy for the compose-buffer auto-submit queue.  The side-effecting
;; adapter (`decknix--compose-queue-poll', the timer, the commands) lives in
;; main-bulk per AGENTS.md Rule 2.
;;
;; The queue was a single string assigned with `setq', so queueing a second
;; message while the first was still pending DISCARDED the first, silently and
;; with no way to see it had happened.  It is a list here, submitted one turn
;; at a time in order, because merging two asks into one turn changes what was
;; asked -- combining is offered as an explicit action instead
;; (`decknix--compose-queue-combine').
;;
;; The resolver also holds.  Submission used to key on `shell-maker--busy'
;; alone, and a turn that ended by asking you something is a FINISHED turn, so
;; a queued prompt went straight into the answer slot and the question was
;; gone.  A blocking status suppresses the submit and reports `hold' instead,
;; leaving the queue intact until the block clears or the user releases it.
;; Holding is recoverable; answering a question by accident is not.
;;
;; Decision table, in order:
;;
;;   buffer dead                      -> cancel-timer
;;   empty queue / busy / no process  -> wait
;;   blocked (asking or waiting)      -> hold
;;   otherwise                        -> submit the head
;;
;; Blocking is checked LAST so an empty queue never reports a hold there is
;; nothing to hold.

;;; Code:

(require 'seq)
(require 'subr-x)

(defconst decknix--compose-queue-blocking-statuses '("waiting" "asking")
  "Statuses that must not be submitted over.

Both classify as `needs-input' (see `decknix-session-status-signal-map'):
\"waiting\" is a permission dialog blocking a turn mid-flight, \"asking\" a
settled turn whose closing message put a question to you.  Either way the
session wants an answer from you specifically, and the queue is not it.")

(defun decknix--compose-queue-blocking-status-p (status)
  "Return non-nil when STATUS means the session is waiting on the user.
A nil or unknown status is NOT blocking: the queue exists to run
unattended, so an unrecognised status must not stall it indefinitely."
  (and (stringp status)
       (member status decknix--compose-queue-blocking-statuses)
       t))

(defun decknix--compose-queue-normalise (queue)
  "Return QUEUE as a list of prompt strings.

Accepts a bare string for the single-slot shape this replaced, so a queue
captured before an upgrade still submits instead of being dropped."
  (cond
   ((null queue) nil)
   ((stringp queue) (list queue))
   ((listp queue) queue)
   (t nil)))

(defun decknix--compose-queue-action (queue buffer-live-p busy-p
                                           process-live-p &optional status)
  "Return the next action for the compose-queue poller as a plist.

QUEUE is the pending prompt list (or a bare string, or nil).
BUFFER-LIVE-P, BUSY-P and PROCESS-LIVE-P are the caller-evaluated
predicates: whether the agent-shell buffer is alive, whether
`shell-maker--busy' is set, and whether the buffer process is live.
STATUS is the session's status string, consulted only to decide whether
submitting would talk over a question.

Result:
  (:action cancel-timer)                 -- buffer dead, drop the timer
  (:action wait)                         -- busy, empty, or no process
  (:action hold :input STR :reason STR)  -- the session wants the user
  (:action submit :input STR :rest LIST) -- send the head, keep the tail

The caller performs the side-effect and, for `submit', stores `:rest' as
the new queue.  This function never touches a buffer, timer, or process."
  (let ((pending (decknix--compose-queue-normalise queue)))
    (cond
     ((not buffer-live-p)
      (list :action 'cancel-timer))
     ((or (null pending) busy-p (not process-live-p))
      (list :action 'wait))
     ((decknix--compose-queue-blocking-status-p status)
      (list :action 'hold :input (car pending) :reason status))
     (t
      (list :action 'submit :input (car pending) :rest (cdr pending))))))

(defun decknix--compose-queue-append (queue input)
  "Return QUEUE with INPUT added at the end.
Appending rather than assigning is the fix for the overwrite: a second
message queued before the first fired used to destroy it."
  (append (decknix--compose-queue-normalise queue) (list input)))

(defun decknix--compose-queue-drop (queue index)
  "Return QUEUE without the entry at INDEX.
An out-of-range INDEX returns the queue unchanged, so a stale completion
selection cannot silently drop the wrong message."
  (let ((pending (decknix--compose-queue-normalise queue)))
    (if (or (null index) (< index 0) (>= index (length pending)))
        pending
      (append (seq-take pending index) (seq-drop pending (1+ index))))))

(defconst decknix--compose-queue-combine-separator "\n\n"
  "Separator used when collapsing a queue into one prompt.
A blank line, so two queued messages read as two paragraphs rather than
running together into one sentence.")

(defun decknix--compose-queue-combine (queue &optional separator)
  "Return QUEUE collapsed into a single prompt string, or nil when empty.
SEPARATOR defaults to `decknix--compose-queue-combine-separator'."
  (let ((pending (decknix--compose-queue-normalise queue)))
    (when pending
      (mapconcat #'identity pending
                 (or separator decknix--compose-queue-combine-separator)))))

(defun decknix--compose-queue-summary (queue &optional held-reason)
  "Return a short label for QUEUE, or nil when nothing is pending.

HELD-REASON, when non-nil, is the blocking status; it is named in the
label because a queue that has silently stopped moving is worse than no
queue at all -- the user needs to know it is waiting on them."
  (let ((n (length (decknix--compose-queue-normalise queue))))
    (when (> n 0)
      (if held-reason
          (format "%d queued, held (%s)" n held-reason)
        (format "%d queued" n)))))

(defconst decknix--compose-queue-boundary "---"
  "Line marking a TURN boundary when a queue is drained into compose.

A markdown horizontal rule, so a drained queue still reads as a document.
Distinct from `decknix--compose-queue-combine-separator' on purpose: a
blank line separates paragraphs WITHIN one turn, this separates turns.  That
is what lets `decknix--compose-queue-combine' be a real combine -- its
output carries no boundary, so a later drain cannot split it back apart.")

(defconst decknix--compose-queue-boundary-regexp
  "^[ \t]*---[ \t]*$"
  "Regexp matching a `decknix--compose-queue-boundary' line.
Anchored to a whole line: a `---' inside prose is not a turn boundary.")

(defun decknix--compose-queue-drain-text (queue)
  "Return QUEUE as one editable document, turns separated by a rule.
Nil when the queue is empty.  Round-trips through
`decknix--compose-queue-split-text'."
  (let ((pending (decknix--compose-queue-normalise queue)))
    (when pending
      (mapconcat #'identity pending
                 (concat "\n\n" decknix--compose-queue-boundary "\n\n")))))

(defun decknix--compose-queue-split-text (text)
  "Return TEXT split back into a list of turns on boundary lines.

Empty segments are dropped, so a stray leading or trailing rule -- or two
in a row after an edit deleted a turn's body -- yields no empty prompt.
Each turn is trimmed, since the rule is surrounded by blank lines."
  (let ((parts (split-string (or text "")
                             decknix--compose-queue-boundary-regexp)))
    (seq-filter (lambda (part) (not (string-empty-p part)))
                (mapcar #'string-trim parts))))

;; -- dispatch tables for the two prompts -------------------------------
;;
;; Pure relative to `read-char-choice', which the suite stubs, and shaped
;; like `decknix--compose-busy-action' so both busy prompts read alike.

(defconst decknix--compose-queue-enqueue-prompt
  "%d already queued: [a]ppend  [r]eplace all  [j]oin into one turn  [c]ancel "
  "Prompt shown when queueing onto a non-empty queue.")

(defun decknix--compose-queue-enqueue-action (queued-count)
  "Return the dispatch symbol for queueing onto a queue of QUEUED-COUNT.

Returns `append' without asking when the queue is empty: the question only
exists because a second message used to destroy the first, and there is
nothing to destroy at zero.

  `append'   add at the end (the default, and the old behaviour)
  `replace'  drop what is queued and keep only the new message
  `combine'  collapse queue and new message into a single turn
  `cancel'   queue nothing"
  (if (or (null queued-count) (zerop queued-count))
      'append
    (pcase (read-char-choice
            (format decknix--compose-queue-enqueue-prompt queued-count)
            '(?a ?r ?j ?c))
      (?a 'append)
      (?r 'replace)
      (?j 'combine)
      (?c 'cancel))))

(defconst decknix--compose-queue-interrupt-prompt
  "%d queued: [f]irst-then-queue  [o]nly-this (drop queue)  [l]ast (after queue)  [c]ancel "
  "Prompt shown when interrupting with a non-empty queue.")

(defun decknix--compose-queue-interrupt-action (queued-count)
  "Return the dispatch symbol for interrupting with QUEUED-COUNT queued.

Returns `first' without asking when nothing is queued.  The point of the
prompt is the ORDERING, which was previously silent: interrupting submitted
the new message and the older queued ones then ran BEHIND it.

  `first'  submit this now, the queue follows (the old behaviour)
  `only'   submit this and drop the queue
  `last'   append this to the queue so everything runs in the order queued
  `cancel'  do nothing"
  (if (or (null queued-count) (zerop queued-count))
      'first
    (pcase (read-char-choice
            (format decknix--compose-queue-interrupt-prompt queued-count)
            '(?f ?o ?l ?c))
      (?f 'first)
      (?o 'only)
      (?l 'last)
      (?c 'cancel))))

(defun decknix--compose-queue-entry-label (input index &optional width)
  "Return a one-line completion label for INPUT at INDEX.
Newlines collapse to spaces and the text is truncated to WIDTH (default
60) so a multi-line prompt stays selectable in the minibuffer."
  (let* ((flat (replace-regexp-in-string "[ \t\n\r]+" " " (or input "")))
         (trimmed (string-trim flat))
         (max (or width 60)))
    (format "%d: %s" (1+ index)
            (if (> (length trimmed) max)
                (concat (substring trimmed 0 max) "…")
              trimmed))))

(provide 'decknix-agent-compose-queue)
;;; decknix-agent-compose-queue.el ends here
