;;; decknix-agent-heartbeat-watch.el --- Reclaim stuck busy heartbeats -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, heartbeat, performance

;;; Commentary:
;;
;; agent-shell animates a busy "spinner" by running a heartbeat timer
;; (`agent-shell-heartbeat-start') while a prompt request is in flight,
;; and stops it only inside that request's on-success / on-failure
;; callback.  If a request never gets a response -- the ACP bridge dies,
;; the connection breaks, or a turn is orphaned (all plausible after a
;; wedged daemon or a resume-all storm) -- neither callback fires and the
;; heartbeat leaks: the session stays `busy' and the spinner animates
;; forever, forcing a header/mode-line redisplay several times a second.
;; A single leaked heartbeat was the residual idle-CPU floor that
;; survived the sidebar-timer fix.
;;
;; This watchdog reclaims those.  A slow periodic timer checks every live
;; agent-shell buffer whose heartbeat is still running: if the buffer has
;; produced no output (its `buffer-chars-modified-tick' is unchanged) for
;; longer than `decknix-agent-heartbeat-stuck-seconds', the heartbeat is
;; considered stuck and STOPPED.  A genuinely-working turn streams output
;; (or tool-call fragments) well within the window, so it is never cut
;; off; the window is deliberately generous so a slow-but-live tool call
;; is safe.
;;
;; It stops ONLY the heartbeat (the redisplay drain), not the shell's
;; request state: if the orphaned request does eventually respond, its
;; on-success path still completes normally (calling
;; `agent-shell-heartbeat-stop' again is idempotent).  So the reclaim is
;; safe and reversible -- it removes the CPU cost, nothing else.
;;
;; The pure decision (`decknix--agent-hb-stuck-p') is carved for ERT; the
;; timer wiring lives in the heredoc per AGENTS.md Rule 2.

;;; Code:

(require 'map)

(declare-function agent-shell-buffers "ext:agent-shell")
(declare-function agent-shell--state "ext:agent-shell")
(declare-function agent-shell-heartbeat-stop "ext:agent-shell-heartbeat")
(defvar shell-maker--busy)

(defun decknix--agent-status-settled-p (busy heartbeat-live session-id)
  "Return non-nil when a \"working\" report is stale residue, not live work.

`agent-shell-workspace--buffer-status' decides \"working\" from a
non-empty `:tool-calls' list BEFORE it consults the busy flag, so any
tool-call residue outlives the turn that produced it and the session
never leaves \"working\".  Clearing the residue at turn end is the
primary fix (`decknix--agent-normalize-turn-end'); this is the backstop
for residue arriving by some other path.

Deliberately demands TWO independent negatives -- BUSY is nil AND
HEARTBEAT-LIVE is nil -- before contradicting the reported status.
Either alone is ambiguous: a turn is briefly busy before its heartbeat
starts, and the watchdog may stop a leaked heartbeat while a request is
genuinely still outstanding.  Requiring both means a live turn is never
mislabelled idle, which is the failure that would actually cost the user
something.

SESSION-ID mirrors upstream's own precondition for reporting \"ready\";
without it there is no session to be ready, so the report is left alone.
Pure, so the decision is ERT-testable."
  (and (not busy)
       (not heartbeat-live)
       session-id
       t))

(defun decknix--agent-buffer-status-harden (orig buffer &rest args)
  "Return BUFFER's status from ORIG, downgrading stale \"working\" to \"ready\".

`:around' advice for `agent-shell-workspace--buffer-status'.  Only a
\"working\" result is ever reconsidered -- \"waiting\" (a pending
permission request), \"killed\", \"initializing\" and \"ready\" pass
through untouched -- and only when `decknix--agent-status-settled-p'
agrees the turn is demonstrably over."
  (let ((status (apply orig buffer args)))
    (if (and (equal status "working")
             (bufferp buffer)
             (buffer-live-p buffer))
        (with-current-buffer buffer
          (let* ((state (ignore-errors (agent-shell--state)))
                 (heartbeat (map-elt state :heartbeat)))
            (if (decknix--agent-status-settled-p
                 (bound-and-true-p shell-maker--busy)
                 (and (timerp (map-elt heartbeat :heartbeat-timer)) t)
                 (map-nested-elt state '(:session :id)))
                "ready"
              status)))
      status)))

(defun decknix--agent-heartbeat-owner (heartbeat buffers state-fn)
  "Return the buffer in BUFFERS whose agent-shell state owns HEARTBEAT.

STATE-FN maps a buffer to its `agent-shell--state' (injected so the
lookup is ERT-testable without a live shell).  Matched by identity
\(`eq'): the heartbeat alist handed to `agent-shell-heartbeat-stop' is
the very object stored under the owning shell's `:heartbeat', so nothing
else can be `eq' to it.

Needed because `agent-shell-heartbeat-stop' takes only the heartbeat --
it carries no buffer, and the current buffer at call time is merely
whatever the process filter or timer left selected."
  (when heartbeat
    (seq-find (lambda (buf)
                (and (buffer-live-p buf)
                     (eq (map-elt (funcall state-fn buf) :heartbeat) heartbeat)))
              buffers)))

(defun decknix--agent-normalize-turn-end-in-buffer (buffer)
  "Clear BUFFER's residual turn state (`:tool-calls' and the busy flag)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (derived-mode-p 'agent-shell-mode)
        (ignore-errors
          (when (agent-shell--state)
            (map-put! (agent-shell--state) :tool-calls nil)))
        (when (bound-and-true-p shell-maker--busy)
          (setq shell-maker--busy nil))))))

(defun decknix--agent-normalize-turn-end (&rest args)
  "Clear a finished turn's residual state so status leaves \"working\".
`agent-shell''s `session/prompt' ON-SUCCESS handler clears `:tool-calls' and the
busy flag, but its ON-FAILURE handler (an errored / non-`end_turn' Claude turn)
stops the heartbeat WITHOUT clearing them.  So after a failure-path turn end,
`agent-shell-workspace--buffer-status' keeps returning \"working\" (tool-calls >
0 and/or `shell-maker--busy' set) indefinitely — the session never shows ready
after its output, and interrupt-submit can't help because there is no active
turn to cancel (observed: sid b05da127 stuck `working tc=11' for ~30 min after a
TURN-END).

Run as `:after' advice on `agent-shell-heartbeat-stop' (= turn end, either
path).  Safe: heartbeat-stop only fires when the turn is genuinely over — a turn
paused on a permission prompt keeps its heartbeat running — and the SUCCESS path
merely re-clears already-cleared state.

The buffer is resolved from ARGS' `:heartbeat' rather than assumed to be
`current-buffer'.  Trusting the current buffer made this a silent no-op
whenever heartbeat-stop ran with a non-shell buffer selected, leaving the
state dirty indefinitely (observed: sid a93a0f99 reporting \"working\" on 95
residual tool-calls while `agent-shell-status' said `ready' and the heartbeat
had already ended).  Worse, when some OTHER agent-shell buffer happened to be
current it would clear that innocent session's state instead — the
`derived-mode-p' guard only checks that some shell is selected, not the right
one.  Falls back to the current buffer when the owner cannot be resolved, so a
heartbeat already detached from any live shell behaves as it used to."
  (let* ((heartbeat (plist-get args :heartbeat))
         (owner (and (fboundp 'agent-shell-buffers)
                     (decknix--agent-heartbeat-owner
                      heartbeat (agent-shell-buffers)
                      (lambda (buf)
                        (with-current-buffer buf
                          (ignore-errors (agent-shell--state))))))))
    (decknix--agent-normalize-turn-end-in-buffer
     (or owner (current-buffer)))))

(defcustom decknix-agent-heartbeat-stuck-seconds 600
  "Seconds of no buffer output after which a running heartbeat is stuck.
A live turn streams output (or tool-call fragments) far sooner, so this
only ever fires on a leaked heartbeat (dead/orphaned request).  Generous
by design: better to let a slow-but-live tool call run than to cut it
off; a truly stuck heartbeat is reclaimed within this window regardless."
  :type 'integer
  :group 'decknix)

(defcustom decknix-agent-heartbeat-hung-seconds 180
  "Shorter stuck window for a turn that has made ZERO tool calls.
A running turn with no tool calls AND no output is far more likely hung — an
unresolved `session/prompt' request after an auth/API error or a wedged bridge —
than slow-but-live work (a slow TOOL call keeps the generous
`decknix-agent-heartbeat-stuck-seconds' window).  Still long enough to cover a
Claude turn's silent extended-thinking gap before its first output, so a live
turn is never cut off."
  :type 'integer
  :group 'decknix)

(defun decknix--agent-hb-effective-threshold (tool-call-count stuck hung)
  "Return the stuck window: HUNG when TOOL-CALL-COUNT is 0, else STUCK.
Never longer than STUCK.  Pure, so the choice is ERT-testable."
  (if (and (integerp tool-call-count) (= tool-call-count 0))
      (min hung stuck)
    stuck))

(defvar-local decknix--agent-hb-last-tick nil
  "`buffer-chars-modified-tick' at the previous watchdog check.")

(defvar-local decknix--agent-hb-idle-since nil
  "`float-time' since which this buffer's output has been unchanged, or nil.")

(defvar decknix--agent-hb-watch-timer nil
  "The single watchdog timer, or nil when not armed.")

(defun decknix--agent-hb-running-p (state)
  "Return non-nil when STATE's heartbeat timer is live (spinner animating)."
  (let ((hb (and state (map-elt state :heartbeat))))
    (and hb (timerp (map-elt hb :heartbeat-timer)))))

(defun decknix--agent-hb-stuck-p (running tick last-tick idle-since now threshold)
  "Return non-nil when a running heartbeat looks stuck (leaked).
RUNNING is whether the heartbeat timer is live.  TICK is the buffer's
current `buffer-chars-modified-tick'; LAST-TICK the value at the previous
check.  IDLE-SINCE is when output last stopped changing (or nil).  NOW is
the current `float-time'.  Stuck when the heartbeat is running, the
buffer has not changed since the last check, and it has been idle for at
least THRESHOLD seconds.  Pure, so the decision is ERT-testable."
  (and running
       (eql tick last-tick)
       (numberp idle-since)
       (>= (- now idle-since) threshold)))

(defun decknix--agent-hb-watch-buffer (buf now threshold)
  "Reclaim a stuck heartbeat in BUF (a live agent-shell buffer).
NOW is `float-time'; THRESHOLD the stuck window in seconds.  Updates the
buffer's activity bookkeeping and, when the heartbeat is judged stuck by
`decknix--agent-hb-stuck-p', stops it (only the heartbeat)."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let* ((state (ignore-errors (agent-shell--state)))
             (running (decknix--agent-hb-running-p state))
             (tick (buffer-chars-modified-tick))
             ;; A running turn that has made no tool calls uses the shorter
             ;; hung window (likely an unresolved request after an auth/API
             ;; error); a turn with a tool in flight keeps the generous window.
             (eff-threshold (decknix--agent-hb-effective-threshold
                             (length (map-elt state :tool-calls))
                             threshold decknix-agent-heartbeat-hung-seconds)))
        (cond
         ((not running)
          ;; No spinner: keep the baseline fresh so a future run starts clean.
          (setq decknix--agent-hb-last-tick tick
                decknix--agent-hb-idle-since nil))
         ((not (eql tick decknix--agent-hb-last-tick))
          ;; Output changed since last check -> genuinely working.
          (setq decknix--agent-hb-last-tick tick
                decknix--agent-hb-idle-since now))
         (t
          (unless decknix--agent-hb-idle-since
            (setq decknix--agent-hb-idle-since now))
          (when (decknix--agent-hb-stuck-p
                 running tick decknix--agent-hb-last-tick
                 decknix--agent-hb-idle-since now eff-threshold)
            (ignore-errors
              (agent-shell-heartbeat-stop :heartbeat (map-elt state :heartbeat)))
            (setq decknix--agent-hb-idle-since nil)
            (message "decknix: reclaimed stuck heartbeat in %s"
                     (buffer-name buf)))))))))

(defun decknix--agent-hb-watch-tick ()
  "Watchdog entry point: reclaim stuck heartbeats across live agent buffers."
  (when (fboundp 'agent-shell-buffers)
    (let ((now (float-time)))
      (dolist (buf (ignore-errors (agent-shell-buffers)))
        (decknix--agent-hb-watch-buffer
         buf now decknix-agent-heartbeat-stuck-seconds)))))

(defun decknix--agent-hb-watch-start ()
  "Arm the heartbeat watchdog timer (idempotent across hot-reloads)."
  (when (timerp decknix--agent-hb-watch-timer)
    (cancel-timer decknix--agent-hb-watch-timer))
  (setq decknix--agent-hb-watch-timer
        (run-with-timer 60 60 #'decknix--agent-hb-watch-tick)))

(provide 'decknix-agent-heartbeat-watch)
;;; decknix-agent-heartbeat-watch.el ends here
