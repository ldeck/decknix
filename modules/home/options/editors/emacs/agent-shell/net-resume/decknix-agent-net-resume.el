;;; decknix-agent-net-resume.el --- Resume sessions a dropped link stopped -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, network

;;; Commentary:
;;
;; `decknix-agent-net-error' flags a session whose turn died on the
;; network (`netfail') and offers a manual bulk retry.  On 2026-11-24
;; and 25 a run of DNS blips stopped every session in flight, each
;; with "API Error: Can't reach the API server ... (ENOTFOUND)", and
;; every one needed a typed "continue" once the link was back.  This
;; file does that typing, under rules strict enough that it never
;; speaks over the user:
;;
;;   CLASSIFY  only a reachability failure (DNS, reset, refused,
;;             timeout, "Can't reach the API server") or an overloaded
;;             API (502/503/504/529) is resumable.  A cancel, a login
;;             or quota failure, a rate limit, a bare 500, a tool error
;;             or a refusal never is.
;;
;;   WATCH     only while at least one session waits on the network:
;;             `notifyutil -w com.apple.system.config.network_change'
;;             (event-driven, macOS) plus an async probe of the agent's
;;             API host on an exponential backoff.  Nothing runs, not
;;             even a timer, while no session waits.
;;
;;   RESUME    when the probe succeeds, each waiting session that is
;;             still idle, still `netfail', not asking the user, with no
;;             unsent or queued input, gets one prompt, staggered and
;;             jittered.  A session the user has since typed into is
;;             never touched: `input-submitted' from the user drops its
;;             record.  At most `decknix-agent-net-resume-max-attempts'
;;             per failure streak, with backoff between them.
;;
;; The attempt count is persisted per session id before each submit, so
;; an Emacs restart (agent processes survive it in the broker) neither
;; repeats a resume nor resets the cap.
;;
;; The pure layer (classification, decision, backoff, schedule, watcher
;; transitions, badge) is ERT-tested; the effect layer only interprets
;; the actions the transitions return.

;;; Code:

(require 'cl-lib)
(require 'rx)
(require 'subr-x)
(require 'decknix-agent-net-error)
(require 'decknix-state-io)

(declare-function agent-shell-buffers "ext:agent-shell")
(declare-function agent-shell-get-config "ext:agent-shell" (buffer))
(declare-function agent-shell-workspace--buffer-status "ext:agent-shell-workspace" (buffer))
(declare-function agent-shell-workspace-sidebar-refresh "ext:agent-shell-workspace")
(declare-function decknix--compose-submit-after-wait "decknix-agent-shell-main-compose" (target input))
(declare-function decknix--compose-queue-normalise "decknix-agent-compose-queue" (queue))
(declare-function decknix--agent-buffer-session-id "decknix-agent-buffer-lookup" (&optional buf))

(defvar decknix--agent-turn-question)
(defvar decknix--compose-queued-prompt)
(defvar decknix--compose-target-buffer)
(defvar shell-maker--busy)

;; ---------------------------------------------------------------------------
;; Tunables
;; ---------------------------------------------------------------------------

(defgroup decknix-agent-net-resume nil
  "Automatically resume agent sessions a dropped link stopped."
  :group 'decknix)

(defcustom decknix-agent-net-resume-enabled t
  "When non-nil, resume network-failed sessions once the link is back.
Toggle with `decknix-agent-net-resume-toggle' (sidebar toggles `Z').
Turning it off stops the watcher at once."
  :type 'boolean :group 'decknix-agent-net-resume)

(defcustom decknix-agent-net-resume-max-attempts 3
  "Most automatic resumes per failure streak of one session.
The streak ends when a turn completes without failing, or the user
sends input.  After the cap the session stays `netfail' for you."
  :type 'integer :group 'decknix-agent-net-resume)

(defcustom decknix-agent-net-resume-prompt
  "The network dropped and is back. Continue where you left off; re-run any step that failed because of the network."
  "Prompt sent to a session resumed after a reachability failure."
  :type 'string :group 'decknix-agent-net-resume)

(defcustom decknix-agent-net-resume-overloaded-prompt
  "The API was overloaded and has had time to recover. Continue where you left off; re-run any step that failed because of it."
  "Prompt sent to a session resumed after an overloaded API (502/503/504/529)."
  :type 'string :group 'decknix-agent-net-resume)

(defcustom decknix-agent-net-resume-min-interval 30
  "Never resume one session twice within this many seconds.
A backstop under the attempt cap: it survives the user taking a session
over (which resets the cap), so no sequence of events can make a
flapping link drive a tight resume loop."
  :type 'number :group 'decknix-agent-net-resume)

(defcustom decknix-agent-net-resume-stagger 4.0
  "Seconds between successive sessions resumed by one recovery.
Every resumed session re-uploads its context; a link that has only just
come back is the worst place to send them all at once."
  :type 'number :group 'decknix-agent-net-resume)

(defcustom decknix-agent-net-resume-jitter 3.0
  "Up to this many random seconds added to each resume's delay."
  :type 'number :group 'decknix-agent-net-resume)

(defcustom decknix-agent-net-resume-probe-backoff '(10 . 300)
  "(BASE . CAP) seconds between reachability probes while sessions wait.
The Nth consecutive failed probe waits BASE*2^N, at most CAP.  The
network-change notification short-circuits the wait."
  :type '(cons number number) :group 'decknix-agent-net-resume)

(defcustom decknix-agent-net-resume-overloaded-backoff '(60 . 900)
  "(BASE . CAP) seconds before resuming a session the API turned away.
Attempt N waits BASE*2^N, at most CAP.  The link is up, so no probe."
  :type '(cons number number) :group 'decknix-agent-net-resume)

(defcustom decknix-agent-net-resume-hosts
  '((claude-code . "api.anthropic.com")
    (codex . "api.openai.com")
    (pi . "api.anthropic.com")
    (auggie . "api.augmentcode.com")
    (gemini-cli . "generativelanguage.googleapis.com")
    (antigravity . "generativelanguage.googleapis.com"))
  "API host probed for each agent-shell provider identifier.
A host named in the failure itself (\"getaddrinfo ENOTFOUND HOST\") wins.
Unlisted providers use `decknix-agent-net-resume-default-host'."
  :type '(alist :key-type symbol :value-type string)
  :group 'decknix-agent-net-resume)

(defcustom decknix-agent-net-resume-default-host "api.anthropic.com"
  "API host probed when neither the failure nor the provider names one."
  :type 'string :group 'decknix-agent-net-resume)

(defcustom decknix-agent-net-resume-notify-key
  "com.apple.system.config.network_change"
  "Darwin notification posted when the network configuration changes.
Ignored when `notifyutil' is not on `exec-path' (non-macOS): the probe
backoff alone then decides when to look again."
  :type 'string :group 'decknix-agent-net-resume)

(defcustom decknix-agent-net-resume-state-file
  (expand-file-name "decknix/net-resume.eld"
                    (or (getenv "XDG_STATE_HOME") "~/.local/state"))
  "Where per-session attempt counts persist across Emacs restarts."
  :type 'file :group 'decknix-agent-net-resume)

(defcustom decknix-agent-net-resume-startup-delay 60
  "Idle seconds after start before restored sessions are rescanned.
Gives the broker reattach time to render each session's last turns."
  :type 'number :group 'decknix-agent-net-resume)

;; ---------------------------------------------------------------------------
;; Pure layer: classification
;; ---------------------------------------------------------------------------

(defconst decknix-agent-net-resume--api-line-regexp
  (rx string-start (0+ (any " \t>|")) (0+ (any "⚠✗❌•-")) (0+ (any " \t"))
      (or "API Error" "API error" "Api Error" "Connection error"
          "Request failed" "Network error" "Fetch error" "stream error"
          "Stream error"))
  "Prefix of a failure the AGENT'S OWN API call reported.
Stricter than the net-error report shape, which also takes a bare
\"Error:\": that is what a tool prints, and a tool that could not reach
its own service is not a reason to re-prompt the session.")

(defconst decknix-agent-net-resume--never-regexps
  `((quota . ,(rx (or "usage limit" "weekly limit" "daily limit" "monthly limit"
                      "credit balance" "budget" "quota" "billing"
                      "insufficient_quota" "exceeded your")))
    (auth . ,(rx (or "authenticat" "OAuth" "oauth" "Not logged in" "/login"
                     "Unauthorized" "unauthorized" "Forbidden" "forbidden"
                     "invalid x-api-key" "invalid api key" "API key"
                     (seq word-boundary (or "401" "403") word-boundary))))
    (rate-limit . ,(rx (or "rate limit" "rate_limit" "Rate limit"
                           "Too Many Requests" "too many requests"
                           (seq word-boundary "429" word-boundary))))
    (local . ,(rx (or "localhost" "127.0.0.1" "[::1]" "0.0.0.0"))))
  "Failure markers that rule a resume out, checked before the resumable ones.
Order is the precedence: a line naming a quota and an errno is a quota.")

(defconst decknix-agent-net-resume--network-regexp
  (rx (or (seq word-boundary
               (or "ENOTFOUND" "EAI_AGAIN" "ECONNRESET" "ECONNREFUSED"
                   "ECONNABORTED" "ETIMEDOUT" "EHOSTUNREACH" "ENETUNREACH"
                   "ENETDOWN" "ENETRESET" "EPIPE")
               word-boundary)
          "Can't reach the API server" "Unable to connect"
          "unable to connect" "socket hang up" "fetch failed"
          "network timeout" "Connection closed mid-response"
          "Stream idle timeout" "Premature close" "terminated"
          "NameResolutionError" "Name or service not known"
          "nodename nor servname" "Temporary failure in name resolution"
          "error sending request" "stream disconnected"))
  "Reachability faults: the request never got an answer.")

(defconst decknix-agent-net-resume--overloaded-regexp
  (rx (or "overloaded" "Overloaded" "Bad Gateway" "Service Unavailable"
          "Gateway Timeout" "Request Timeout"
          (seq word-boundary (or "408" "502" "503" "504" "529") word-boundary)))
  "The API answered, but turned the request away for now.")

(defun decknix-agent-net-resume-classify (reason)
  "Return the resume class of failure line REASON.

`network' and `overloaded' are resumable.  `quota', `auth',
`rate-limit' and `local' are reported so the reason can be shown, but
never resumed; `server' is a bare 500, which repeats as often as it
clears.  Nil when REASON is not an API failure at all (a tool's own
error, prose, nothing)."
  (when (and (stringp reason)
             (string-match-p decknix-agent-net-resume--api-line-regexp reason))
    (let ((case-fold-search nil))
      (or (car (seq-find (lambda (entry) (string-match-p (cdr entry) reason))
                         decknix-agent-net-resume--never-regexps))
          (and (string-match-p decknix-agent-net-resume--network-regexp reason)
               'network)
          (and (string-match-p decknix-agent-net-resume--overloaded-regexp reason)
               'overloaded)
          (and (string-match-p (rx (or (seq word-boundary "500" word-boundary)
                                       "Internal server error"
                                       "Internal Server Error"))
                               reason)
               'server)))))

(defun decknix-agent-net-resume-resumable-p (class)
  "Return non-nil when failure CLASS may be resumed automatically."
  (memq class '(network overloaded)))

(defun decknix-agent-net-resume-host-from-reason (reason)
  "Return the host REASON names (\"ENOTFOUND api.example.com\"), or nil."
  (when (and (stringp reason)
             (string-match (rx (or "ENOTFOUND" "EAI_AGAIN") (1+ space)
                               (group (1+ (any alnum ".-"))))
                           reason))
    (match-string 1 reason)))

(defun decknix-agent-net-resume-host-for (identifier reason)
  "Return the API host to probe for provider IDENTIFIER failing on REASON."
  (or (decknix-agent-net-resume-host-from-reason reason)
      (alist-get identifier decknix-agent-net-resume-hosts)
      decknix-agent-net-resume-default-host))

;; ---------------------------------------------------------------------------
;; Pure layer: decision, backoff, schedule
;; ---------------------------------------------------------------------------

(defun decknix-agent-net-resume-backoff (attempt base cap)
  "Return BASE*2^ATTEMPT seconds, at most CAP."
  (min cap (* base (expt 2 (max 0 attempt)))))

(defun decknix-agent-net-resume-decide (facts)
  "Return what to do with one session, from the plist FACTS.

`resume', `wait' (not due yet), or a symbol naming why not.  Checked
in this order, so the reason given is the most fundamental one:

  :enabled nil       disabled       :busy t            busy
  :live nil          dead           :unsent t          user-typing
  :suppressed t      suppressed     :queued t          queued
  :class not resumable  not-resumable
  :status not netfail   not-netfail :attempts >= :max  gave-up
  :asking t          asking         :now - :last < :min-interval  too-soon
                                    :now < :not-before wait

`not-netfail' covers a permission prompt, a dead process and a session
the user has already re-prompted: the status chain no longer says it
is stuck on the link."
  (cl-destructuring-bind (&key enabled live suppressed class status asking
                               busy unsent queued (attempts 0) (max 3)
                               (now 0) (not-before 0) last (min-interval 0)
                               &allow-other-keys)
      facts
    (cond ((not enabled) 'disabled)
          ((not live) 'dead)
          (suppressed 'suppressed)
          ((not (decknix-agent-net-resume-resumable-p class)) 'not-resumable)
          ((not (equal status decknix-agent-net-error-status)) 'not-netfail)
          (asking 'asking)
          (busy 'busy)
          (unsent 'user-typing)
          (queued 'queued)
          ((>= attempts max) 'gave-up)
          ((and last (< (- now last) min-interval)) 'too-soon)
          ((< now not-before) 'wait)
          (t 'resume))))

(defun decknix-agent-net-resume-schedule (items stagger jitter random-fn)
  "Return ITEMS paired with their delay in seconds, as (ITEM . DELAY).
The Nth item waits N*STAGGER plus (RANDOM-FN JITTER).  RANDOM-FN is
injected so the spacing is testable; the live caller passes a uniform
random float."
  (let ((i -1)
        (step (if (and (numberp stagger) (> stagger 0)) stagger 0))
        (spread (if (and (numberp jitter) (> jitter 0)) jitter 0)))
    (mapcar (lambda (item)
              (setq i (1+ i))
              (cons item (+ (* i step)
                            (if (> spread 0) (funcall random-fn spread) 0))))
            items)))

(defun decknix-agent-net-resume-prompt-for (class attempt max)
  "Return the resume prompt for failure CLASS on ATTEMPT of MAX.
Starts with the resume glyph so the transcript shows which prompts were
automatic."
  (format "↻ %s [auto-resume %d/%d]"
          (if (eq class 'overloaded)
              decknix-agent-net-resume-overloaded-prompt
            decknix-agent-net-resume-prompt)
          attempt max))

(defun decknix-agent-net-resume-badge-for (record flagged)
  "Return the sidebar badge for RECORD, or nil.

  ↻…    waiting for the link (no resume sent yet)
  ↻N    N resumes sent in this streak, still failing
  ↻✗    gave up after the cap: over to you
  ↻off  suppressed for this session
  ↻     resumed, and the next turn got through

A session this recovery skipped (the user was typing, it asked a
question) shows nothing extra: it is a plain `netfail' for you now.
FLAGGED is whether the session is `netfail' now."
  (when record
    (let ((attempts (or (plist-get record :attempts) 0)))
      (cond ((plist-get record :suppressed) (and flagged "↻off"))
            ((and flagged (plist-get record :gave-up)) "↻✗")
            ((and flagged (plist-get record :skipped)
                  (not (eq (plist-get record :skipped) 'scheduled)))
             nil)
            ((and flagged (plist-get record :class)
                  (decknix-agent-net-resume-resumable-p (plist-get record :class)))
             (if (zerop attempts) "↻…" (format "↻%d" attempts)))
            ((plist-get record :resumed) "↻")))))

;; ---------------------------------------------------------------------------
;; Pure layer: the watcher state machine
;; ---------------------------------------------------------------------------

(defun decknix-agent-net-resume-watch-step (state event)
  "Return (NEW-STATE . ACTIONS) for the watcher in STATE receiving EVENT.

STATE is a plist (:phase P :failures N); P is `idle' (nothing waits,
nothing runs), `waiting' (notification process up, next probe on a
timer) or `probing' (a probe in flight).

EVENT is (pending N), (change), (timer), (probe-ok) or (probe-fail).
ACTIONS are interpreted by the effect layer, in order:
  start-notify stop-notify (schedule SECS) cancel-timer start-probe
  kill-probe recovered

A change or timer while a probe runs is dropped: the probe answers the
same question.  A successful probe goes back to `idle'; the effect layer
then recounts, and re-arms only if a session still waits."
  (let* ((phase (or (plist-get state :phase) 'idle))
         (failures (or (plist-get state :failures) 0))
         (base (car decknix-agent-net-resume-probe-backoff))
         (cap (cdr decknix-agent-net-resume-probe-backoff)))
    (pcase (car event)
      ('pending
       (let ((n (or (cadr event) 0)))
         (cond ((and (<= n 0) (eq phase 'idle)) (cons state nil))
               ((<= n 0) (cons (list :phase 'idle :failures 0)
                               '(cancel-timer kill-probe stop-notify)))
               ((eq phase 'idle)
                (cons (list :phase 'waiting :failures 0)
                      (list 'start-notify (list 'schedule base))))
               (t (cons state nil)))))
      ((or 'change 'timer)
       (if (eq phase 'waiting)
           (cons (list :phase 'probing :failures failures)
                 '(cancel-timer start-probe))
         (cons state nil)))
      ('probe-ok
       (if (eq phase 'idle)
           (cons state nil)
         (cons (list :phase 'idle :failures 0)
               '(cancel-timer stop-notify recovered))))
      ('probe-fail
       (if (eq phase 'idle)
           (cons state nil)
         (let ((n (1+ failures)))
           (cons (list :phase 'waiting :failures n)
                 (list (list 'schedule
                             (decknix-agent-net-resume-backoff n base cap)))))))
      (_ (cons state nil)))))

(defun decknix-agent-net-resume-probe-command (hosts curl nc)
  "Return the argv that succeeds only when every one of HOSTS answers.

CURL and NC are the executables found on `exec-path', or nil.  curl
does DNS, TCP and TLS and counts ANY HTTP answer (a 401 or 404 too) as
reachable, since the question is whether the API is there, not whether
this request is welcome.  nc checks DNS and TCP to port 443 only.  Nil
when neither exists; the watcher then trusts the network-change
notification alone."
  (when hosts
    (cond
     (curl
      (cl-list* "sh" "-c"
            (concat "for h in \"$@\"; do "
                    (shell-quote-argument curl)
                    " -sS -o /dev/null -I --connect-timeout 5 -m 10 \"https://$h/\" || exit 1; done")
            "probe" hosts))
     (nc
      (cl-list* "sh" "-c"
            (concat "for h in \"$@\"; do "
                    (shell-quote-argument nc)
                    " -z -G 5 \"$h\" 443 || exit 1; done")
            "probe" hosts)))))

;; ---------------------------------------------------------------------------
;; Records: one per session id, persisted
;; ---------------------------------------------------------------------------

(defvar decknix-agent-net-resume--records nil
  "Alist of (SESSION-KEY . PLIST) for sessions in a failure streak.
PLIST keys: :class :reason :host :attempts :last :not-before :gave-up
:suppressed :resumed :skipped.  Loaded lazily from
`decknix-agent-net-resume-state-file'.")

(defvar decknix-agent-net-resume--loaded nil
  "Non-nil once the records were read from disk.")

(defvar decknix-agent-net-resume--last-written nil
  "Text of the last write, so an unchanged store is never rewritten.")

(defvar decknix-agent-net-resume-session-key-function
  #'decknix-agent-net-resume--default-session-key
  "Function of BUFFER returning its stable session key (a string).")

(defun decknix-agent-net-resume--default-session-key (buffer)
  "Return BUFFER's ACP session id, or its name when it has none yet."
  (or (and (fboundp 'decknix--agent-buffer-session-id)
           (ignore-errors (decknix--agent-buffer-session-id buffer)))
      (buffer-name buffer)))

(defun decknix-agent-net-resume--key (buffer)
  "Return the record key for BUFFER."
  (funcall decknix-agent-net-resume-session-key-function buffer))

(defun decknix-agent-net-resume--load ()
  "Read the record store once.  Entries older than a week are dropped."
  (unless decknix-agent-net-resume--loaded
    (setq decknix-agent-net-resume--loaded t)
    (let ((file decknix-agent-net-resume-state-file)
          (horizon (- (float-time) (* 7 24 3600))))
      (when (file-readable-p file)
        (setq decknix-agent-net-resume--records
              (seq-filter
               (lambda (entry)
                 (and (stringp (car entry))
                      (> (or (plist-get (cdr entry) :last)
                             (plist-get (cdr entry) :seen) 0)
                         horizon)))
               (decknix-state-io-read-list file)))))))

(defun decknix-agent-net-resume--save ()
  "Write the record store when it changed, atomically."
  (let ((text (decknix-state-io-to-string
               decknix-agent-net-resume--records))
        (file decknix-agent-net-resume-state-file))
    (unless (equal text decknix-agent-net-resume--last-written)
      (condition-case err
          (progn
            (make-directory (file-name-directory file) t)
            (let ((tmp (make-temp-name (concat file ".tmp"))))
              (with-temp-file tmp (insert text))
              (rename-file tmp file t))
            (setq decknix-agent-net-resume--last-written text))
        (error (message "decknix-agent-net-resume: save failed: %S" err))))))

(defun decknix-agent-net-resume-record (buffer)
  "Return BUFFER's record plist, or nil."
  (decknix-agent-net-resume--load)
  (cdr (assoc (decknix-agent-net-resume--key buffer)
              decknix-agent-net-resume--records)))

(defun decknix-agent-net-resume--put (buffer plist)
  "Store PLIST as BUFFER's record (nil removes it) and persist."
  (decknix-agent-net-resume--load)
  (let ((key (decknix-agent-net-resume--key buffer)))
    (setq decknix-agent-net-resume--records
          (assoc-delete-all key decknix-agent-net-resume--records))
    (when plist
      (push (cons key plist) decknix-agent-net-resume--records))
    (decknix-agent-net-resume--save)
    plist))

(defun decknix-agent-net-resume--update (buffer &rest props)
  "Set PROPS on BUFFER's record, creating it."
  (let ((rec (copy-sequence (decknix-agent-net-resume-record buffer))))
    (while props
      (setq rec (plist-put rec (pop props) (pop props))))
    (decknix-agent-net-resume--put buffer rec)))

(defun decknix-agent-net-resume-badge (buffer)
  "Return the sidebar badge for live BUFFER, or nil.  No I/O after load."
  (when (buffer-live-p buffer)
    (decknix-agent-net-resume-badge-for
     (decknix-agent-net-resume-record buffer)
     (decknix-agent-net-error-flagged-p buffer))))

;; ---------------------------------------------------------------------------
;; Facts about a live session
;; ---------------------------------------------------------------------------

(defvar decknix-agent-net-resume-status-function
  #'decknix-agent-net-resume--default-status
  "Function of BUFFER returning its status string (`netfail', `waiting', ...).")

(defvar decknix-agent-net-resume-submit-function
  #'decknix--compose-submit-after-wait
  "Function of (BUFFER INPUT) that submits INPUT, non-nil when it was sent.")

(defvar decknix-agent-net-resume-random-function
  (lambda (n) (* n (/ (random 1000) 1000.0)))
  "Function of N returning a random float in [0, N).")

(defun decknix-agent-net-resume--default-status (buffer)
  "Return BUFFER's status through the full refinement chain."
  (if (fboundp 'agent-shell-workspace--buffer-status)
      (agent-shell-workspace--buffer-status buffer)
    (and (decknix-agent-net-error-flagged-p buffer)
         decknix-agent-net-error-status)))

(defun decknix-agent-net-resume--unsent-p (buffer)
  "Return non-nil when BUFFER has text typed but not sent.
Both the shell prompt and any compose buffer aimed at BUFFER count."
  (or (with-current-buffer buffer
        (let ((proc (get-buffer-process buffer)))
          (and proc (process-mark proc)
               (marker-buffer (process-mark proc))
               (not (string-blank-p
                     (buffer-substring-no-properties
                      (min (point-max) (process-mark proc)) (point-max)))))))
      (seq-some (lambda (b)
                  (and (eq (buffer-local-value 'decknix--compose-target-buffer b)
                           buffer)
                       (with-current-buffer b
                         (not (string-blank-p (buffer-string))))))
                (seq-filter (lambda (b)
                              (local-variable-p 'decknix--compose-target-buffer b))
                            (buffer-list)))))

(defun decknix-agent-net-resume--queued-p (buffer)
  "Return non-nil when BUFFER has prompts waiting in its compose queue."
  (let ((q (and (local-variable-p 'decknix--compose-queued-prompt buffer)
                (buffer-local-value 'decknix--compose-queued-prompt buffer))))
    (and q (if (fboundp 'decknix--compose-queue-normalise)
               (decknix--compose-queue-normalise q)
             t))))

(defun decknix-agent-net-resume--facts (buffer)
  "Return the decision facts for BUFFER now."
  (let* ((live (buffer-live-p buffer))
         (rec (and live (decknix-agent-net-resume-record buffer))))
    (list :enabled decknix-agent-net-resume-enabled
          :live live
          :suppressed (plist-get rec :suppressed)
          :class (plist-get rec :class)
          :status (and live (ignore-errors
                              (funcall decknix-agent-net-resume-status-function buffer)))
          :asking (and live (local-variable-p 'decknix--agent-turn-question buffer)
                       (buffer-local-value 'decknix--agent-turn-question buffer)
                       t)
          :busy (and live (local-variable-p 'shell-maker--busy buffer)
                     (buffer-local-value 'shell-maker--busy buffer)
                     t)
          :unsent (and live (decknix-agent-net-resume--unsent-p buffer))
          :queued (and live (decknix-agent-net-resume--queued-p buffer))
          :attempts (or (plist-get rec :attempts) 0)
          :max decknix-agent-net-resume-max-attempts
          :now (float-time)
          :not-before (or (plist-get rec :not-before) 0)
          :last (plist-get rec :last)
          :min-interval decknix-agent-net-resume-min-interval)))

(defun decknix-agent-net-resume--identifier (buffer)
  "Return BUFFER's agent-shell provider identifier, or nil."
  (and (fboundp 'agent-shell-get-config)
       (ignore-errors
         (let ((config (agent-shell-get-config buffer)))
           (and (listp config) (alist-get :identifier config))))))

;; ---------------------------------------------------------------------------
;; Effect layer: the watcher
;; ---------------------------------------------------------------------------

(defvar decknix-agent-net-resume--watch '(:phase idle :failures 0)
  "Current watcher state; see `decknix-agent-net-resume-watch-step'.")

(defvar decknix-agent-net-resume--notify-proc nil)
(defvar decknix-agent-net-resume--probe-proc nil)
(defvar decknix-agent-net-resume--timer nil)
(defvar decknix-agent-net-resume--debounce nil
  "Timer collapsing a burst of network-change notifications into one.")
(defvar decknix-agent-net-resume--due-timer nil
  "Timer for the earliest overloaded session's resume.")
(defvar decknix-agent-net-resume--startup-timer nil)

(defvar decknix-agent-net-resume-process-function #'make-process
  "Constructor for the watcher's child processes; ERT stubs it.")

(defun decknix-agent-net-resume--live-buffers ()
  "Return the live agent-shell buffers."
  (and (fboundp 'agent-shell-buffers)
       (seq-filter #'buffer-live-p (ignore-errors (agent-shell-buffers)))))

(defun decknix-agent-net-resume--waiting-on (class)
  "Return the live buffers in a streak of CLASS that could still resume."
  (seq-filter
   (lambda (buf)
     (let ((rec (decknix-agent-net-resume-record buf)))
       (and rec (eq (plist-get rec :class) class)
            (not (plist-get rec :suppressed))
            (not (plist-get rec :gave-up))
            (not (plist-get rec :skipped))
            (decknix-agent-net-error-flagged-p buf))))
   (decknix-agent-net-resume--live-buffers)))

(defun decknix-agent-net-resume--dispatch (event)
  "Feed EVENT to the watcher and carry out the actions it returns."
  (let* ((step (decknix-agent-net-resume-watch-step
                decknix-agent-net-resume--watch event)))
    (setq decknix-agent-net-resume--watch (car step))
    (dolist (action (cdr step))
      (pcase action
        ('start-notify (decknix-agent-net-resume--start-notify))
        ('stop-notify (decknix-agent-net-resume--stop-notify))
        (`(schedule ,secs)
         (decknix-agent-net-resume--cancel-timer)
         (setq decknix-agent-net-resume--timer
               (run-at-time secs nil #'decknix-agent-net-resume--dispatch '(timer))))
        ('cancel-timer (decknix-agent-net-resume--cancel-timer))
        ('start-probe (decknix-agent-net-resume--start-probe))
        ('kill-probe (decknix-agent-net-resume--kill-probe))
        ('recovered (decknix-agent-net-resume--on-recovered))))))

(defun decknix-agent-net-resume--cancel-timer ()
  (when (timerp decknix-agent-net-resume--timer)
    (cancel-timer decknix-agent-net-resume--timer))
  (setq decknix-agent-net-resume--timer nil))

(defun decknix-agent-net-resume--notify-filter (_proc output)
  "Turn a network-change line in OUTPUT into one debounced `change' event.
The configuration changes several times while an interface comes up, and
DNS is often the last piece; two seconds of quiet first."
  (when (string-match-p (regexp-quote decknix-agent-net-resume-notify-key) output)
    (when (timerp decknix-agent-net-resume--debounce)
      (cancel-timer decknix-agent-net-resume--debounce))
    (setq decknix-agent-net-resume--debounce
          (run-at-time 2 nil #'decknix-agent-net-resume--dispatch '(change)))))

(defun decknix-agent-net-resume--start-notify ()
  "Start the network-change listener when macOS provides one."
  (let ((exe (executable-find "notifyutil")))
    (when (and exe (not (process-live-p decknix-agent-net-resume--notify-proc)))
      (setq decknix-agent-net-resume--notify-proc
            (ignore-errors
              (funcall decknix-agent-net-resume-process-function
                       :name "decknix-net-change"
                       :command (list exe "-w" decknix-agent-net-resume-notify-key)
                       :noquery t
                       :connection-type 'pipe
                       :filter #'decknix-agent-net-resume--notify-filter
                       :sentinel #'ignore))))))

(defun decknix-agent-net-resume--stop-notify ()
  (when (timerp decknix-agent-net-resume--debounce)
    (cancel-timer decknix-agent-net-resume--debounce))
  (setq decknix-agent-net-resume--debounce nil)
  (when (process-live-p decknix-agent-net-resume--notify-proc)
    (delete-process decknix-agent-net-resume--notify-proc))
  (setq decknix-agent-net-resume--notify-proc nil))

(defun decknix-agent-net-resume--kill-probe ()
  (when (process-live-p decknix-agent-net-resume--probe-proc)
    (delete-process decknix-agent-net-resume--probe-proc))
  (setq decknix-agent-net-resume--probe-proc nil))

(defun decknix-agent-net-resume--probe-sentinel (proc _event)
  "Report PROC's verdict to the watcher once it has exited."
  (when (memq (process-status proc) '(exit signal))
    (when (eq proc decknix-agent-net-resume--probe-proc)
      (setq decknix-agent-net-resume--probe-proc nil)
      (decknix-agent-net-resume--dispatch
       (if (and (eq (process-status proc) 'exit) (zerop (process-exit-status proc)))
           '(probe-ok)
         '(probe-fail))))))

(defun decknix-agent-net-resume--start-probe ()
  "Probe every host a waiting session needs, in a child process."
  (let* ((hosts (delete-dups
                 (mapcar (lambda (b) (plist-get (decknix-agent-net-resume-record b) :host))
                         (decknix-agent-net-resume--waiting-on 'network))))
         (argv (decknix-agent-net-resume-probe-command
                (delq nil hosts) (executable-find "curl") (executable-find "nc"))))
    (decknix-agent-net-resume--kill-probe)
    (cond
     ((null hosts) (decknix-agent-net-resume--dispatch '(pending 0)))
     ((null argv) (decknix-agent-net-resume--dispatch '(probe-ok)))
     (t
      (setq decknix-agent-net-resume--probe-proc
            (condition-case nil
                (funcall decknix-agent-net-resume-process-function
                         :name "decknix-net-probe"
                         :command argv
                         :noquery t
                         :connection-type 'pipe
                         :buffer nil
                         :sentinel #'decknix-agent-net-resume--probe-sentinel)
              (error nil)))
      (unless decknix-agent-net-resume--probe-proc
        (decknix-agent-net-resume--dispatch '(probe-fail)))))))

(defun decknix-agent-net-resume-recount ()
  "Arm or disarm the watcher and the overloaded timer to match the records."
  (let ((network (if decknix-agent-net-resume-enabled
                     (length (decknix-agent-net-resume--waiting-on 'network))
                   0)))
    (decknix-agent-net-resume--dispatch (list 'pending network)))
  (decknix-agent-net-resume--arm-due-timer))

(defun decknix-agent-net-resume--arm-due-timer ()
  "Time the next overloaded resume, or cancel the timer when none waits."
  (when (timerp decknix-agent-net-resume--due-timer)
    (cancel-timer decknix-agent-net-resume--due-timer))
  (setq decknix-agent-net-resume--due-timer nil)
  (let ((due (and decknix-agent-net-resume-enabled
                  (mapcar (lambda (b) (or (plist-get (decknix-agent-net-resume-record b)
                                                     :not-before)
                                          0))
                          (decknix-agent-net-resume--waiting-on 'overloaded)))))
    (when due
      (setq decknix-agent-net-resume--due-timer
            (run-at-time (max 1 (- (apply #'min due) (float-time))) nil
                         #'decknix-agent-net-resume--on-due)))))

(defun decknix-agent-net-resume--on-due ()
  (setq decknix-agent-net-resume--due-timer nil)
  (decknix-agent-net-resume--resume-class 'overloaded)
  (decknix-agent-net-resume--arm-due-timer))

(defun decknix-agent-net-resume--on-recovered ()
  "The API host answers again: resume what waited on it, then recount."
  (decknix-agent-net-resume--resume-class 'network)
  (decknix-agent-net-resume-recount))

;; ---------------------------------------------------------------------------
;; Effect layer: resuming
;; ---------------------------------------------------------------------------

(defvar-local decknix-agent-net-resume--submitting nil
  "Non-nil while this buffer's own `input-submitted' is our resume.")

(defun decknix-agent-net-resume--resume-class (class)
  "Offer a resume to every session waiting on CLASS, staggered."
  (let* ((candidates (decknix-agent-net-resume--waiting-on class))
         (decided (mapcar (lambda (b)
                            (cons b (decknix-agent-net-resume-decide
                                     (decknix-agent-net-resume--facts b))))
                          candidates))
         (go (mapcar #'car (seq-filter (lambda (d) (eq (cdr d) 'resume)) decided))))
    (dolist (d decided)
      (pcase (cdr d)
        ('resume nil)
        ((or 'wait 'too-soon)
         (let* ((rec (decknix-agent-net-resume-record (car d)))
                (at (max (or (plist-get rec :not-before) 0)
                         (+ (or (plist-get rec :last) 0)
                            decknix-agent-net-resume-min-interval))))
           (decknix-agent-net-resume--update (car d) :skipped 'scheduled)
           (run-at-time (max 1 (- at (float-time))) nil
                        #'decknix-agent-net-resume--resume-one (car d))))
        ('gave-up (decknix-agent-net-resume--update (car d) :gave-up t))
        ;; This recovery is spent on it: someone is at the keyboard, the
        ;; agent asked a question, or it woke up by itself.  Never queue
        ;; a resume behind the user.
        (why (decknix-agent-net-resume--update (car d) :skipped why))))
    (dolist (entry (decknix-agent-net-resume-schedule
                    go decknix-agent-net-resume-stagger decknix-agent-net-resume-jitter
                    decknix-agent-net-resume-random-function))
      (run-at-time (cdr entry) nil #'decknix-agent-net-resume--resume-one (car entry)))
    (when go
      (message "↻ Resuming %d session%s after %s"
               (length go) (if (cdr go) "s" "")
               (if (eq class 'overloaded) "an overloaded API" "network loss")))
    go))

(defun decknix-agent-net-resume--resume-one (buffer)
  "Resume BUFFER if, at this moment, every rule still allows it.

The attempt is counted and saved BEFORE the submit, so a crash between
the two costs an attempt rather than repeating one."
  (when (buffer-live-p buffer)
    (let ((decision (decknix-agent-net-resume-decide
                     (decknix-agent-net-resume--facts buffer))))
      (if (not (eq decision 'resume))
          (decknix-agent-net-resume--update buffer :skipped decision)
        (let* ((rec (decknix-agent-net-resume-record buffer))
               (attempt (1+ (or (plist-get rec :attempts) 0)))
               (prompt (decknix-agent-net-resume-prompt-for
                        (plist-get rec :class) attempt
                        decknix-agent-net-resume-max-attempts)))
          (decknix-agent-net-resume--update buffer :attempts attempt
                                            :last (float-time) :resumed t)
          (decknix--agent-net-error-reset-buffer buffer)
          (with-current-buffer buffer
            (setq decknix-agent-net-resume--submitting t))
          (let ((sent (ignore-errors
                        (funcall decknix-agent-net-resume-submit-function buffer prompt))))
            ;; `input-submitted' fires inside the submit, so the flag is
            ;; consumed by now; clear it regardless so the user's next
            ;; prompt is never mistaken for ours.
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (setq decknix-agent-net-resume--submitting nil)))
            (unless sent
              (decknix-agent-net-resume--update buffer :skipped 'submit-refused)
              (message "↻ Could not resume %s: the submit was refused"
                       (buffer-name buffer))))
          (when (fboundp 'agent-shell-workspace-sidebar-refresh)
            (agent-shell-workspace-sidebar-refresh)))))))

;; ---------------------------------------------------------------------------
;; Listener on net-error's turn boundaries
;; ---------------------------------------------------------------------------

(defun decknix-agent-net-resume-on-change (buffer event)
  "Track BUFFER's failure streak across agent-shell EVENT.

Installed on `decknix-agent-net-error-change-functions'."
  (when (buffer-live-p buffer)
    (pcase event
      ('input-submitted
       (if (buffer-local-value 'decknix-agent-net-resume--submitting buffer)
           (with-current-buffer buffer
             (setq decknix-agent-net-resume--submitting nil))
         ;; The user took over: whatever streak there was is theirs now.
         (let ((rec (decknix-agent-net-resume-record buffer)))
           (when rec
             (decknix-agent-net-resume--put
              buffer (and (or (plist-get rec :suppressed) (plist-get rec :last))
                          (list :suppressed (plist-get rec :suppressed)
                                :last (plist-get rec :last)
                                :seen (float-time))))))))
      ((or 'turn-complete 'error)
       (let ((reason (decknix-agent-net-error-reason buffer)))
         (cond
          (reason (decknix-agent-net-resume--note-failure buffer reason))
          ;; A clean turn ends the streak; keep the ↻ for the resumed one.
          ((eq event 'turn-complete)
           (let ((rec (decknix-agent-net-resume-record buffer)))
             (when rec
               (decknix-agent-net-resume--put
                buffer
                (and (or (plist-get rec :resumed) (plist-get rec :suppressed))
                     (list :resumed (plist-get rec :resumed)
                           :suppressed (plist-get rec :suppressed)
                           :last (plist-get rec :last)
                           :seen (float-time))))))))))))
  (decknix-agent-net-resume-recount))

(defun decknix-agent-net-resume--note-failure (buffer reason)
  "Record that BUFFER's turn died on REASON."
  (let* ((rec (decknix-agent-net-resume-record buffer))
         (class (decknix-agent-net-resume-classify reason))
         (attempts (or (plist-get rec :attempts) 0)))
    (decknix-agent-net-resume--update
     buffer
     :class class :reason reason :seen (float-time)
     :host (decknix-agent-net-resume-host-for
            (decknix-agent-net-resume--identifier buffer) reason)
     :attempts attempts :skipped nil
     :gave-up (>= attempts decknix-agent-net-resume-max-attempts)
     :not-before (if (eq class 'overloaded)
                     (+ (float-time)
                        (decknix-agent-net-resume-backoff
                         attempts
                         (car decknix-agent-net-resume-overloaded-backoff)
                         (cdr decknix-agent-net-resume-overloaded-backoff)))
                   ;; A repeat network failure waits out the probe backoff
                   ;; too, so a flapping link is not hit on every blip.
                   (if (zerop attempts) 0
                     (+ (float-time)
                        (decknix-agent-net-resume-backoff
                         (1- attempts)
                         (car decknix-agent-net-resume-probe-backoff)
                         (cdr decknix-agent-net-resume-probe-backoff))))))))

(defun decknix-agent-net-resume-sweep ()
  "Rescan every live session and register those stuck on the network.
Run once after startup, when broker-reattached sessions have rendered
their last turns but no live turn boundary has fired for them."
  (interactive)
  (setq decknix-agent-net-resume--startup-timer nil)
  (dolist (buf (decknix-agent-net-resume--live-buffers))
    (let ((reason (decknix-agent-net-error-scan-buffer buf)))
      (when reason
        (decknix-agent-net-resume--note-failure buf reason))))
  (decknix-agent-net-resume-recount))

(defun decknix-agent-net-resume-start ()
  "Hook the listener in and schedule one startup sweep.  Idempotent."
  (add-hook 'decknix-agent-net-error-change-functions
            #'decknix-agent-net-resume-on-change)
  (unless (timerp decknix-agent-net-resume--startup-timer)
    (setq decknix-agent-net-resume--startup-timer
          (run-with-idle-timer decknix-agent-net-resume-startup-delay nil
                               #'decknix-agent-net-resume--sweep-when-quiet))))

(defun decknix-agent-net-resume--sweep-when-quiet ()
  "Run the startup sweep, re-deferring while the user is typing."
  (if (input-pending-p)
      (setq decknix-agent-net-resume--startup-timer
            (run-with-idle-timer (+ (decknix-agent-net-resume--idle-seconds) 5) nil
                                 #'decknix-agent-net-resume--sweep-when-quiet))
    (decknix-agent-net-resume-sweep)))

(defun decknix-agent-net-resume--idle-seconds ()
  "Return the current idle time in seconds, or 0."
  (let ((idle (current-idle-time)))
    (if idle (float-time idle) 0)))

(defun decknix-agent-net-resume-stop ()
  "Stop every process and timer the watcher owns."
  (setq decknix-agent-net-resume--watch '(:phase idle :failures 0))
  (decknix-agent-net-resume--cancel-timer)
  (decknix-agent-net-resume--kill-probe)
  (decknix-agent-net-resume--stop-notify)
  (when (timerp decknix-agent-net-resume--due-timer)
    (cancel-timer decknix-agent-net-resume--due-timer))
  (setq decknix-agent-net-resume--due-timer nil))

;; ---------------------------------------------------------------------------
;; Commands
;; ---------------------------------------------------------------------------

;;;###autoload
(defun decknix-agent-net-resume-toggle ()
  "Turn automatic resume after network loss on or off."
  (interactive)
  (setq decknix-agent-net-resume-enabled (not decknix-agent-net-resume-enabled))
  (if decknix-agent-net-resume-enabled
      (decknix-agent-net-resume-recount)
    (decknix-agent-net-resume-stop))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Auto-resume after network loss %s"
           (if decknix-agent-net-resume-enabled "on" "off")))

(defun decknix-agent-net-resume--read-session ()
  "Return the current agent-shell buffer, or one read from the user."
  (if (derived-mode-p 'agent-shell-mode)
      (current-buffer)
    (let ((bufs (decknix-agent-net-resume--live-buffers)))
      (unless bufs (user-error "No live agent session"))
      (get-buffer (completing-read "Session: " (mapcar #'buffer-name bufs) nil t)))))

;;;###autoload
(defun decknix-agent-net-resume-suppress (buffer)
  "Toggle automatic resume for the session in BUFFER alone.
Suppression lasts until toggled back, across failures and restarts."
  (interactive (list (decknix-agent-net-resume--read-session)))
  (let ((now (not (plist-get (decknix-agent-net-resume-record buffer) :suppressed))))
    (decknix-agent-net-resume--update buffer :suppressed now :skipped nil
                                      :seen (float-time))
    (decknix-agent-net-resume-recount)
    (when (fboundp 'agent-shell-workspace-sidebar-refresh)
      (agent-shell-workspace-sidebar-refresh))
    (message "Auto-resume %s for %s" (if now "suppressed" "allowed")
             (buffer-name buffer))))

(provide 'decknix-agent-net-resume)
;;; decknix-agent-net-resume.el ends here
