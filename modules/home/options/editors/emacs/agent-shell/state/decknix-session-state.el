;;; decknix-session-state.el --- Lifecycle-state classifier for agent sessions -*- lexical-binding: t -*-

;; Author: decknix
;; Keywords: decknix, agent, board

;;; Commentary:
;;
;; The board's linchpin (ldeck/decknix#150): a session's kanban column and its
;; attention ordering must be DERIVED, not manual.  This file is the pure,
;; testable classifier — it turns a plist of observable signals into a
;; lifecycle `state' plus an attention `score' (higher = more deserving of your
;; attention).  A thin live adapter (separate) gathers the signals from an
;; agent-shell buffer; keeping the judgement pure makes it unit-testable and
;; reusable by both the board and the sidebar.

;;; Code:

(defconst decknix-session-state-order
  '(error needs-input review running idle done closing)
  "Lifecycle states, most-attention-worthy first.
`closing' is last: a session counting down to auto-close after a successful
turn wants the least attention (it is finishing itself), but stays visually
distinct via its own glyph.")

(defconst decknix-session-state-meta
  '((error      . ("✗" . "error"))
    (needs-input . ("⚠" . "needs input"))
    (review     . ("◉" . "review"))
    (running    . ("●" . "running"))
    (idle       . ("○" . "idle"))
    (done       . ("✓" . "done"))
    (closing    . ("⏻" . "closing")))
  "Alist of STATE -> (GLYPH . LABEL) for rendering.")

(defun decknix-session-state-glyph (state)
  "Return the display glyph for STATE (\"?\" if unknown)."
  (or (cadr (assq state decknix-session-state-meta)) "?"))

(defun decknix-session-state-label (state)
  "Return the human label for STATE (its symbol name if unknown)."
  (or (cddr (assq state decknix-session-state-meta))
      (and state (symbol-name state))))

(defun decknix-session-classify (signals)
  "Classify a session from SIGNALS into a plist (:state SYM :score INT).

SIGNALS is a plist; every key is optional and nil means absent:
  :error                the session is in an error / dead state
  :awaiting-permission  a permission prompt is pending your decision
  :attention            the agent flagged it needs you (e.g. asked a question)
  :closing              armed to auto-close, counting down after a clean turn
  :done                 the work is complete (e.g. hub says the PR merged)
  :busy                 a turn is currently in progress
  :unread               completed output you have not yet viewed

Precedence runs most-urgent first, so a single call collapses overlapping
signals to one state.  Higher :score sorts the card nearer the top.  `:closing'
outranks `:busy'/`:unread' so the countdown status wins even though a just-
finished turn also looks `unread' — but stays below anything needing you."
  (cond
   ((plist-get signals :error)               '(:state error       :score 90))
   ((plist-get signals :awaiting-permission) '(:state needs-input :score 80))
   ((plist-get signals :attention)           '(:state needs-input :score 70))
   ((plist-get signals :closing)             '(:state closing     :score 5))
   ((plist-get signals :done)                '(:state done        :score 0))
   ((and (not (plist-get signals :busy))
         (plist-get signals :unread))        '(:state review      :score 60))
   ((plist-get signals :busy)                '(:state running     :score 30))
   (t                                        '(:state idle        :score 10))))

(defconst decknix-session-status-signal-map
  '(("killed"       . (:error t))
    ("waiting"      . (:attention t))
    ("closing"      . (:closing t))
    ("working"      . (:busy t))
    ("finished"     . (:unread t))
    ("ready"        . nil)
    ("initializing" . nil))
  "Map an agent-shell status string to `decknix-session-classify' signals.
The status strings are those produced by `agent-shell-workspace--buffer-status'
/ `decknix--header-detect-status'.  Unmapped / \"ready\" / \"initializing\"
statuses carry no signals, classifying as `idle'.")

(defun decknix-session-signals-from-status (status)
  "Return classifier signals (a plist) for agent-shell STATUS string."
  (cdr (assoc status decknix-session-status-signal-map)))

(defun decknix-session-classify-status (status)
  "Classify an agent-shell STATUS string directly.
Convenience over signals-from-status + `decknix-session-classify'."
  (decknix-session-classify (decknix-session-signals-from-status status)))

(defun decknix-session-state (result)
  "Return the state symbol from a `decknix-session-classify' RESULT."
  (plist-get result :state))

(defun decknix-session-score (result)
  "Return the attention score from a `decknix-session-classify' RESULT."
  (plist-get result :score))

(provide 'decknix-session-state)
;;; decknix-session-state.el ends here
