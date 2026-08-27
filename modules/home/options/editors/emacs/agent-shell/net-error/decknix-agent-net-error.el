;;; decknix-agent-net-error.el --- Transient network-failure state + bulk retry -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, status, network

;;; Commentary:
;;
;; ldeck/decknix#162.
;;
;; When the link drops, a Claude/ACP turn does not fail loudly -- it
;; ends, having printed one line:
;;
;;   API Error: Unable to connect to API (ECONNRESET)
;;
;; agent-shell renders that as ordinary agent output and the turn
;; settles, so `agent-shell-workspace--buffer-status' reports a cheerful
;; "ready".  In the sidebar the session is then INDISTINGUISHABLE from
;; one that finished its work: no glyph, no colour, no position change.
;; The observed cost (the session that motivated this file) was a dozen
;; wasted turns -- every "continue" the user typed hit the same dead
;; link and produced the same one-line reply -- and then the discovery
;; that several OTHER sessions had died the same way hours earlier and
;; had simply been sitting there.
;;
;; Two things are needed and this file provides both:
;;
;;   SENSING   a turn that ended on a transient network/API failure
;;             reports the `netfail' status, which
;;             `decknix-session-state' maps to the `error' state -- top
;;             of the attention order, `✗' glyph, red row.
;;
;;   RECOVERY  one command resets EVERY session in that state and
;;             re-prompts it, because a dropped link takes down all of
;;             them at once and clearing them one at a time is the
;;             chore this issue was raised about.
;;
;; ---------------------------------------------------------------------
;; Why detection is text-matching, and why that is safe
;; ---------------------------------------------------------------------
;;
;; ACP carries no "the transport died" bit: the failure arrives as agent
;; output like any other text, so the only evidence available is the
;; text.  A naive errno search would be actively dangerous here -- the
;; bulk retry SENDS A PROMPT, so a false positive interrupts a healthy
;; session -- and agents discuss network errors constantly (reviewing
;; retry code, writing a postmortem, reading this very file).
;;
;; Three guards make it safe, all in `decknix--agent-net-error-p':
;;
;;   1. the line must be a REPORTED error (an "API Error:"-shaped
;;      prefix), not prose that happens to contain an errno;
;;   2. it must carry a TRANSIENT fault (errno, socket/fetch failure,
;;      or a 408/429/5xx).  A 401 or a 400 is excluded on purpose:
;;      retrying an auth or schema failure forever is the same wedge in
;;      a different costume;
;;   3. it must be within the last few lines -- the turn ENDED on it.
;;      A failure the agent recovered from and worked past is not a
;;      stuck session.
;;
;; Code fences are stripped first, so a matcher quoted in a diff (the
;; patterns below, for one) is source rather than an incident.
;;
;; The pure layer is ERT-tested; the advice/dispatch wiring lives in the
;; heredoc per AGENTS.md Rule 2.

;;; Code:

(require 'rx)
(require 'subr-x)

(declare-function agent-shell-buffers "ext:agent-shell")
(declare-function agent-shell-workspace-sidebar-refresh "ext:agent-shell-workspace")
(declare-function decknix--session-bulk-dispatch "decknix-agent-shell-main-session" (bufs input))
(declare-function decknix--agent-normalize-turn-end-in-buffer
                  "decknix-agent-heartbeat-watch" (buffer))
(declare-function decknix-agent-turn-reset "decknix-agent-turn-signals" ())

;; ---------------------------------------------------------------------------
;; Tunables
;; ---------------------------------------------------------------------------

(defgroup decknix-agent-net-error nil
  "Transient network-failure detection and bulk retry for agent sessions."
  :group 'decknix)

(defconst decknix-agent-net-error-status "netfail"
  "Status string reported by a session whose turn died on a network fault.
Consumed by `decknix-session-status-signal-map' (-> the `error' state),
the sidebar row painter, the tab tint and the picker's attention rank.
A distinct status rather than reusing `killed': the process is alive and
the session is resumable, which is exactly why a retry is worth
offering.")

(defcustom decknix-agent-net-error-tail-lines 4
  "How many trailing non-blank lines of a turn are scanned for a failure.
Bounds the scan to \"the turn ENDED on this\", which is what makes the
flag mean stuck rather than merely mentioned.  Small: the failure line
is the last thing a dead turn prints."
  :type 'integer :group 'decknix-agent-net-error)

(defcustom decknix-agent-net-error-scan-chars 4000
  "Cap on how much trailing buffer text a rescan reads, in characters.
`decknix-agent-net-error-scan-buffer' runs over every live session when
the bulk command fires, so the cost per session must not scale with the
length of its transcript."
  :type 'integer :group 'decknix-agent-net-error)

(defcustom decknix-agent-net-error-retry-prompt "continue"
  "Prompt broadcast to each recovered session by the bulk retry.
Deliberately minimal: the session already holds the full context of what
it was doing, so anything longer would be re-briefing it on its own
work."
  :type 'string :group 'decknix-agent-net-error)

(defcustom decknix-agent-net-error-retry-stagger 1.5
  "Seconds between successive sessions in a bulk retry.

The reset leaves every target IDLE, so an unstaggered dispatch would put
all of them on the wire at once, each re-uploading a full context — the
same saturation that `decknix-agent-session-bulk-send' exists to avoid
\(it produced 408 Request Timeouts).  It is a worse bet here than there:
a bulk retry runs on a link that has only just come back, and every
session that times out lands straight back in the state we are clearing.

Set to 0 to dispatch everything immediately."
  :type 'number :group 'decknix-agent-net-error)

(defconst decknix-agent-net-error-report-regexp
  (rx line-start (0+ (any " \t>|")) (0+ (any "⚠✗❌•-")) (0+ (any " \t"))
      (or "API Error" "API error" "Api Error"
          "Request failed" "Request error"
          "Connection error" "Connection failed"
          "Fetch error" "Network error"
          "Error")
      (0+ (any " \t")) (or ":" "-" " ") (0+ nonl))
  "Shape of a line that REPORTS an error, as opposed to discussing one.

Anchored at line start and requiring an error-report prefix.  This is
the guard that keeps an agent reviewing retry code -- or reading this
file -- from being flagged and bulk-prompted; see the Commentary.")

(defcustom decknix-agent-net-error-transient-regexp
  (rx (or
       ;; Node/libuv transport errnos: the link itself failed.
       (seq word-boundary
            (or "ECONNRESET" "ECONNREFUSED" "ECONNABORTED" "ENOTFOUND"
                "ETIMEDOUT" "EHOSTUNREACH" "ENETUNREACH" "ENETDOWN"
                "ENETRESET" "EAI_AGAIN" "EPIPE" "EPROTO")
            word-boundary)
       ;; Transport failures that carry no errno.
       "socket hang up" "fetch failed" "network timeout"
       "Unable to connect" "unable to connect"
       "Premature close" "terminated"
       ;; Transient HTTP: overloaded / rate-limited / gateway / timeout.
       ;; 4xx that are NOT transient (401, 403, 400) are excluded on
       ;; purpose -- retrying those forever is the same wedge.
       (seq word-boundary (or "408" "429" "500" "502" "503" "504" "529")
            word-boundary)))
  "Faults that a retry can plausibly clear.

A line must match BOTH this and `decknix-agent-net-error-report-regexp'
to count.  Extend it for an agent whose wording differs; keep
non-transient failures (auth, malformed request) out -- the bulk command
sends a prompt, so anything listed here will be retried on your behalf."
  :type 'regexp :group 'decknix-agent-net-error)

;; ---------------------------------------------------------------------------
;; Pure layer -- ERT-tested.
;; ---------------------------------------------------------------------------

(defun decknix--agent-net-error-strip-fences (text)
  "Return TEXT with fenced code blocks removed.
An error line quoted inside a fence is source -- a pattern list, a log
excerpt pasted for review -- not an incident this session suffered."
  (replace-regexp-in-string "```[^\0]*?```" "" (or text "")))

(defun decknix--agent-net-error-tail-lines (text n)
  "Return the last N non-blank lines of TEXT, in order."
  (let ((lines (seq-remove #'string-empty-p
                           (mapcar #'string-trim (split-string (or text "") "\n")))))
    (if (<= (length lines) n)
        lines
      (nthcdr (- (length lines) n) lines))))

(defun decknix--agent-net-error-line-p (line)
  "Return non-nil when LINE reports a transient network/API failure.
Requires both an error-report shape and a retryable fault; see the
Commentary for why either alone is not enough."
  (and (stringp line)
       (string-match-p decknix-agent-net-error-report-regexp line)
       (string-match-p decknix-agent-net-error-transient-regexp line)
       t))

(defun decknix--agent-net-error-p (text)
  "Return the offending line when TEXT ends on a transient network failure.

Nil when TEXT is absent, discusses a network error without having
suffered one, quotes it inside a code fence, or recovered and carried on
past it.  Returning the LINE rather than t lets callers report what
actually happened (`decknix-agent-net-error-reason')."
  (when (and text (stringp text))
    (seq-find #'decknix--agent-net-error-line-p
              (decknix--agent-net-error-tail-lines
               (decknix--agent-net-error-strip-fences text)
               decknix-agent-net-error-tail-lines))))

(defconst decknix-agent-net-error-refinable-statuses
  '("ready" "finished" "asking" "idle" "working" "unknown")
  "Statuses a network failure may override.

`working' is included deliberately: the observed wedge left the shell
still reporting a turn in flight that was never going to land.  `waiting'
and `killed' are excluded -- a permission prompt is a real block you must
answer, and a dead process needs a restart rather than a `continue'.")

(defun decknix-agent-net-error-refine-status (raw-status flagged)
  "Return `decknix-agent-net-error-status' when FLAGGED, else RAW-STATUS.
Only the statuses in `decknix-agent-net-error-refinable-statuses' are
ever rewritten, so a truth a retry cannot change is never masked."
  (if (and flagged (member raw-status decknix-agent-net-error-refinable-statuses))
      decknix-agent-net-error-status
    raw-status))

(defun decknix-agent-net-error-display-face (status fallback)
  "Return the face for STATUS, or FALLBACK when it is not a network failure.
Upstream's `agent-shell-workspace--status-face' answers `default' for any
status it does not know, which would render a dead session as ordinary
text."
  (if (equal status decknix-agent-net-error-status)
      'error
    fallback))

(defun decknix--agent-net-error-retry-schedule (targets stagger)
  "Return TARGETS paired with their dispatch delay, as (BUFFER . SECONDS).

The Nth target waits N*STAGGER seconds, so the first goes immediately and
the rest fan out behind it.  A STAGGER of 0 (or negative, or non-numeric)
schedules everything at once.  Pure, so the spacing is ERT-testable
without timers."
  (let ((step (if (and (numberp stagger) (> stagger 0)) stagger 0))
        (i -1))
    (mapcar (lambda (buf) (setq i (1+ i)) (cons buf (* i step)))
            targets)))

(defun decknix--agent-net-error-retry-plan (entries all)
  "Return the live buffers to retry from ENTRIES.

ENTRIES is a list of (BUFFER . FLAGGED).  With ALL nil only flagged
buffers are returned; with ALL non-nil every live buffer is, which is the
escape hatch for a failure whose evidence has already scrolled out of the
scan window.  Dead buffers are dropped either way -- a bulk retry must
never dispatch into a killed session."
  (delq nil
        (mapcar (lambda (entry)
                  (let ((buf (car entry)))
                    (and (buffer-live-p buf)
                         (or all (cdr entry))
                         buf)))
                entries)))

;; ---------------------------------------------------------------------------
;; Capture layer -- buffer-local flag.
;; ---------------------------------------------------------------------------

(defvar-local decknix--agent-net-error-reason nil
  "The failure line this session's last turn died on, or nil.")

(defvar-local decknix--agent-net-error-turn-start nil
  "Marker at which the current/last turn's output began, or nil.

The scan floor.  Without it a scan reads whatever happens to be in the
trailing window, so a failure from an EARLIER turn stays in view and a
session that recovered with a short reply gets re-flagged and
re-prompted — the retry sends a prompt, so that is a real cost, not a
cosmetic one.  Nil (a session that predates the flag, or one restored
from disk) falls back to the trailing window.

A MARKER rather than an integer, because a stored integer goes stale the
moment the buffer is rewound: it would then sit past the new text and
clamp the scan to an empty region, silently blinding the detector
exactly when a session was reset.  A marker collapses to the start of
the surviving text instead, which is the floor we wanted anyway.")

(defun decknix-agent-net-error-flagged-p (&optional buffer)
  "Return non-nil when BUFFER's last turn died on a network failure."
  (let ((buf (or buffer (current-buffer))))
    (and (buffer-live-p buf)
         (buffer-local-value 'decknix--agent-net-error-reason buf)
         t)))

(defun decknix-agent-net-error-reason (&optional buffer)
  "Return the failure line BUFFER died on, or nil."
  (let ((buf (or buffer (current-buffer))))
    (and (buffer-live-p buf)
         (buffer-local-value 'decknix--agent-net-error-reason buf))))

(defun decknix-agent-net-error-mark (buffer reason)
  "Flag BUFFER as having died on REASON.  Returns REASON, or nil if dead."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq decknix--agent-net-error-reason reason))))

(defun decknix-agent-net-error-clear (&optional buffer)
  "Clear BUFFER's network-failure flag."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq decknix--agent-net-error-reason nil)))))

(defun decknix-agent-net-error-mark-turn-start (&optional buffer)
  "Record where BUFFER's current turn begins, as the scan floor.
Reuses the existing marker so a long-lived session accumulates one, not
one per turn."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (if (markerp decknix--agent-net-error-turn-start)
            (set-marker decknix--agent-net-error-turn-start (point-max))
          (setq decknix--agent-net-error-turn-start (copy-marker (point-max))))))))

(defun decknix--agent-net-error-scan-floor (buffer)
  "Return the position in BUFFER from which a scan should read.

The later of this turn's start and the trailing-window cap.  The turn
floor is what keeps an EARLIER turn's failure from being read as this
one's; the cap is what keeps the scan O(1) rather than proportional to
the transcript.  A marker belonging to another buffer (or none) is
ignored rather than trusted."
  (with-current-buffer buffer
    (let* ((marker decknix--agent-net-error-turn-start)
           (turn (and (markerp marker)
                      (eq (marker-buffer marker) buffer)
                      (marker-position marker)))
           (window (max (point-min)
                        (- (point-max) decknix-agent-net-error-scan-chars))))
      (if turn (max turn window) window))))

(defun decknix--agent-net-error-buffer-tail (buffer)
  "Return the text of BUFFER's current turn, capped for cost.
See `decknix--agent-net-error-scan-floor'."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (buffer-substring-no-properties
       (decknix--agent-net-error-scan-floor buffer)
       (point-max)))))

(defun decknix-agent-net-error-scan-buffer (buffer)
  "Re-derive BUFFER's network-failure flag from this turn's own output.

Sets the flag when the turn ended on a failure and CLEARS a stale one
when it did not, so a session that recovered on its own is never
re-prompted by the bulk retry.  Returns the failure line, or nil.

Reading the buffer rather than the ACP stream deliberately: it is the one
seam that sees both the agent's own error text and the fragment
agent-shell renders on the request-failure path, and it costs nothing
until a turn ends or a rescan is asked for."
  (when (buffer-live-p buffer)
    (let ((reason (decknix--agent-net-error-p
                   (decknix--agent-net-error-buffer-tail buffer))))
      (if reason
          (decknix-agent-net-error-mark buffer reason)
        (decknix-agent-net-error-clear buffer))
      reason)))

;; ---------------------------------------------------------------------------
;; Live layer -- sensing seam, status advice, and the bulk reset.
;; ---------------------------------------------------------------------------

(defun decknix--agent-net-error-live-buffers ()
  "Return the live agent-shell buffers, or nil when agent-shell is absent."
  (and (fboundp 'agent-shell-buffers)
       (seq-filter #'buffer-live-p (ignore-errors (agent-shell-buffers)))))

(defun decknix--agent-net-error-observe-event (&rest args)
  "Flag the current session when its turn ends on a network failure.

Installed as `:before' advice on `agent-shell--emit-event'.  Uses
`current-buffer', safely and for the same reason
`decknix--agent-turn-observe-event' does: `agent-shell--emit-event' has
already made the owning shell buffer current by the time it dispatches.

Costs nothing per streamed chunk -- it only acts on the two events that
bracket a turn -- so unlike a chunk accumulator it stays off the hot
path entirely."
  (when (derived-mode-p 'agent-shell-mode)
    (pcase (plist-get args :event)
      ('turn-complete (decknix-agent-net-error-scan-buffer (current-buffer)))
      ;; A new turn supersedes the last one's failure: whatever happens
      ;; now is the session's current truth.  Recording the floor here is
      ;; what stops the previous turn's error line staying in view and
      ;; re-flagging a session that has since recovered.
      ('input-submitted
       (decknix-agent-net-error-clear (current-buffer))
       (decknix-agent-net-error-mark-turn-start (current-buffer)))
      (_ nil))))

(defun decknix--agent-net-error-status-advice (orig-fn buffer &rest args)
  "Around-advice for `agent-shell-workspace--buffer-status': add `netfail'.

Wraps the whole existing advice chain, so it sees the status already
refined by `decknix--agent-turn-status-advice' (`asking') and hardened by
`decknix--agent-buffer-status-harden' (stale `working' -> `ready') and
has the final say.  That ordering is the point: a session that is dead on
the link should not be reported as merely idle or merely asking."
  (let ((raw (apply orig-fn buffer args)))
    (if (buffer-live-p buffer)
        (decknix-agent-net-error-refine-status
         raw (decknix-agent-net-error-flagged-p buffer))
      raw)))

(defun decknix--agent-net-error-reset-buffer (buffer)
  "Reset BUFFER's failed-turn state so a fresh prompt can land.

Clears the flag, the residual turn state agent-shell's failure path
leaves behind (`:tool-calls' plus the busy flag -- without this the shell
believes a turn is still in flight and refuses the prompt), and the
turn-end facts that would otherwise keep reporting the dead turn's
question."
  (when (buffer-live-p buffer)
    (decknix-agent-net-error-clear buffer)
    (when (fboundp 'decknix--agent-normalize-turn-end-in-buffer)
      (decknix--agent-normalize-turn-end-in-buffer buffer))
    (when (fboundp 'decknix-agent-turn-reset)
      (with-current-buffer buffer (decknix-agent-turn-reset)))))

(defun decknix--agent-net-error-dispatch-staggered (targets prompt)
  "Send PROMPT to each of TARGETS, spaced by the retry stagger.

Each session goes through `decknix--session-bulk-dispatch' individually
so it still gets that function's idle/busy routing (submit now vs queue
until ready); the stagger only decides WHEN each one is offered.

Buffers are rebound per iteration: `dolist' reuses one binding and
`setq's it, so a closure over the loop variable would see every timer
fire against the LAST buffer."
  (dolist (entry (decknix--agent-net-error-retry-schedule
                  targets decknix-agent-net-error-retry-stagger))
    (let ((buf (car entry))
          (delay (cdr entry)))
      (if (<= delay 0)
          (decknix--session-bulk-dispatch (list buf) prompt)
        (run-at-time delay nil
                     (lambda ()
                       ;; Re-check liveness: the user may have closed the
                       ;; session while the queue drained.
                       (when (and (buffer-live-p buf)
                                  (fboundp 'decknix--session-bulk-dispatch))
                         (decknix--session-bulk-dispatch (list buf) prompt))))))))

;;;###autoload
(defun decknix-agent-net-error-reset-all (&optional all)
  "Reset every session stuck on a network failure, WITHOUT re-prompting.

Rescans each live session first, so a failure the streaming seam missed
is still found and one that has since recovered is not touched.  With a
prefix argument ALL, resets every live session regardless.

Use this when you want the sidebar honest again but intend to steer the
sessions yourself; `decknix-agent-net-error-retry-all' is the same reset
followed by a `continue'."
  (interactive "P")
  (let* ((bufs (decknix--agent-net-error-live-buffers))
         (_ (mapc #'decknix-agent-net-error-scan-buffer bufs))
         (targets (decknix--agent-net-error-retry-plan
                   (mapcar (lambda (b)
                             (cons b (decknix-agent-net-error-flagged-p b)))
                           bufs)
                   all)))
    (mapc #'decknix--agent-net-error-reset-buffer targets)
    (when (fboundp 'agent-shell-workspace-sidebar-refresh)
      (agent-shell-workspace-sidebar-refresh))
    (let ((n (length targets)))
      (message "Network-failure reset: %d session%s cleared%s"
               n (if (= n 1) "" "s")
               (if (and (zerop n) (not all))
                   " (none stuck — C-u to reset all)"
                 ""))
      n)))

;;;###autoload
(defun decknix-agent-net-error-retry-all (&optional all)
  "Reset every network-failed session and broadcast a `continue' to each.

This is the recovery half of ldeck/decknix#162: one dropped link kills
every in-flight session at once, so clearing them one at a time is the
chore.  Run it after the link is back.

Rescans before acting, so a session that recovered on its own is left
alone and one whose failure the streaming seam missed is still caught.
With a prefix argument ALL, re-prompts every live session -- the escape
hatch for a failure that has already scrolled out of the scan window.

Dispatch reuses `decknix--session-bulk-dispatch', so an idle session is
prompted immediately while a busy one is queued rather than saturating
the link the moment it comes back.  The prompt is
`decknix-agent-net-error-retry-prompt'."
  (interactive "P")
  (let* ((bufs (decknix--agent-net-error-live-buffers))
         (_ (mapc #'decknix-agent-net-error-scan-buffer bufs))
         (targets (decknix--agent-net-error-retry-plan
                   (mapcar (lambda (b)
                             (cons b (decknix-agent-net-error-flagged-p b)))
                           bufs)
                   all)))
    (cond
     ((null targets)
      (message "No session is stuck on a network failure%s"
               (if all "" " (C-u to retry all live sessions)"))
      0)
     ((not (fboundp 'decknix--session-bulk-dispatch))
      (message "Bulk dispatch unavailable — reset only")
      (mapc #'decknix--agent-net-error-reset-buffer targets)
      0)
     (t
      (mapc #'decknix--agent-net-error-reset-buffer targets)
      (decknix--agent-net-error-dispatch-staggered
       targets decknix-agent-net-error-retry-prompt)
      (when (fboundp 'agent-shell-workspace-sidebar-refresh)
        (agent-shell-workspace-sidebar-refresh))
      (let ((n (length targets)))
        (message "Network-failure retry: %d session%s re-prompted%s"
                 n (if (= n 1) "" "s")
                 (if (> decknix-agent-net-error-retry-stagger 0)
                     (format " (staggered %.1fs apart)"
                             decknix-agent-net-error-retry-stagger)
                   ""))
        n)))))

;;;###autoload
(defun decknix-agent-net-error-list ()
  "Report which sessions are stuck on a network failure, and why."
  (interactive)
  (let* ((bufs (decknix--agent-net-error-live-buffers))
         (_ (mapc #'decknix-agent-net-error-scan-buffer bufs))
         (stuck (seq-filter #'decknix-agent-net-error-flagged-p bufs)))
    (if (null stuck)
        (message "No session is stuck on a network failure")
      (message "%d stuck on the network:\n%s"
               (length stuck)
               (mapconcat (lambda (b)
                            (format "  %s — %s"
                                    (buffer-name b)
                                    (decknix-agent-net-error-reason b)))
                          stuck "\n")))))

(provide 'decknix-agent-net-error)
;;; decknix-agent-net-error.el ends here
