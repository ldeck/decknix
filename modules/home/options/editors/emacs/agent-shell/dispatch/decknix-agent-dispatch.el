;;; decknix-agent-dispatch.el --- Explicit-approval CLI-to-session prompt dispatch -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, dispatch

;;; Commentary:
;;
;; Receiver half of `decknix-agent-dispatch' (the CLI is the sender).  An
;; outside process hands ONE prompt to ONE live agent-shell session by
;; dropping a request file; this module delivers it through the same submit
;; path the compose buffer uses, and records what happened in a receipt.
;; Nothing here talks to Emacs over `emacsclient -e', opens another ACP
;; attachment, or resumes a session: the only channel is a private directory.
;;
;; State lives in a 0700 directory (`decknix-agent-dispatch-dir'):
;;
;;   pending/   <request-id>.json   written by the CLI (atomic rename, 0600)
;;   inflight/  <request-id>.json   claimed by this receiver (atomic rename)
;;              <request-id>.attempt  marker written just before submit
;;   receipts/  <request-id>.json   one per request, never overwritten
;;   tmp/       scratch for atomic writes
;;
;; Delivery is AT MOST ONCE.  The request is renamed pending -> inflight (an
;; atomic claim; a second claimer loses) before anything else, the attempt
;; marker is written before the submit call, and the receipt is written before
;; the inflight file is removed.  There is no retry anywhere: a crash or an
;; ambiguous outcome produces `unknown' (marker seen) or `not-sent' (never
;; attempted) on recovery.
;;
;; Receipt states: accepted, rejected, expired, not-sent, unknown.  An
;; accepted version 2 request later gains `<id>.answered.json' when the
;; session's turn ends (or goes quiet on background work), and a sender that
;; asked for `notify' gets a notice under notices/<sender-id>/.
;;
;; Version 2 requests (written by `decknix session send') add a delivery
;; mode: `idle' waits for the session, including on text the user is
;; typing; `now' is refused when the session is busy; `interrupt' cancels
;; the running turn first, subject to `decknix-agent-dispatch-interrupt-policy'
;; and a rate limit.  Version 1 requests keep their original semantics.
;;
;; Version 3 requests carry a `kind' and change which sessions exist rather
;; than what one is told (`decknix session spawn' and `retire'):
;;
;;   spawn   start a lane in the background (or resume its saved session),
;;           unless exactly one live session already carries every requested
;;           tag, in which case nothing is started and that lane is reported.
;;           `receipts/<id>.spawned.json' follows once the new session has an
;;           id: {session_id, buffer, outcome new|resumed|existing}, or
;;           {state spawn-failed, reason}.
;;   retire  quit exactly one live session whose tags still match, once it
;;           is idle (or at once with `force'), never one carrying a
;;           protected tag or holding text the user has not sent.
;;
;; Both are governed by `decknix-agent-dispatch-lifecycle-policy'.  The
;; third kind, `dispatch' (arm or disarm this receiver), never arrives
;; here: it goes to control/ and is handled by the separately enabled
;; `decknix-agent-dispatch-control' watcher.
;;
;; The receiver fails closed on: an id that is not an exact lowercase UUID, no
;; or several live buffers holding the session, a buffer that changed between
;; claim and submit, a dead process, text the user has typed but not sent, a
;; stale or future-dated request, a request older than the moment the receiver
;; was armed, an unsafe file (symlink, wrong mode or owner, oversized), and a
;; unsafe state directory.  A busy session is waited on until the request's
;; own expiry; only a version 2 `interrupt' request that the interrupt policy
;; allows ever cancels a turn.
;;
;; Installing this package is inert: it defines functions and a global minor
;; mode, and starts no timer, watch or directory.  Delivery only happens while
;; `decknix-agent-dispatch-mode' is on, which is a deliberate user action.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'filenotify)

(defvar shell-maker--busy)
(defvar agent-shell-confirm-interrupt)
(defvar decknix--agent-turn-message-tail)

(defgroup decknix-agent-dispatch nil
  "Explicit-approval prompt dispatch into live agent-shell sessions."
  :group 'tools)

(declare-function decknix--compose-submit-after-wait "decknix-agent-shell-main-compose"
                  (target input))
(declare-function decknix--agent-buffer-session-id "decknix-agent-buffer-lookup"
                  (&optional buf))
(declare-function agent-shell-buffers "agent-shell")
(declare-function agent-shell-interrupt "agent-shell" (&optional force))
(declare-function decknix--agent-tags-for-session "decknix-agent-tags-read" (session-id))
(declare-function decknix-agent-turn-closing-text "decknix-agent-turn-signals"
                  (&optional buffer))
(declare-function decknix-agent-session-export-background-p
                  "decknix-agent-session-export" (buf))
(declare-function decknix--agent-tags-resolve "decknix-agent-tags-read" (conv-key session-id))
(declare-function decknix--agent-current-conv-key "decknix-agent-buffer-lookup" ())
(declare-function decknix--agent-find-new-shell-buffer "decknix-agent-buffer-lookup"
                  (before-buffers))
(declare-function decknix--agent-conv-key-for-session-id "decknix-agent-conv-resolve"
                  (session-id))
(declare-function decknix--agent-quickaction-start "decknix-agent-shell-main-link"
                  (name tags workspace command &optional model provider-id mode
                        background review-prs additional-roots))
(declare-function decknix--agent-session-resume "decknix-agent-shell-main-session"
                  (session-id history-count &optional display-name workspace
                              conv-key search-term background))
(declare-function decknix-agent-spawn-enqueue "decknix-agent-spawn-queue" (thunk))
(declare-function decknix-agent-get-provider "decknix-agent-provider" (id))
(declare-function decknix-session-lifecycle-quit "decknix-agent-session-lifecycle"
                  (buffers &optional noconfirm))
(defvar decknix-agent-session-history-count)

(defvar decknix-agent-dispatch-dir
  (expand-file-name "decknix/agent-dispatch"
                    (or (getenv "XDG_STATE_HOME") "~/.local/state"))
  "Private state directory shared with the `decknix-agent-dispatch' CLI.")

(defvar decknix-agent-dispatch-max-ttl 900
  "Longest lifetime in seconds a version 1 request may claim.")

(defvar decknix-agent-dispatch-max-ttl-v2 (* 7 24 3600)
  "Longest lifetime in seconds a version 2 request may claim.
Long because an idle delivery waits for the session's turn to end, and a
lane turn routinely outlasts the 900 s a version 1 request may live: 89 of
1089 requests expired that way before version 2 existed.")

(defvar decknix-agent-dispatch-max-reason-chars 300
  "Longest `reason' a version 2 request may carry.")

(defcustom decknix-agent-dispatch-interrupt-policy 'coordinator
  "Who may interrupt a busy session with a `when: interrupt' request.
`never'       nobody.
`opt-in'      only sessions tagged with one of
              `decknix-agent-dispatch-interruptible-tags'.
`coordinator' senders tagged with one of
              `decknix-agent-dispatch-coordinator-tags', or opted-in sessions.
`always'      any sender.
Self-interrupts, the rate limit and the loop guard apply to every policy."
  :type '(choice (const never) (const opt-in) (const coordinator) (const always))
  :group 'decknix-agent-dispatch)

(defcustom decknix-agent-dispatch-coordinator-tags '("coordinator")
  "Session tags that let a sender interrupt under the `coordinator' policy."
  :type '(repeat string)
  :group 'decknix-agent-dispatch)

(defcustom decknix-agent-dispatch-interruptible-tags '("interruptible")
  "Session tags by which a session accepts interrupts from any sender."
  :type '(repeat string)
  :group 'decknix-agent-dispatch)

(defcustom decknix-agent-dispatch-interrupt-min-interval 300
  "Seconds after an interrupt before the same session may be interrupted again.
Also the window in which an interrupted session may not interrupt its
interrupter back, so two sessions cannot cancel each other in a loop."
  :type 'integer
  :group 'decknix-agent-dispatch)

(defcustom decknix-agent-dispatch-lifecycle-policy 'coordinator
  "Who may spawn or retire sessions with a version 3 request.
`never'       nobody.
`coordinator' (default) senders tagged with one of
              `decknix-agent-dispatch-coordinator-tags'.
`always'      any sender, including a request with no sender."
  :type '(choice (const never) (const coordinator) (const always))
  :group 'decknix-agent-dispatch)

(defcustom decknix-agent-dispatch-spawn-roots '("~/Code" "~/tools")
  "Directories a spawned session's workspace must be in or below."
  :type '(repeat directory)
  :group 'decknix-agent-dispatch)

(defcustom decknix-agent-dispatch-agent-providers
  '(("claude" . claude-code) ("auggie" . auggie) ("pi" . pi))
  "Agent names a spawn request may carry, and the provider id each starts.
The names are the ones `decknix session' uses (its `--agent' values and
the store's agent field); the ids are what
`decknix-agent-register-provider' registered.  Keep it in step with
`SPAWN_AGENTS' in cli/src/session_lifecycle.rs, which refuses any other
name before writing a request."
  :type '(alist :key-type string :value-type symbol)
  :group 'decknix-agent-dispatch)

(defcustom decknix-agent-dispatch-spawn-max-live 12
  "Counted lanes at or above which a spawn is refused (`too-many-sessions').
See `decknix-agent-dispatch-counted-lanes' for what counts."
  :type 'integer
  :group 'decknix-agent-dispatch)

(defcustom decknix-agent-dispatch-spawn-counted-tag-regexp "\\`lane-[0-9]+\\'"
  "A live session with a tag matching this (ignoring case) counts as a lane.
Lanes count toward `decknix-agent-dispatch-spawn-max-live', as do sessions
this receiver spawned whatever their tags.  Auto-review and human sessions
carry no such tag, so they never use up the cap.  Nil counts only spawned
sessions."
  :type '(choice (const :tag "Spawned sessions only" nil) regexp)
  :group 'decknix-agent-dispatch)

(defcustom decknix-agent-dispatch-spawn-min-interval 10
  "Seconds after one spawn before another may start (`spawn-rate-limited')."
  :type 'integer
  :group 'decknix-agent-dispatch)

(defcustom decknix-agent-dispatch-retire-protected-tags '("coordinator")
  "Session tags that make a session impossible to retire by request."
  :type '(repeat string)
  :group 'decknix-agent-dispatch)

(defvar decknix-agent-dispatch-max-ttl-v3 86400
  "Longest lifetime in seconds a version 3 (spawn or retire) request may claim.")

(defvar decknix-agent-dispatch-spawn-timeout 180
  "Seconds a spawn may take to produce a session id before `spawn-failed'.")

(defvar decknix-agent-dispatch-spawn-settle-seconds 4
  "Seconds a resumed session must stay idle before its brief is submitted.
A resume can auto-send a continuation primer when the session first
reports ready; waiting out a short idle stretch keeps the brief from
racing it.")

(defvar decknix-agent-dispatch-arming-source nil
  "Who is arming the receiver, bound around `decknix-agent-dispatch-mode'.
nil means the human; the control watcher binds \"control:<sender>\".")

(defvar decknix-agent-dispatch-arming-release-queued nil
  "Non-nil, bound around arming, to release spawns queued before it.")

(defvar decknix-agent-dispatch-interrupt-function
  (lambda (buf)
    (with-current-buffer buf
      (when (fboundp 'agent-shell-interrupt)
        (let ((agent-shell-confirm-interrupt nil))
          (agent-shell-interrupt)))))
  "Called with a session buffer to cancel its running turn.
The same call compose's interrupt-and-submit makes.")

(defvar decknix-agent-dispatch-tags-function
  (lambda (sid) (and (fboundp 'decknix--agent-tags-for-session)
                     (ignore-errors (decknix--agent-tags-for-session sid))))
  "Called with a session id; returns that session's tags.")

(defvar decknix-agent-dispatch-settled-function
  (lambda (buf) (and (fboundp 'decknix-agent-session-export-background-p)
                     (decknix-agent-session-export-background-p buf)))
  "Called with a busy session buffer; non-nil when its turn is only waiting.
Lets an `answered' receipt fire for a turn the agent keeps open while a
background task it started runs, which can be hours.")

(defvar decknix-agent-dispatch-closing-text-function
  (lambda (buf) (and (fboundp 'decknix-agent-turn-closing-text)
                     (or (decknix-agent-turn-closing-text buf)
                         (buffer-local-value 'decknix--agent-turn-message-tail buf))))
  "Called with a session buffer; returns the text its turn closed with.")

(defvar decknix-agent-dispatch-answer-chars 600
  "Characters of closing text kept in an `answered' receipt.")

(defvar decknix-agent-dispatch-max-prompt-bytes 65536
  "Largest prompt, in UTF-8 bytes, the receiver will deliver.")

(defvar decknix-agent-dispatch-poll-interval 2
  "Seconds between scans; file-notify only makes a scan happen sooner.")

(defvar decknix-agent-dispatch-clock-skew 60
  "Seconds a request's creation time may lead the receiver's clock.")

(defvar decknix-agent-dispatch-submit-function #'decknix--compose-submit-after-wait
  "Called with (BUFFER INPUT); non-nil only when INPUT was really submitted.")

(defvar decknix-agent-dispatch-session-id-function
  (lambda (buf) (and (fboundp 'decknix--agent-buffer-session-id)
                     (decknix--agent-buffer-session-id buf)))
  "Called with a buffer; returns its full session id or nil.")

(defvar decknix-agent-dispatch-buffers-function
  (lambda () (and (fboundp 'agent-shell-buffers) (agent-shell-buffers)))
  "Returns the agent-shell buffers to consider.")

(defvar decknix-agent-dispatch-live-tags-function
  (lambda (buf)
    (when (fboundp 'decknix--agent-tags-resolve)
      (with-current-buffer buf
        (decknix--agent-tags-resolve
         (and (fboundp 'decknix--agent-current-conv-key)
              (decknix--agent-current-conv-key))
         (ignore-errors (funcall decknix-agent-dispatch-session-id-function buf))))))
  "Called with a live session buffer; returns its tags as the sidebar shows them.")

(defvar decknix-agent-dispatch-spawn-function #'decknix-agent-dispatch--start-session
  "Called with (SPEC CALLBACK) to start a new session without showing it.
SPEC is a plist (:name :tags :workspace :brief :agent :model :mode).
CALLBACK is called once with (BUFFER nil) or (nil REASON).")

(defvar decknix-agent-dispatch-resume-function #'decknix-agent-dispatch--resume-session
  "Called with (SPEC CALLBACK) to resume SPEC's :session_id in the background.
Same SPEC and CALLBACK contract as `decknix-agent-dispatch-spawn-function'.")

(defvar decknix-agent-dispatch-retire-function
  (lambda (buf) (decknix-session-lifecycle-quit (list buf) t))
  "Called with a session buffer to quit it and stop its broker.")

(defvar decknix-agent-dispatch--active (make-hash-table :test 'equal)
  "Claimed requests awaiting an idle session: id -> (:req REQ :buffer BUF).")
(defvar decknix-agent-dispatch--delivered (make-hash-table :test 'equal)
  "Accepted version 2 requests whose turn has not ended: id -> plist.")
(defvar decknix-agent-dispatch--last-delivered (make-hash-table :test 'equal)
  "Session id -> (:id ID :at EPOCH :from SENDER) of its last delivery.")
(defvar decknix-agent-dispatch--interrupts nil
  "Recent interrupts, newest first: (FROM TO AT).")
(defvar decknix-agent-dispatch--armed-at nil
  "Epoch second the receiver was armed; earlier requests are refused.")
(defvar decknix-agent-dispatch--armed-by nil
  "\"human\", or \"control:<sender>\" when a control request armed it.")
(defvar decknix-agent-dispatch--release-queued nil
  "Non-nil when the arming control request asked to release queued spawns.")
(defvar decknix-agent-dispatch--spawning (make-hash-table :test 'equal)
  "Accepted spawns awaiting a session id: id -> plist.")
(defvar decknix-agent-dispatch--lane-buffers nil
  "Buffers a spawn started or resumed; they count as lanes while live.")
(defvar decknix-agent-dispatch--last-spawn-at nil
  "Epoch second of the last spawn or resume started, for the rate limit.")
(defvar decknix-agent-dispatch--timer nil)
(defvar decknix-agent-dispatch--watch nil)
(defvar decknix-agent-dispatch--kick nil)
(defvar decknix-agent-dispatch--pending-seen nil
  "(MTIME . AT) of pending/ when a listing last left nothing unread, or nil.")

(defvar decknix-agent-dispatch-rescan-interval 30
  "Seconds after which the poll lists pending/ even though its mtime is unchanged.
A backstop for a filesystem whose directory mtime did not move; file-notify
and the mtime check make a new request visible well before this.")

(defconst decknix-agent-dispatch--uuid-regexp
  "[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}")

(defconst decknix-agent-dispatch--subdirs
  '("pending" "inflight" "receipts" "tmp" "notices" "control"))

(defconst decknix-agent-dispatch--modes '("idle" "now" "interrupt"))

(defconst decknix-agent-dispatch--reserved-prompts '("help" "clear" "config")
  "Inputs shell-maker handles itself and never sends to the agent.")

;; -- pure ----------------------------------------------------------

(defun decknix-agent-dispatch--now ()
  (floor (float-time)))

(defun decknix-agent-dispatch--uuid-p (s)
  "Non-nil when S is exactly a lowercase 36-character UUID."
  (and (stringp s)
       (let ((case-fold-search nil))
         (string-match-p (concat "\\`" decknix-agent-dispatch--uuid-regexp "\\'") s))
       t))

(defun decknix-agent-dispatch--prompt-hash (prompt)
  (secure-hash 'sha256 (encode-coding-string prompt 'utf-8)))

(defun decknix-agent-dispatch--v2-fields-bad (req)
  "Return a reason when REQ's version 2 fields are malformed, else nil."
  (let ((mode (plist-get req :when))
        (from (plist-get req :from))
        (reason (plist-get req :reason))
        (name (plist-get req :from_name)))
    (cond
     ((and mode (not (member mode decknix-agent-dispatch--modes))) "bad-mode")
     ((and from (not (decknix-agent-dispatch--uuid-p from))) "bad-from")
     ((and reason (not (and (stringp reason)
                            (<= (length reason)
                                decknix-agent-dispatch-max-reason-chars))))
      "bad-reason")
     ((and (equal mode "interrupt")
           (not (and (stringp reason) (not (string-empty-p (string-trim reason))))))
      "interrupt-needs-reason")
     ((and name (not (and (stringp name) (<= (length name) 80)))) "bad-from-name"))))

(defun decknix-agent-dispatch--mode (req)
  "Delivery mode of REQ: `idle', `now' or `interrupt'; nil for version 1."
  (when (eql (plist-get req :v) 2)
    (intern (or (plist-get req :when) "idle"))))

(defun decknix-agent-dispatch--times-bad (req max-ttl now)
  "Return why REQ's created/expiry times are unusable at NOW, else nil."
  (let ((created (plist-get req :created_at))
        (expires (plist-get req :expires_at)))
    (cond
     ((not (and (integerp created) (integerp expires))) "bad-times")
     ((> created (+ now decknix-agent-dispatch-clock-skew)) "future-dated")
     ((<= expires created) "bad-times")
     ((> (- expires created) max-ttl) "ttl-too-long")
     ((>= now expires) "expired"))))

(defun decknix-agent-dispatch--text-bad (text hash)
  "Return why TEXT (with claimed sha256 HASH) cannot be submitted, else nil."
  (cond
   ((not (stringp text)) "malformed")
   ((string-empty-p (string-trim text)) "empty-prompt")
   ((member (downcase (string-trim text)) decknix-agent-dispatch--reserved-prompts)
    "reserved-prompt")
   ((> (length (encode-coding-string text 'utf-8))
       decknix-agent-dispatch-max-prompt-bytes)
    "prompt-too-large")
   ((not (equal hash (decknix-agent-dispatch--prompt-hash text))) "hash-mismatch")))

(defun decknix-agent-dispatch--string-list (v &optional allow-empty)
  "V (a JSON array) as a list of short non-blank strings, or `:bad'."
  (if (and (vectorp v)
           (or allow-empty (> (length v) 0))
           (seq-every-p (lambda (s) (and (stringp s)
                                         (not (string-empty-p (string-trim s)))
                                         (<= (length s) 80)))
                        v))
      (append v nil)
    :bad))

(defun decknix-agent-dispatch--short-strings-bad (req keys)
  (seq-some (lambda (k)
              (let ((v (plist-get req k)))
                (and v (not (and (stringp v) (<= (length v) 200))))))
            keys))

(defun decknix-agent-dispatch--v3-fields-bad (req)
  "Return a reason when REQ's version 3 fields are malformed, else nil."
  (let ((kind (plist-get req :kind))
        (from (plist-get req :from))
        (name (plist-get req :from_name))
        (reason (plist-get req :reason))
        (resume (plist-get req :resume_session_id)))
    (cond
     ((not (member kind '("spawn" "retire"))) "bad-kind")
     ((not (decknix-agent-dispatch--uuid-p (plist-get req :id))) "bad-id")
     ((and from (not (decknix-agent-dispatch--uuid-p from))) "bad-from")
     ((and name (not (and (stringp name) (<= (length name) 80)))) "bad-from-name")
     ((and reason (not (and (stringp reason)
                            (<= (length reason) decknix-agent-dispatch-max-reason-chars))))
      "bad-reason")
     ((equal kind "spawn")
      (let ((ws (plist-get req :workspace)))
        (cond
         ((eq :bad (decknix-agent-dispatch--string-list (plist-get req :tags))) "bad-tags")
         ((not (and (stringp ws) (string-prefix-p "/" ws))) "bad-workspace")
         ((decknix-agent-dispatch--text-bad (plist-get req :brief)
                                            (plist-get req :brief_sha256)))
         ((and resume (not (decknix-agent-dispatch--uuid-p resume))) "bad-resume-id")
         ((decknix-agent-dispatch--short-strings-bad req '(:agent :name :model :mode))
          "bad-field"))))
     (t
      (cond
       ((not (decknix-agent-dispatch--uuid-p (plist-get req :session_id))) "bad-session-id")
       ((eq :bad (decknix-agent-dispatch--string-list (plist-get req :expect_tags) t))
        "bad-tags")
       ((decknix-agent-dispatch--short-strings-bad req '(:expect_buffer)) "bad-field"))))))

(defun decknix-agent-dispatch--validate (req now)
  "Return nil when REQ is deliverable at NOW, else a short reason string."
  (if (not (and (consp req) (plistp req)))
      "malformed"
    (let* ((version (plist-get req :v))
           (max-ttl (pcase version
                      (2 decknix-agent-dispatch-max-ttl-v2)
                      (3 decknix-agent-dispatch-max-ttl-v3)
                      (_ decknix-agent-dispatch-max-ttl))))
      (cond
       ((not (memql version '(1 2 3))) "bad-version")
       ((eql version 3)
        (or (decknix-agent-dispatch--v3-fields-bad req)
            (decknix-agent-dispatch--times-bad req max-ttl now)))
       ((and (eql version 2) (decknix-agent-dispatch--v2-fields-bad req)))
       ((not (decknix-agent-dispatch--uuid-p (plist-get req :id))) "bad-id")
       ((not (decknix-agent-dispatch--uuid-p (plist-get req :session_id)))
        "bad-session-id")
       ((decknix-agent-dispatch--text-bad (plist-get req :prompt)
                                          (plist-get req :prompt_sha256)))
       ((decknix-agent-dispatch--times-bad req max-ttl now))))))

(cl-defun decknix-agent-dispatch--decide (&key matches same proc unsent busy
                                                mode interrupted)
  "Return `submit', `wait', `interrupt' or (refuse . REASON).
MATCHES is how many live buffers hold the session, SAME whether that is
still the buffer claimed, PROC whether its process is live, UNSENT whether
the user has typed text not yet sent, BUSY whether a turn is running.
MODE is the request's delivery mode, nil for version 1, and INTERRUPTED
whether this request already cancelled the session's turn.

Version 1: unsent input outranks busy, since waiting on a session someone
is typing into only delays the same refusal.  `idle' waits on both, which
is the point of a durable queue: the user will send or clear the text.
`now' and `interrupt' refuse unsent input, because a human at the prompt
outranks a coordinator."
  (cond
   ((eql matches 0) '(refuse . "no-session"))
   ((> matches 1) '(refuse . "ambiguous-session"))
   ((not same) '(refuse . "session-changed"))
   ((not proc) '(refuse . "no-process"))
   ((and unsent (eq mode 'idle)) 'wait)
   (unsent '(refuse . "unsent-input"))
   ((and busy (eq mode 'now)) '(refuse . "busy"))
   ((and busy (eq mode 'interrupt) (not interrupted)) 'interrupt)
   (busy 'wait)
   (t 'submit)))

(defun decknix-agent-dispatch--short (id)
  (if (and (stringp id) (>= (length id) 8)) (substring id 0 8) (or id "?")))

(defun decknix-agent-dispatch--sender (req)
  "How REQ's sender is named in a transcript."
  (or (plist-get req :from_name)
      (and (plist-get req :from) (decknix-agent-dispatch--short (plist-get req :from)))
      "an outside process"))

(defun decknix-agent-dispatch--spawn-envelope (req)
  "The line a spawned session's brief starts with, naming REQ and its sender."
  (format "[decknix spawn %s from %s]"
          (decknix-agent-dispatch--short (plist-get req :id))
          (decknix-agent-dispatch--sender req)))

(defun decknix-agent-dispatch--envelope (req &optional interrupted)
  "Return the line naming REQ's sender, or nil for version 1.
It reaches the session's transcript, so the human reading it later sees
who sent the message and, after an interrupt, why their turn was cut."
  (when (eql (plist-get req :v) 2)
    (let ((sender (decknix-agent-dispatch--sender req)))
      (format "[decknix message %s from %s%s]"
              (decknix-agent-dispatch--short (plist-get req :id))
              sender
              (if interrupted
                  (format "; interrupted your turn: %s"
                          (string-trim (plist-get req :reason)))
                "")))))

(defun decknix-agent-dispatch--delivery-text (req &optional interrupted)
  "Return the input to submit for REQ."
  (let ((prompt (string-trim-right (plist-get req :prompt)))
        (envelope (decknix-agent-dispatch--envelope req interrupted)))
    (if envelope (concat envelope "\n" prompt) prompt)))

(defun decknix-agent-dispatch--interrupt-refusal (from to tags-of now)
  "Return why FROM may not interrupt TO at NOW, or nil when it may.
TAGS-OF maps a session id to its tags.  Pure apart from TAGS-OF."
  (let ((window decknix-agent-dispatch-interrupt-min-interval)
        (opted-in (lambda ()
                    (seq-intersection (funcall tags-of to)
                                      decknix-agent-dispatch-interruptible-tags))))
    (cond
     ((equal from to) "interrupt-self")
     ((seq-find (lambda (e) (and (equal (nth 1 e) to) (< (- now (nth 2 e)) window)))
                decknix-agent-dispatch--interrupts)
      "interrupt-rate-limited")
     ((and from
           (seq-find (lambda (e) (and (equal (nth 0 e) to) (equal (nth 1 e) from)
                                      (< (- now (nth 2 e)) window)))
                     decknix-agent-dispatch--interrupts))
      "interrupt-loop")
     ((pcase decknix-agent-dispatch-interrupt-policy
        ('always nil)
        ('opt-in (not (funcall opted-in)))
        ('coordinator
         (not (or (funcall opted-in)
                  (and from (seq-intersection
                             (funcall tags-of from)
                             decknix-agent-dispatch-coordinator-tags)))))
        (_ t))
      "interrupt-not-allowed"))))

(defun decknix-agent-dispatch--note-interrupt (from to now)
  (setq decknix-agent-dispatch--interrupts
        (cons (list from to now)
              (seq-filter (lambda (e) (< (- now (nth 2 e))
                                         (* 2 decknix-agent-dispatch-interrupt-min-interval)))
                          decknix-agent-dispatch--interrupts))))

;; -- lifecycle decisions (pure) --------------------------------------

(defun decknix-agent-dispatch--tags-cover-p (have want)
  "Non-nil when tag list HAVE holds every tag in WANT, ignoring case."
  (seq-every-p (lambda (w)
                 (seq-some (lambda (h) (and (stringp h)
                                            (eq t (compare-strings w nil nil h nil nil t))))
                           have))
               want))

(defun decknix-agent-dispatch--lifecycle-refusal (from tags-of)
  "Return why sender FROM may not spawn or retire, or nil.
TAGS-OF maps a session id to its tags."
  (pcase decknix-agent-dispatch-lifecycle-policy
    ('always nil)
    ('coordinator
     (unless (and from (seq-intersection (funcall tags-of from)
                                         decknix-agent-dispatch-coordinator-tags))
       "lifecycle-not-allowed"))
    (_ "lifecycle-not-allowed")))

(defun decknix-agent-dispatch--spawn-limit-refusal (live last-at now)
  "Return why a spawn may not start with LIVE sessions, LAST-AT spawn, at NOW."
  (cond
   ((>= live decknix-agent-dispatch-spawn-max-live) "too-many-sessions")
   ((and last-at (< (- now last-at) decknix-agent-dispatch-spawn-min-interval))
    "spawn-rate-limited")))

(cl-defun decknix-agent-dispatch--retire-decide (&key matches changed protected
                                                       unsent busy force)
  "Return `retire', `wait' or (refuse . REASON) for a retire request.
MATCHES is how many live buffers hold the session; CHANGED whether its
tags, buffer name or buffer no longer match what the request expected;
PROTECTED whether it carries a protected tag; UNSENT whether the user has
typed text there; BUSY whether a turn is open; FORCE whether the request
asked not to wait.  Unsent text refuses even a forced retire: a human at
the prompt outranks a coordinator."
  (cond
   ((eql matches 0) '(refuse . "no-session"))
   ((> matches 1) '(refuse . "ambiguous-session"))
   (changed '(refuse . "session-changed"))
   (protected '(refuse . "protected-session"))
   (unsent '(refuse . "unsent-input"))
   ((and busy (not force)) 'wait)
   (t 'retire)))

;; -- state directory ----------------------------------------------

(defun decknix-agent-dispatch--sub (name)
  (expand-file-name name decknix-agent-dispatch-dir))

(defun decknix-agent-dispatch--ensure-dirs ()
  "Create any missing state directory with mode 0700.
Existing directories are left as they are so `--check-dirs' can refuse a
loose one instead of this function quietly repairing it."
  (dolist (d (cons "" decknix-agent-dispatch--subdirs))
    (let ((path (directory-file-name (expand-file-name d decknix-agent-dispatch-dir))))
      (unless (file-exists-p path)
        (make-directory path t)
        (set-file-modes path #o700)))))

(defun decknix-agent-dispatch--check-dirs ()
  "Signal a `user-error' unless every state directory is private and ours."
  (dolist (d (cons "" decknix-agent-dispatch--subdirs))
    (let* ((path (directory-file-name (expand-file-name d decknix-agent-dispatch-dir)))
           (attrs (file-attributes path)))
      (unless (and attrs
                   (not (file-symlink-p path))
                   (eq t (file-attribute-type attrs))
                   (= #o700 (logand (file-modes path) #o777))
                   (= (user-uid) (file-attribute-user-id attrs)))
        (user-error "Dispatch state dir %s must be a real directory, mode 0700, owned by you"
                    path)))))

(defun decknix-agent-dispatch--path (sub id &optional ext)
  (expand-file-name (concat id (or ext ".json")) (decknix-agent-dispatch--sub sub)))

(defun decknix-agent-dispatch--receipt-exists-p (id)
  (file-exists-p (decknix-agent-dispatch--path "receipts" id)))

(defun decknix-agent-dispatch--write-receipt (id session-id state reason &optional info)
  "Write the receipt for ID atomically; return nil if one already exists.
INFO is a plist of extra non-nil fields.  The prompt text is never recorded."
  (let* ((body (append (list :v 1 :id id)
                       (and session-id (list :session_id session-id))
                       (list :state state)
                       (and reason (list :reason reason))
                       (list :at (decknix-agent-dispatch--now))
                       info))
         (tmp (decknix-agent-dispatch--path
               "tmp" (format "receipt-%s-%06x" id (random #xffffff)) ".tmp"))
         (final (decknix-agent-dispatch--path "receipts" id)))
    (condition-case nil
        (progn
          (with-file-modes #o600
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region (json-serialize body) nil tmp nil 'silent)))
          (rename-file tmp final nil)
          t)
      (error (ignore-errors (delete-file tmp)) nil))))

(defun decknix-agent-dispatch--claim (id)
  "Atomically move ID from pending to inflight; non-nil if this call won."
  (condition-case nil
      (progn (rename-file (decknix-agent-dispatch--path "pending" id)
                          (decknix-agent-dispatch--path "inflight" id)
                          nil)
             t)
    (error nil)))

(defun decknix-agent-dispatch--cleanup (id)
  (dolist (p (list (decknix-agent-dispatch--path "inflight" id)
                   (decknix-agent-dispatch--path "inflight" id ".attempt")
                   (decknix-agent-dispatch--path "inflight" id ".interrupted")))
    (ignore-errors (delete-file p)))
  (remhash id decknix-agent-dispatch--active))

(defun decknix-agent-dispatch--write-json (sub name body)
  "Atomically write BODY as SUB/NAME (0600) unless it exists; non-nil on success."
  (let ((tmp (decknix-agent-dispatch--path
              "tmp" (format "%s-%06x" name (random #xffffff)) ".tmp"))
        (final (expand-file-name name (decknix-agent-dispatch--sub sub))))
    (condition-case nil
        (progn
          (make-directory (file-name-directory final) t)
          (set-file-modes (file-name-directory final) #o700)
          (with-file-modes #o600
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region (json-serialize body) nil tmp nil 'silent)))
          (rename-file tmp final nil)
          t)
      (error (ignore-errors (delete-file tmp)) nil))))

(defun decknix-agent-dispatch--notify (req state reason &optional extra)
  "Leave a notice for REQ's sender when it asked for one."
  (let ((from (plist-get req :from))
        (id (plist-get req :id)))
    (when (and (eql (plist-get req :v) 2) (eq t (plist-get req :notify))
               (decknix-agent-dispatch--uuid-p from)
               (decknix-agent-dispatch--uuid-p id))
      (decknix-agent-dispatch--write-json
       (concat "notices/" from)
       (format "%d-%s-%s.json" (decknix-agent-dispatch--now) id state)
       (append (list :v 1 :id id :to (plist-get req :session_id)
                     :state state :at (decknix-agent-dispatch--now))
               (and reason (list :reason reason))
               extra)))))

(defun decknix-agent-dispatch--finish (id session-id state reason &optional info)
  "Record the outcome, then drop the in-flight files (receipt first)."
  (decknix-agent-dispatch--write-receipt id session-id state reason info)
  (when-let ((req (plist-get (gethash id decknix-agent-dispatch--active) :req)))
    (decknix-agent-dispatch--notify req state reason))
  (decknix-agent-dispatch--cleanup id)
  state)

(defun decknix-agent-dispatch--safe-file-p (path)
  (let ((attrs (file-attributes path)))
    (and attrs
         (not (file-symlink-p path))
         (null (file-attribute-type attrs))
         (= #o600 (logand (file-modes path) #o777))
         (= (user-uid) (file-attribute-user-id attrs))
         (<= (file-attribute-size attrs)
             (+ 4096 (* 6 decknix-agent-dispatch-max-prompt-bytes))))))

(defun decknix-agent-dispatch--read-request (path)
  "Parse the request at PATH into a plist, or nil when unparseable."
  (condition-case nil
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8))
          (insert-file-contents path))
        (json-parse-string (buffer-string) :object-type 'plist
                           :null-object nil :false-object nil))
    (error nil)))

;; -- session observation ------------------------------------------

(defun decknix-agent-dispatch--matching-buffers (sid)
  (seq-filter
   (lambda (buf)
     (and (buffer-live-p buf)
          (equal sid (ignore-errors
                       (funcall decknix-agent-dispatch-session-id-function buf)))))
   (funcall decknix-agent-dispatch-buffers-function)))

(defun decknix-agent-dispatch--process-live-p (buf)
  (let ((proc (get-buffer-process buf)))
    (and proc (process-live-p proc))))

(defun decknix-agent-dispatch--unsent-input-p (buf)
  "Non-nil when BUF's prompt holds text the user typed but did not send.
Fails closed: an unreadable process mark counts as unsent input."
  (with-current-buffer buf
    (let* ((proc (get-buffer-process buf))
           (pm (and proc (process-mark proc))))
      (if (not (and pm (marker-position pm)))
          t
        (not (string-empty-p
              (string-trim (buffer-substring-no-properties
                            (min pm (point-max)) (point-max)))))))))

(defun decknix-agent-dispatch--busy-p (buf)
  (with-current-buffer buf (bound-and-true-p shell-maker--busy)))

;; -- delivery ------------------------------------------------------

(defun decknix-agent-dispatch--info (req &optional input buf)
  (append (list :prompt_sha256 (plist-get req :prompt_sha256))
          (and input (list :prompt_len (length input)))
          (and buf (list :buffer (buffer-name buf)))))

(defun decknix-agent-dispatch--accepted (id req buf input)
  "Record ID as delivered to BUF and start watching for its answer."
  (let ((sid (plist-get req :session_id))
        (now (decknix-agent-dispatch--now)))
    (puthash sid (list :id id :at now :from (plist-get req :from))
             decknix-agent-dispatch--last-delivered)
    (when (eql (plist-get req :v) 2)
      (puthash id (list :req req :buffer buf :at now)
               decknix-agent-dispatch--delivered))
    (decknix-agent-dispatch--finish
     id sid "accepted" nil (decknix-agent-dispatch--info req input buf))))

(defun decknix-agent-dispatch--attempt (id req buf input)
  "Submit INPUT to BUF, the one irreversible step; always ends with a receipt."
  (let ((sid (plist-get req :session_id)))
    (with-file-modes #o600
      (write-region "1" nil (decknix-agent-dispatch--path "inflight" id ".attempt")
                    nil 'silent))
    (condition-case err
        (let ((ok (funcall decknix-agent-dispatch-submit-function buf input)))
          (cond
           ((not ok)
            (decknix-agent-dispatch--finish
             id sid "rejected" "submit-refused" (decknix-agent-dispatch--info req)))
           ((decknix-agent-dispatch--busy-p buf)
            (decknix-agent-dispatch--accepted id req buf input))
           (t
            (decknix-agent-dispatch--finish
             id sid "unknown" "no-busy-evidence-after-submit"
             (decknix-agent-dispatch--info req input buf)))))
      (error
       (decknix-agent-dispatch--finish
        id sid "unknown"
        (truncate-string-to-width
         (concat "submit-error: " (error-message-string err)) 200)
        (decknix-agent-dispatch--info req input buf))))))

(defun decknix-agent-dispatch--step (id)
  "Advance claimed request ID one decision; never blocks."
  (when-let ((entry (gethash id decknix-agent-dispatch--active)))
    (if (equal "retire" (plist-get (plist-get entry :req) :kind))
        (decknix-agent-dispatch--step-retire id entry)
      (decknix-agent-dispatch--step-prompt id entry))))

(defun decknix-agent-dispatch--step-prompt (id entry)
  "Advance prompt request ID (ENTRY in the active table) one decision."
  (let* ((req (plist-get entry :req))
           (sid (plist-get req :session_id))
           (info (decknix-agent-dispatch--info req)))
      (if (>= (decknix-agent-dispatch--now) (plist-get req :expires_at))
          (decknix-agent-dispatch--finish id sid "expired" "expired-before-send" info)
        (let* ((matches (decknix-agent-dispatch--matching-buffers sid))
               (buf (and (= 1 (length matches)) (car matches)))
               (claimed (plist-get entry :buffer))
               (interrupted (plist-get entry :interrupted))
               (decision
                (decknix-agent-dispatch--decide
                 :matches (length matches)
                 :same (or (null claimed) (eq claimed buf))
                 :proc (and buf (decknix-agent-dispatch--process-live-p buf))
                 :unsent (and buf (decknix-agent-dispatch--unsent-input-p buf))
                 :busy (and buf (decknix-agent-dispatch--busy-p buf))
                 :mode (decknix-agent-dispatch--mode req)
                 :interrupted interrupted)))
          (when (and buf (not claimed))
            (puthash id (plist-put entry :buffer buf) decknix-agent-dispatch--active))
          (cond
           ((eq decision 'wait) nil)
           ((consp decision)
            (decknix-agent-dispatch--finish id sid "rejected" (cdr decision) info))
           ((eq decision 'interrupt)
            (decknix-agent-dispatch--interrupt id entry buf))
           ((not (functionp decknix-agent-dispatch-submit-function))
            (decknix-agent-dispatch--finish id sid "rejected" "submit-unavailable" info))
           ((input-pending-p) nil)
           (t (decknix-agent-dispatch--attempt
               id req buf (decknix-agent-dispatch--delivery-text req interrupted))))))))

(defun decknix-agent-dispatch--interrupt (id entry buf)
  "Cancel BUF's turn for claimed request ID, or refuse it under the policy.
The request stays claimed either way it goes forward: the next tick that
finds BUF idle delivers it, and if the cancel is never acknowledged it
waits like an idle request until its own expiry rather than being lost."
  (let* ((req (plist-get entry :req))
         (sid (plist-get req :session_id))
         (from (plist-get req :from))
         (now (decknix-agent-dispatch--now))
         (refusal (decknix-agent-dispatch--interrupt-refusal
                   from sid
                   (lambda (s) (and s (funcall decknix-agent-dispatch-tags-function s)))
                   now)))
    (if refusal
        (decknix-agent-dispatch--finish id sid "rejected" refusal
                                        (decknix-agent-dispatch--info req))
      (decknix-agent-dispatch--note-interrupt from sid now)
      (puthash id (plist-put entry :interrupted now) decknix-agent-dispatch--active)
      (with-file-modes #o600
        (write-region (number-to-string now) nil
                      (decknix-agent-dispatch--path "inflight" id ".interrupted")
                      nil 'silent))
      (message "decknix-agent-dispatch: %s interrupted by %s: %s"
               (buffer-name buf)
               (or (plist-get req :from_name)
                   (decknix-agent-dispatch--short from))
               (plist-get req :reason))
      (funcall decknix-agent-dispatch-interrupt-function buf))))

;; -- retire ---------------------------------------------------------

(defun decknix-agent-dispatch--live-tags (buf)
  (ignore-errors (funcall decknix-agent-dispatch-live-tags-function buf)))

(defun decknix-agent-dispatch--sender-tags (sid)
  (and sid (ignore-errors (funcall decknix-agent-dispatch-tags-function sid))))

(defun decknix-agent-dispatch--step-retire (id entry)
  "Advance retire request ID (ENTRY in the active table) one decision."
  (let* ((req (plist-get entry :req))
         (sid (plist-get req :session_id))
         (from (plist-get req :from))
         (force (eq t (plist-get req :force)))
         (info (list :kind "retire"))
         (refusal (or (decknix-agent-dispatch--lifecycle-refusal
                       from #'decknix-agent-dispatch--sender-tags)
                      (and (equal from sid) (not force) "retire-self-needs-force"))))
    (cond
     (refusal (decknix-agent-dispatch--finish id sid "rejected" refusal info))
     ((>= (decknix-agent-dispatch--now) (plist-get req :expires_at))
      (decknix-agent-dispatch--finish id sid "expired" "expired-before-retire" info))
     (t
      (let* ((matches (decknix-agent-dispatch--matching-buffers sid))
             (buf (and (= 1 (length matches)) (car matches)))
             (claimed (plist-get entry :buffer))
             (tags (and buf (decknix-agent-dispatch--live-tags buf)))
             (want-buffer (plist-get req :expect_buffer))
             (decision
              (decknix-agent-dispatch--retire-decide
               :matches (length matches)
               :changed (and buf
                             (or (and claimed (not (eq claimed buf)))
                                 (not (decknix-agent-dispatch--tags-cover-p
                                       tags (append (plist-get req :expect_tags) nil)))
                                 (and want-buffer (not (equal want-buffer (buffer-name buf))))))
               :protected (and buf
                               (seq-some (lambda (p) (decknix-agent-dispatch--tags-cover-p
                                                      tags (list p)))
                                         decknix-agent-dispatch-retire-protected-tags))
               :unsent (and buf (decknix-agent-dispatch--unsent-input-p buf))
               :busy (and buf (decknix-agent-dispatch--busy-p buf))
               :force force)))
        (when (and buf (not claimed))
          (puthash id (plist-put entry :buffer buf) decknix-agent-dispatch--active))
        (pcase decision
          ('wait nil)
          (`(refuse . ,reason)
           (decknix-agent-dispatch--finish id sid "rejected" reason info))
          (_ (unless (input-pending-p)
               (decknix-agent-dispatch--retire id sid buf info)))))))))

(defun decknix-agent-dispatch--retire (id sid buf info)
  "Quit BUF for retire request ID and record whether it is really gone."
  (let ((name (buffer-name buf)))
    (with-file-modes #o600
      (write-region "1" nil (decknix-agent-dispatch--path "inflight" id ".attempt")
                    nil 'silent))
    (condition-case err
        (progn
          (funcall decknix-agent-dispatch-retire-function buf)
          (if (buffer-live-p buf)
              (decknix-agent-dispatch--finish id sid "unknown" "buffer-still-live"
                                              (append info (list :buffer name)))
            (decknix-agent-dispatch--finish
             id sid "accepted" nil (append info (list :outcome "retired" :buffer name)))))
      (error
       (decknix-agent-dispatch--finish
        id sid "unknown"
        (truncate-string-to-width (concat "retire-error: " (error-message-string err)) 200)
        (append info (list :buffer name)))))))

;; -- spawn ----------------------------------------------------------

(defun decknix-agent-dispatch--agent-provider (agent)
  "Provider id spawn AGENT names, nil when it names none, else `:unknown'."
  (cond
   ((null agent) nil)
   ((cdr (assoc agent decknix-agent-dispatch-agent-providers)))
   (t :unknown)))

(defun decknix-agent-dispatch--agent-refusal (agent)
  "Return `unknown-agent' unless AGENT maps to a registered provider (or is nil)."
  (let ((provider (decknix-agent-dispatch--agent-provider agent)))
    (when (or (eq provider :unknown)
              (and provider (fboundp 'decknix-agent-get-provider)
                   (not (decknix-agent-get-provider provider))))
      "unknown-agent")))

(defun decknix-agent-dispatch--enqueue (thunk)
  "Run THUNK through the spawn throttle when it is loaded, else now."
  (if (fboundp 'decknix-agent-spawn-enqueue)
      (decknix-agent-spawn-enqueue thunk)
    (funcall thunk)))

(defun decknix-agent-dispatch--start-session (spec callback)
  "Default spawn: a background quick-action session for SPEC, throttled.
The brief is the session's first message, which also keys its tags."
  (decknix-agent-dispatch--enqueue
   (lambda ()
     (condition-case err
         (let ((before (buffer-list))
               (provider (decknix-agent-dispatch--agent-provider (plist-get spec :agent))))
           (when (decknix-agent-dispatch--agent-refusal (plist-get spec :agent))
             (error "unknown agent %s" (plist-get spec :agent)))
           (decknix--agent-quickaction-start
            (plist-get spec :name) (plist-get spec :tags) (plist-get spec :workspace)
            (plist-get spec :brief) (plist-get spec :model) provider
            (plist-get spec :mode) t)
           (funcall callback (decknix--agent-find-new-shell-buffer before) nil))
       (error (funcall callback nil (error-message-string err)))))))

(defun decknix-agent-dispatch--resume-session (spec callback)
  "Default resume: reopen SPEC's :session_id in the background, throttled."
  (decknix-agent-dispatch--enqueue
   (lambda ()
     (condition-case err
         (let* ((sid (plist-get spec :session_id))
                (conv-key (and (fboundp 'decknix--agent-conv-key-for-session-id)
                               (ignore-errors (decknix--agent-conv-key-for-session-id sid))))
                (buf (decknix--agent-session-resume
                      sid (if (boundp 'decknix-agent-session-history-count)
                              decknix-agent-session-history-count
                            0)
                      (plist-get spec :name) (plist-get spec :workspace)
                      conv-key nil t)))
           (funcall callback (and (bufferp buf) buf) nil))
       (error (funcall callback nil (error-message-string err)))))))

(defun decknix-agent-dispatch--workspace-refusal (ws)
  (cond
   ((not (seq-some (lambda (root) (file-in-directory-p ws (expand-file-name root)))
                   decknix-agent-dispatch-spawn-roots))
    "workspace-not-allowed")
   ((not (file-directory-p ws)) "no-workspace")))

(defun decknix-agent-dispatch--live-buffers ()
  (seq-filter #'buffer-live-p (funcall decknix-agent-dispatch-buffers-function)))

(defun decknix-agent-dispatch--write-spawned (id body)
  "Write ID's spawned receipt with BODY and stop tracking it."
  (remhash id decknix-agent-dispatch--spawning)
  (decknix-agent-dispatch--write-json
   "receipts" (concat id ".spawned.json")
   (append (list :v 1 :id id :at (decknix-agent-dispatch--now)) body)))

(defun decknix-agent-dispatch--spawn-failed (id reason)
  (decknix-agent-dispatch--write-spawned
   id (list :state "spawn-failed"
            :reason (truncate-string-to-width (or reason "no-buffer") 200))))

(defun decknix-agent-dispatch--spawn-started (id buf err)
  "Callback of a spawn or resume seam for request ID."
  (when (gethash id decknix-agent-dispatch--spawning)
    (if (and (bufferp buf) (buffer-live-p buf) (not err))
        (progn
          (cl-pushnew buf decknix-agent-dispatch--lane-buffers)
          (puthash id (plist-put (gethash id decknix-agent-dispatch--spawning) :buffer buf)
                   decknix-agent-dispatch--spawning))
      (decknix-agent-dispatch--spawn-failed id (or err "no-buffer")))))

(defun decknix-agent-dispatch--spawn-in-progress-p (tags)
  "Non-nil when an accepted spawn not yet confirmed asked for TAGS or more."
  (let (hit)
    (maphash (lambda (_ e)
               (when (decknix-agent-dispatch--tags-cover-p (plist-get e :tags) tags)
                 (setq hit t)))
             decknix-agent-dispatch--spawning)
    hit))

(defun decknix-agent-dispatch--spawn (id req)
  "Handle validated spawn request ID: report a lane, start one, or refuse."
  (let* ((now (decknix-agent-dispatch--now))
         (tags (append (plist-get req :tags) nil))
         (ws (directory-file-name (expand-file-name (plist-get req :workspace))))
         (resume (plist-get req :resume_session_id))
         (info (list :kind "spawn"))
         (refusal (or (decknix-agent-dispatch--lifecycle-refusal
                       (plist-get req :from) #'decknix-agent-dispatch--sender-tags)
                      (decknix-agent-dispatch--agent-refusal (plist-get req :agent))
                      (decknix-agent-dispatch--workspace-refusal ws)))
         (live (and (not refusal) (decknix-agent-dispatch--live-buffers)))
         (existing (and (not refusal)
                        (or (and resume (decknix-agent-dispatch--matching-buffers resume))
                            (seq-filter (lambda (b) (decknix-agent-dispatch--tags-cover-p
                                                     (decknix-agent-dispatch--live-tags b)
                                                     tags))
                                        live)))))
    (cond
     (refusal (decknix-agent-dispatch--finish id nil "rejected" refusal info))
     ((cdr existing) (decknix-agent-dispatch--finish id nil "rejected" "ambiguous-existing" info))
     (existing (decknix-agent-dispatch--spawn-existing id req (car existing) info))
     ((decknix-agent-dispatch--spawn-in-progress-p tags)
      (decknix-agent-dispatch--finish id nil "rejected" "spawn-in-progress" info))
     (t
      (if-let ((limit (decknix-agent-dispatch--spawn-limit-refusal
                       (decknix-agent-dispatch-counted-lanes live)
                       decknix-agent-dispatch--last-spawn-at now)))
          (decknix-agent-dispatch--finish id nil "rejected" limit info)
        (decknix-agent-dispatch--launch id req tags ws resume now info))))))

(defun decknix-agent-dispatch--unstarted-count ()
  "Accepted spawns whose buffer does not exist yet, so the cap counts them."
  (let ((n 0))
    (maphash (lambda (_ e) (unless (plist-get e :buffer) (setq n (1+ n))))
             decknix-agent-dispatch--spawning)
    n))

(defun decknix-agent-dispatch--counted-lane-p (buf)
  (or (memq buf decknix-agent-dispatch--lane-buffers)
      (and decknix-agent-dispatch-spawn-counted-tag-regexp
           (let ((case-fold-search t))
             (seq-some (lambda (tag)
                         (and (stringp tag)
                              (string-match-p decknix-agent-dispatch-spawn-counted-tag-regexp tag)))
                       (decknix-agent-dispatch--live-tags buf))))))

(defun decknix-agent-dispatch-counted-lanes (&optional live)
  "Sessions the spawn cap counts: lanes among LIVE buffers, plus unstarted spawns.
A lane is a session this receiver spawned or one carrying a tag matching
`decknix-agent-dispatch-spawn-counted-tag-regexp'.  LIVE defaults to every
live agent-shell buffer."
  (setq decknix-agent-dispatch--lane-buffers
        (seq-filter #'buffer-live-p decknix-agent-dispatch--lane-buffers))
  (+ (seq-count #'decknix-agent-dispatch--counted-lane-p
                (or live (decknix-agent-dispatch--live-buffers)))
     (decknix-agent-dispatch--unstarted-count)))

(defun decknix-agent-dispatch--spawn-existing (id req buf info)
  "Report BUF as the lane spawn request ID asked for; start nothing."
  (let ((sid (ignore-errors (funcall decknix-agent-dispatch-session-id-function buf))))
    (decknix-agent-dispatch--finish
     id sid "accepted" nil (append info (list :outcome "existing" :buffer (buffer-name buf))))
    (if (and (stringp sid) (not (string-empty-p sid)))
        (decknix-agent-dispatch--write-spawned
         id (list :session_id sid :buffer (buffer-name buf) :outcome "existing"))
      (puthash id (list :req req :outcome "existing" :buffer buf
                        :at (decknix-agent-dispatch--now))
               decknix-agent-dispatch--spawning))))

(defun decknix-agent-dispatch--launch (id req tags ws resume now info)
  "Start (or resume) the session spawn request ID asked for."
  (let* ((outcome (if resume "resumed" "new"))
         (text (concat (decknix-agent-dispatch--spawn-envelope req) "\n"
                       (string-trim-right (plist-get req :brief))))
         (spec (list :name (or (plist-get req :name) (string-join tags "/"))
                     :tags tags :workspace ws :brief text
                     :agent (plist-get req :agent) :model (plist-get req :model)
                     :mode (plist-get req :mode) :session_id resume)))
    (setq decknix-agent-dispatch--last-spawn-at now)
    (puthash id (list :req req :outcome outcome :tags tags :brief text :at now)
             decknix-agent-dispatch--spawning)
    (decknix-agent-dispatch--finish id nil "accepted" nil
                                    (append info (list :outcome outcome)))
    (condition-case err
        (funcall (if resume decknix-agent-dispatch-resume-function
                   decknix-agent-dispatch-spawn-function)
                 spec
                 (lambda (buf reason) (decknix-agent-dispatch--spawn-started id buf reason)))
      (error (decknix-agent-dispatch--spawn-failed id (error-message-string err))))))

(defun decknix-agent-dispatch--deliver-brief (id entry buf now)
  "Submit a resumed session's brief once BUF has been idle long enough."
  (if (or (not (decknix-agent-dispatch--process-live-p buf))
          (decknix-agent-dispatch--busy-p buf)
          (decknix-agent-dispatch--unsent-input-p buf))
      (puthash id (plist-put entry :idle-since nil) decknix-agent-dispatch--spawning)
    (let ((since (or (plist-get entry :idle-since)
                     (progn (puthash id (plist-put entry :idle-since now)
                                     decknix-agent-dispatch--spawning)
                            now))))
      (when (and (>= (- now since) decknix-agent-dispatch-spawn-settle-seconds)
                 (not (input-pending-p)))
        (let ((ok (ignore-errors
                    (funcall decknix-agent-dispatch-submit-function buf
                             (plist-get entry :brief)))))
          (decknix-agent-dispatch--write-spawned
           id (list :session_id (funcall decknix-agent-dispatch-session-id-function buf)
                    :buffer (buffer-name buf) :outcome "resumed"
                    :brief (if ok "delivered" "not-delivered"))))))))

(defun decknix-agent-dispatch--check-spawn (id)
  "Advance tracked spawn ID: confirm its session id, or give up on it."
  (when-let ((entry (gethash id decknix-agent-dispatch--spawning)))
    (let* ((now (decknix-agent-dispatch--now))
           (buf (plist-get entry :buffer))
           (late (> (- now (plist-get entry :at)) decknix-agent-dispatch-spawn-timeout))
           (sid (and (buffer-live-p buf)
                     (ignore-errors (funcall decknix-agent-dispatch-session-id-function buf))))
           (sid (and (stringp sid) (not (string-empty-p sid)) sid)))
      (cond
       ((and buf (not (buffer-live-p buf)))
        (decknix-agent-dispatch--spawn-failed id "buffer-died"))
       ((and (not sid) late) (decknix-agent-dispatch--spawn-failed id "timeout"))
       ((not sid) nil)
       ((not (equal "resumed" (plist-get entry :outcome)))
        (decknix-agent-dispatch--write-spawned
         id (list :session_id sid :buffer (buffer-name buf)
                  :outcome (plist-get entry :outcome))))
       ((> (- now (or (plist-get entry :sid-at)
                      (progn (puthash id (plist-put entry :sid-at now)
                                      decknix-agent-dispatch--spawning)
                             now)))
           decknix-agent-dispatch-spawn-timeout)
        (decknix-agent-dispatch--write-spawned
         id (list :session_id sid :buffer (buffer-name buf) :outcome "resumed"
                  :brief "not-delivered")))
       (t (decknix-agent-dispatch--deliver-brief id entry buf now))))))

(defun decknix-agent-dispatch--answer-tail (buf)
  (let ((text (ignore-errors (funcall decknix-agent-dispatch-closing-text-function buf))))
    (when (and (stringp text) (not (string-empty-p (string-trim text))))
      (let ((text (string-trim text)))
        (substring text (max 0 (- (length text) decknix-agent-dispatch-answer-chars)))))))

(defun decknix-agent-dispatch--check-answered (id)
  "Write ID's `answered' receipt once its session's turn has ended."
  (when-let ((entry (gethash id decknix-agent-dispatch--delivered)))
    (let* ((req (plist-get entry :req))
           (buf (plist-get entry :buffer))
           (live (buffer-live-p buf))
           (busy (and live (decknix-agent-dispatch--busy-p buf)))
           (quiet (and busy (ignore-errors
                              (funcall decknix-agent-dispatch-settled-function buf)))))
      (when (or (not live) (not busy) quiet)
        (remhash id decknix-agent-dispatch--delivered)
        (let* ((tail (and live (decknix-agent-dispatch--answer-tail buf)))
               (state (if live "answered" "session-gone"))
               (extra (append (and tail (list :tail tail))
                              (and quiet (list :turn_open t)))))
          (decknix-agent-dispatch--write-json
           "receipts" (concat id ".answered.json")
           (append (list :v 1 :id id :session_id (plist-get req :session_id)
                         :state state :at (decknix-agent-dispatch--now))
                   extra))
          (decknix-agent-dispatch--notify req state nil extra))))))

(defun decknix-agent-dispatch-waiting-count (sid)
  "How many claimed requests are waiting to reach session SID.  No I/O."
  (let ((n 0))
    (maphash (lambda (_ e) (when (equal sid (plist-get (plist-get e :req) :session_id))
                             (setq n (1+ n))))
             decknix-agent-dispatch--active)
    n))

(defun decknix-agent-dispatch-last-delivered (sid)
  "Plist (:id :at :from) of the last request delivered to SID, or nil."
  (gethash sid decknix-agent-dispatch--last-delivered))

(defun decknix-agent-dispatch--process-pending (id)
  "Claim and validate pending request ID, then take its first step."
  (when (decknix-agent-dispatch--claim id)
    (let* ((path (decknix-agent-dispatch--path "inflight" id))
           (now (decknix-agent-dispatch--now)))
      (cond
       ((decknix-agent-dispatch--receipt-exists-p id)
        (decknix-agent-dispatch--cleanup id))
       ((not (decknix-agent-dispatch--safe-file-p path))
        (decknix-agent-dispatch--finish id nil "rejected" "unsafe-file"))
       (t
        (let* ((req (decknix-agent-dispatch--read-request path))
               (sid (and (consp req) (plist-get req :session_id)))
               (sid (and (decknix-agent-dispatch--uuid-p sid) sid))
               (bad (or (decknix-agent-dispatch--validate req now)
                        (and (not (equal id (plist-get req :id))) "bad-id")
                        (and decknix-agent-dispatch--armed-at
                             (< (plist-get req :created_at)
                                decknix-agent-dispatch--armed-at)
                             (not (decknix-agent-dispatch--released-p req))
                             "predates-arming"))))
          (when (and bad (consp req) (plistp req))
            (puthash id (list :req req) decknix-agent-dispatch--active))
          (cond
           ((equal bad "expired")
            (decknix-agent-dispatch--finish id sid "expired" "expired-before-claim"
                                            (decknix-agent-dispatch--info req)))
           (bad
            (decknix-agent-dispatch--finish id sid "rejected" bad))
           (t
            (puthash id (list :req req) decknix-agent-dispatch--active)
            (if (equal "spawn" (plist-get req :kind))
                (decknix-agent-dispatch--spawn id req)
              (decknix-agent-dispatch--step id))))))))))

(defun decknix-agent-dispatch--released-p (req)
  "Non-nil when REQ is a queued spawn the arming control request released."
  (and decknix-agent-dispatch--release-queued
       (eql 3 (plist-get req :v))
       (equal "spawn" (plist-get req :kind))
       (eq t (plist-get req :queue))))

(defun decknix-agent-dispatch--pending-ids ()
  (mapcar (lambda (f) (string-remove-suffix ".json" f))
          (directory-files (decknix-agent-dispatch--sub "pending") nil
                           (concat "\\`" decknix-agent-dispatch--uuid-regexp "\\.json\\'"))))

(defun decknix-agent-dispatch--guard (id thunk)
  "Run THUNK for request ID; an unexpected error settles ID fail-closed.
Before the attempt marker the request was certainly not sent; after it the
outcome is uncertain.  Either way it leaves the in-flight set, so a bug
cannot make the same request retry on every tick."
  (condition-case err
      (funcall thunk)
    (error
     (let* ((req (plist-get (gethash id decknix-agent-dispatch--active) :req))
            (sid (plist-get req :session_id))
            (msg (truncate-string-to-width
                  (concat "internal-error: " (error-message-string err)) 200)))
       (message "decknix-agent-dispatch: %s: %s" id msg)
       (if (file-exists-p (decknix-agent-dispatch--path "inflight" id ".attempt"))
           (decknix-agent-dispatch--finish id sid "unknown" msg)
         (decknix-agent-dispatch--finish id sid "not-sent" msg))))))

(defun decknix-agent-dispatch--pending-mtime ()
  "Modification time of the pending/ directory, or nil when unreadable."
  (when-let ((attrs (file-attributes (decknix-agent-dispatch--sub "pending"))))
    (file-attribute-modification-time attrs)))

(defun decknix-agent-dispatch--pending-unchanged-p (mtime now)
  "Non-nil when pending/ at MTIME holds nothing a listing at NOW would add.
True only if the last complete listing saw this same MTIME and was taken
less than `decknix-agent-dispatch-rescan-interval' seconds before NOW."
  (and mtime decknix-agent-dispatch--pending-seen
       (equal mtime (car decknix-agent-dispatch--pending-seen))
       (< (- now (cdr decknix-agent-dispatch--pending-seen))
          decknix-agent-dispatch-rescan-interval)))

(defun decknix-agent-dispatch--tick ()
  "Scan for new requests and advance waiting ones.  Cheap; never blocks.
The 2 s poll lists pending/ only when the directory's mtime moved since a
listing that read everything in it.  Listing it every tick was one
directory read every two seconds forever, and on a busy disk that read is
what froze typing (102 hitches, worst 19 s) while nothing was pending."
  (when decknix-agent-dispatch--armed-at
    (condition-case err
        (let ((waiting (hash-table-keys decknix-agent-dispatch--active))
              (mtime (decknix-agent-dispatch--pending-mtime))
              (now (float-time)))
          (unless (decknix-agent-dispatch--pending-unchanged-p mtime now)
            (let ((ids (decknix-agent-dispatch--pending-ids)))
              (setq decknix-agent-dispatch--pending-seen
                    (and mtime (<= (length ids) 8) (cons mtime now)))
              (dolist (id (seq-take ids 8))
                (decknix-agent-dispatch--guard
                 id (lambda () (decknix-agent-dispatch--process-pending id))))))
          (dolist (id waiting)
            (decknix-agent-dispatch--guard
             id (lambda () (decknix-agent-dispatch--step id))))
          (dolist (id (hash-table-keys decknix-agent-dispatch--spawning))
            (condition-case err
                (decknix-agent-dispatch--check-spawn id)
              (error (decknix-agent-dispatch--write-spawned
                      id (list :state "unknown"
                               :reason (truncate-string-to-width
                                        (concat "internal-error: " (error-message-string err))
                                        200))))))
          (dolist (id (hash-table-keys decknix-agent-dispatch--delivered))
            (condition-case err
                (decknix-agent-dispatch--check-answered id)
              (error (remhash id decknix-agent-dispatch--delivered)
                     (message "decknix-agent-dispatch: %s: answer check failed: %s"
                              id (error-message-string err))))))
      (error (message "decknix-agent-dispatch: tick failed: %s"
                      (error-message-string err))))))

(defun decknix-agent-dispatch--recover ()
  "Settle requests a previous receiver left in flight; never retries."
  (let ((ids (delete-dups
              (mapcar (lambda (f) (substring f 0 36))
                      (directory-files
                       (decknix-agent-dispatch--sub "inflight") nil
                       (concat "\\`" decknix-agent-dispatch--uuid-regexp
                               "\\.\\(json\\|attempt\\|interrupted\\)\\'"))))))
    (dolist (id ids)
      (unless (decknix-agent-dispatch--receipt-exists-p id)
        (let* ((req (decknix-agent-dispatch--read-request
                     (decknix-agent-dispatch--path "inflight" id)))
               (sid (and (consp req) (plist-get req :session_id)))
               (sid (and (decknix-agent-dispatch--uuid-p sid) sid)))
          (if (file-exists-p (decknix-agent-dispatch--path "inflight" id ".attempt"))
              (decknix-agent-dispatch--write-receipt
               id sid "unknown" "receiver-restarted-after-attempt")
            (decknix-agent-dispatch--write-receipt
             id sid "not-sent" "receiver-restarted"))))
      (decknix-agent-dispatch--cleanup id))))

(defun decknix-agent-dispatch--disarm-requests ()
  "Settle every waiting request as not sent."
  (dolist (id (hash-table-keys decknix-agent-dispatch--active))
    (let ((req (plist-get (gethash id decknix-agent-dispatch--active) :req)))
      (decknix-agent-dispatch--finish id (plist-get req :session_id)
                                      "not-sent" "disarmed"
                                      (decknix-agent-dispatch--info req)))))

;; -- lifecycle -----------------------------------------------------

(defun decknix-agent-dispatch--kick-scan (&rest _)
  "File-notify callback: schedule one scan soon, collapsing bursts."
  (unless decknix-agent-dispatch--kick
    (setq decknix-agent-dispatch--kick
          (run-at-time 0.2 nil
                       (lambda ()
                         (setq decknix-agent-dispatch--kick nil
                               decknix-agent-dispatch--pending-seen nil)
                         (decknix-agent-dispatch--tick))))))

(defun decknix-agent-dispatch--start ()
  (decknix-agent-dispatch--ensure-dirs)
  (decknix-agent-dispatch--check-dirs)
  (setq decknix-agent-dispatch--armed-at (decknix-agent-dispatch--now)
        decknix-agent-dispatch--armed-by (or decknix-agent-dispatch-arming-source "human")
        decknix-agent-dispatch--release-queued decknix-agent-dispatch-arming-release-queued
        decknix-agent-dispatch--pending-seen nil)
  (decknix-agent-dispatch--recover)
  (setq decknix-agent-dispatch--timer
        (run-with-timer decknix-agent-dispatch-poll-interval
                        decknix-agent-dispatch-poll-interval
                        #'decknix-agent-dispatch--tick))
  (setq decknix-agent-dispatch--watch
        (ignore-errors
          (file-notify-add-watch (decknix-agent-dispatch--sub "pending")
                                 '(change) #'decknix-agent-dispatch--kick-scan))))

(defun decknix-agent-dispatch--stop ()
  (when decknix-agent-dispatch--timer (cancel-timer decknix-agent-dispatch--timer))
  (when decknix-agent-dispatch--kick (cancel-timer decknix-agent-dispatch--kick))
  (when decknix-agent-dispatch--watch
    (ignore-errors (file-notify-rm-watch decknix-agent-dispatch--watch)))
  (setq decknix-agent-dispatch--timer nil
        decknix-agent-dispatch--kick nil
        decknix-agent-dispatch--watch nil)
  (decknix-agent-dispatch--disarm-requests)
  (dolist (id (hash-table-keys decknix-agent-dispatch--spawning))
    (decknix-agent-dispatch--write-spawned
     id (list :state "unknown" :reason "disarmed-before-confirmation")))
  (setq decknix-agent-dispatch--armed-at nil
        decknix-agent-dispatch--armed-by nil
        decknix-agent-dispatch--release-queued nil))

(defun decknix-agent-dispatch-state ()
  "Plist describing the receiver for the heartbeat; no I/O.
Keys: :on, :armed_at, :armed_by and :release_queued."
  (list :on (and (bound-and-true-p decknix-agent-dispatch-mode) t)
        :armed_at decknix-agent-dispatch--armed-at
        :armed_by decknix-agent-dispatch--armed-by
        :release_queued decknix-agent-dispatch--release-queued))

;;;###autoload
(define-minor-mode decknix-agent-dispatch-mode
  "Deliver explicitly requested prompts to live agent-shell sessions.

Off by default and never enabled automatically.  While on, a request file
dropped by the `decknix-agent-dispatch' CLI is delivered at most once to the
single session whose full id it names.  Turning the mode off settles every
waiting request as not sent.  Requests created before the mode was turned on
are refused, so enabling it cannot release old requests."
  :global t
  :lighter nil
  :group 'decknix-agent-dispatch
  (if decknix-agent-dispatch-mode
      (condition-case err
          (decknix-agent-dispatch--start)
        (error (setq decknix-agent-dispatch-mode nil)
               (decknix-agent-dispatch--stop)
               (signal (car err) (cdr err))))
    (decknix-agent-dispatch--stop)))

(provide 'decknix-agent-dispatch)
;;; decknix-agent-dispatch.el ends here
