;;; decknix-agent-broker-rehydrate.el --- Replay a brokered session's in-flight turn on reattach -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, acp, broker

;;; Commentary:
;;
;; #151 M6 — "Reattach replay (rehydrate)".  The broker keeps a session's
;; bridge (and its turn) running while Emacs is detached, but it is a
;; deliberately no-replay relay: a reattaching client gets the LIVE stream
;; only, so the output that arrived while detached never reaches the fresh
;; buffer.  On resume the user sees the prompt, then silence, then the
;; resolved result — never the in-flight progress.
;;
;; This module closes that gap on the READ side.  The broker's raw ACP log
;; (`~/.local/state/decknix/agent-sockets/<key>.log') is a complete record of
;; every bridge->client byte since the broker spawned.  On reattach we parse
;; the log's IN-FLIGHT TAIL — the agent-side `session/update' notifications
;; after the last committed turn boundary (a result carrying `stopReason')
;; and before the last `# client attached' marker (the current live attach) —
;; and replay them through the SAME renderer the live path uses
;; (`agent-shell--on-notification'), so the buffer fills in "as if attached
;; all along".  Everything after the last attach marker is delivered live by
;; the broker, so the marker is the exact seam: no overlap to de-duplicate.
;;
;; This file owns the pure parser (`…-inflight-notifications', ERT-tested off
;; fixtures) and the buffer replay (`…-rehydrate-buffer').  Wiring the replay
;; into the resume lifecycle (after `decknix--agent-session-prepopulate', so
;; the in-flight tail lands below the restored history) stays in main-bulk /
;; the heredoc per AGENTS.md Rule 2.

;;; Code:

(require 'subr-x)
(require 'json)

(declare-function agent-shell--on-notification "agent-shell" (&rest args))
(declare-function agent-shell--state "agent-shell" ())
(defvar decknix--agent-broker-key)

(defcustom decknix-agent-broker-rehydrate-enable t
  "When non-nil, replay a brokered session's in-flight turn on reattach.
Gated on brokering being on anyway (the buffer must carry a
`decknix--agent-broker-key').  Set nil to fall back to the raw broker
behaviour (prompt restored, in-flight output not shown until the turn
resolves)."
  :type 'boolean
  :group 'decknix)

(defconst decknix--agent-broker-replay-kinds
  '("agent_message_chunk" "agent_thought_chunk" "tool_call"
    "tool_call_update" "plan")
  "`sessionUpdate' kinds carrying agent-side visible content to replay.
Excludes `user_message_chunk' (the prompt is restored by prepopulation)
and every session-meta kind (usage/mode/commands/info updates).")

;; ── pure log parsing ────────────────────────────────────────────────

(defun decknix--agent-broker-parse-json-line (line)
  "Parse LINE as one ACP JSON object using acp.el's config, or nil.
Returns a symbol-keyed alist (matching what `agent-shell--on-notification'
consumes); broker marker lines (`# …'), blank lines and malformed JSON
return nil."
  (when (and line (stringp line))
    (let ((s (string-trim line)))
      (when (and (> (length s) 0) (eq (aref s 0) ?{))
        (ignore-errors
          (json-parse-string s :object-type 'alist
                             :null-object nil :false-object nil))))))

(defun decknix--agent-broker-result-stop-reason-p (obj)
  "Non-nil when parsed OBJ is a JSON-RPC result carrying a `stopReason'.
That is a committed turn boundary — the point up to which the resumed
buffer's transcript prepopulation already covers the conversation."
  (and (listp obj)
       (let ((res (alist-get 'result obj)))
         (and (listp res) (alist-get 'stopReason res)))))

(defun decknix--agent-broker-visible-notification (obj)
  "Return OBJ when it is a replayable agent-side `session/update', else nil.
Replayable == method `session/update' whose `sessionUpdate' kind is in
`decknix--agent-broker-replay-kinds'."
  (when (and (listp obj)
             (equal (alist-get 'method obj) "session/update"))
    (let* ((params (alist-get 'params obj))
           (update (and (listp params) (alist-get 'update params)))
           (kind   (and (listp update) (alist-get 'sessionUpdate update))))
      (when (member kind decknix--agent-broker-replay-kinds)
        obj))))

(defun decknix--agent-broker-inflight-notifications (lines)
  "Return the in-flight-turn notifications to replay, parsed from LINES.
LINES is the broker log split into raw lines, in file order.  Returns the
agent-side `session/update' notifications that arrived after the last
committed turn boundary (a result with `stopReason') and before the last
`# client attached' marker (the current live attach), in order.

Returns nil when there is nothing to replay: no current attach marker, or
the last turn already committed (its output is covered by transcript
prepopulation, and everything since the attach is delivered live)."
  (let* ((vec (vconcat lines))
         (n (length vec))
         (attach-idx nil)
         (boundary-idx -1))
    ;; last `# client attached' == the current live attach
    (let ((i (1- n)))
      (while (and (>= i 0) (null attach-idx))
        (when (equal (string-trim (aref vec i)) "# client attached")
          (setq attach-idx i))
        (setq i (1- i))))
    (when attach-idx
      ;; last committed turn boundary strictly before that attach
      (let ((i (1- attach-idx)))
        (while (and (>= i 0) (= boundary-idx -1))
          (when (decknix--agent-broker-result-stop-reason-p
                 (decknix--agent-broker-parse-json-line (aref vec i)))
            (setq boundary-idx i))
          (setq i (1- i))))
      ;; visible agent notifications in (boundary-idx, attach-idx)
      (let ((out nil) (i (1+ boundary-idx)))
        (while (< i attach-idx)
          (when-let* ((obj (decknix--agent-broker-visible-notification
                            (decknix--agent-broker-parse-json-line
                             (aref vec i)))))
            (push obj out))
          (setq i (1+ i)))
        (nreverse out)))))

(defcustom decknix-agent-broker-replay-turns 2
  "How many committed turns to replay backwards from the live attach.

A \"page\" of restored history.  Counted in TURNS rather than lines so the
window always snaps to a turn boundary: a turn carries its own tool calls,
so slicing there keeps a `tool_call_update' with the `tool_call' it
updates.  Measured on a live log, 9 of 10764 updates still reference an
earlier turn, which the per-notification `ignore-errors' in the replay
absorbs.

Replaying from the START is not an option: the longest live broker log
measured 95872 lines.  Older turns load on demand instead -- see
`decknix-agent-broker-replay-more'."
  :type 'integer
  :group 'decknix)

(defun decknix--agent-broker-attach-index (vec)
  "Return the index of the last `# client attached\=' marker in VEC, or nil.

That marker is the seam: everything after it is delivered live by the
broker, so replaying past it would double the output."
  (let ((i (1- (length vec))) (found nil))
    (while (and (>= i 0) (null found))
      (when (equal (string-trim (aref vec i)) "# client attached")
        (setq found i))
      (setq i (1- i)))
    found))

(defun decknix--agent-broker-boundary-before (vec end)
  "Return the index of the last committed turn boundary before END in VEC.
Returns -1 when there is none, meaning the window reaches the log start."
  (let ((i (1- end)) (found -1))
    (while (and (>= i 0) (= found -1))
      (when (decknix--agent-broker-result-stop-reason-p
             (decknix--agent-broker-parse-json-line (aref vec i)))
        (setq found i))
      (setq i (1- i)))
    found))

(defun decknix--agent-broker-window-start (vec end turns)
  "Return the start index of a replay window of TURNS turns ending at END.

Walks boundaries backwards from END.  TURNS of 0 gives the in-flight tail
alone (the last boundary before END); each further turn steps back one
more boundary.  Stops at the log start when there are fewer turns than
asked for, so a short log replays whole rather than empty."
  (let ((start (decknix--agent-broker-boundary-before vec end))
        (n turns))
    (while (and (> n 0) (> start 0))
      (setq start (decknix--agent-broker-boundary-before vec start))
      (setq n (1- n)))
    start))

(defun decknix--agent-broker-notifications-between (vec start end)
  "Return the replayable notifications in VEC strictly between START and END."
  (let ((out nil) (i (1+ start)))
    (while (< i end)
      (when-let* ((obj (decknix--agent-broker-visible-notification
                        (decknix--agent-broker-parse-json-line (aref vec i)))))
        (push obj out))
      (setq i (1+ i)))
    (nreverse out)))

(defun decknix--agent-broker-page (lines turns)
  "Return (START . NOTIFICATIONS) for a TURNS-deep page back from the attach.

START is the window\='s start index within LINES.  Returns nil when the log
has no live attach marker."
  (let* ((vec (vconcat lines))
         (end (decknix--agent-broker-attach-index vec)))
    (when end
      (let ((start (decknix--agent-broker-window-start vec end turns)))
        (cons start (decknix--agent-broker-notifications-between
                     vec start end))))))

(defcustom decknix-agent-broker-replay-window-bytes 1048576
  "Bytes of broker log read for the initial styled replay of a session.

Bounded for the same reason the status check is: these logs record a whole
session and the largest measured was 217 MB.  A megabyte covers the last
turns on every log measured; when it does not, the replay simply starts
further forward and `decknix-agent-broker-replay-more\=' reaches back by
doubling this window rather than by re-reading the file whole."
  :type 'integer
  :group 'decknix)

(defun decknix--agent-broker-read-byte-range (log-path beg end)
  "Return LOG-PATH\='s bytes between BEG and END as lines, or nil."
  (when (and log-path (file-readable-p log-path) (< beg end))
    (with-temp-buffer
      (insert-file-contents log-path nil beg end)
      (split-string (buffer-string) "\n" t))))

(defun decknix--agent-broker-log-size (key)
  "Return the size in bytes of KEY\='s broker log, or 0."
  (or (when-let* ((log (decknix--agent-broker-log-path key)))
        (file-attribute-size (file-attributes log)))
      0))

;; ── log path + buffer replay ────────────────────────────────────────

(defun decknix--agent-broker-dir ()
  "Return the broker runtime dir for sockets/pidfiles/logs/registry.
A STATE dir (`$XDG_STATE_HOME/decknix/agent-sockets', or
`~/.local/state/…'), NOT under `~/.config/decknix' — that is the system
flake's source tree, which nix copies on every `decknix switch', and a
live unix-socket file there aborts the build.  MUST stay in sync with the
`decknix-agent-broker-attach' wrapper's `reg_dir'."
  (expand-file-name "decknix/agent-sockets"
                    (or (getenv "XDG_STATE_HOME")
                        (expand-file-name ".local/state" "~"))))

(defun decknix--agent-broker-log-path (key)
  "Return the broker log path for session KEY, or nil when KEY is blank."
  (when (and key (stringp key) (not (string-empty-p key)))
    (expand-file-name (format "%s.log" key) (decknix--agent-broker-dir))))

(defun decknix--agent-broker-read-log-lines (log-path)
  "Return LOG-PATH's contents as a list of lines, or nil when unreadable."
  (when (and log-path (file-readable-p log-path))
    (with-temp-buffer
      (insert-file-contents log-path)
      (split-string (buffer-string) "\n" t))))

(defun decknix--agent-broker-pidfile-path (key)
  "Return the broker pidfile path for KEY (`<dir>/<key>.sock.pid'), or nil."
  (when-let* ((log (decknix--agent-broker-log-path key)))
    (concat (file-name-sans-extension log) ".sock.pid")))

(defun decknix--agent-broker-live-p (key)
  "Non-nil when KEY's broker process is running, per its pidfile.
Rehydrate is gated on this: a resumed session whose broker has died is
historical — its transcript prepopulation already covers it, and
replaying a stale in-flight tail would be wrong."
  (when-let* ((pf (decknix--agent-broker-pidfile-path key))
              ((file-readable-p pf))
              (pid (ignore-errors
                     (string-to-number
                      (string-trim
                       (with-temp-buffer (insert-file-contents pf)
                                         (buffer-string)))))))
    (and (integerp pid) (> pid 0)
         ;; `signal-process' rather than `call-process' to "kill": this runs
         ;; once per session per status query, and forking 13 `kill' processes
         ;; measured 0.33 s against 0.0000 s for the builtin -- the dominant
         ;; cost of a status sweep, and what made the buffer picker lag.
         ;;
         ;; Signal 0 probes without delivering.  A -1 means no such process
         ;; (or not ours, which cannot happen for a broker we spawned).
         (eq 0 (ignore-errors (signal-process pid 0))))))

(defvar-local decknix--agent-broker-replay-window nil
  "Bytes from the end of the broker log this buffer has restored.
Nil when nothing has been replayed.  `decknix-agent-broker-replay-more\='
doubles it, which is how older history loads on demand instead of all of
it loading at open.  A BYTE window rather than a line index because line
indices are not comparable across two different read windows.")

(defvar-local decknix--agent-broker-replay-depth nil
  "How many turns deep this buffer has replayed so far.")

(defun decknix--agent-broker-replay-notifications (notes)
  "Replay NOTES through the live renderer.  Returns how many were replayed.

The same `agent-shell--on-notification\=' the live stream uses, so restored
history is styled identically rather than being flat text -- the whole
point of reading the broker log instead of the session transcript.

Each is guarded individually: a `tool_call_update\=' whose `tool_call\=' is
older than the window (measured at 9 in 10764) must drop itself, not
abort the rest of the replay."
  (let ((state (agent-shell--state)))
    (dolist (n notes)
      (ignore-errors
        (agent-shell--on-notification :state state :notification n))))
  (length notes))

(defun decknix--agent-broker-rehydrate-buffer (&optional buffer turns)
  "Restore BUFFER\='s brokered history from the broker log, styled.

Replays the last TURNS committed turns (default
`decknix-agent-broker-replay-turns\=') plus any in-flight tail, read from a
BOUNDED window at the end of the log -- never the whole file, which on the
largest measured log would be a 217 MB read at session open.

No-op (nil) when replay is disabled, the buffer is not brokered, its
broker is dead, the renderer is unavailable, or the window holds no attach
marker.  Returns the number of notifications replayed."
  (with-current-buffer (or buffer (current-buffer))
    (when (and decknix-agent-broker-rehydrate-enable
               (bound-and-true-p decknix--agent-broker-key)
               (decknix--agent-broker-live-p decknix--agent-broker-key)
               (fboundp 'agent-shell--on-notification)
               (fboundp 'agent-shell--state))
      (let* ((turns (or turns decknix-agent-broker-replay-turns))
             (key decknix--agent-broker-key)
             (log (decknix--agent-broker-log-path key))
             (size (decknix--agent-broker-log-size key))
             (window decknix-agent-broker-replay-window-bytes)
             (lines (decknix--agent-broker-read-byte-range
                     log (max 0 (- size window)) size))
             (page (and lines (decknix--agent-broker-page lines turns))))
        (when page
          (setq decknix--agent-broker-replay-window window)
          (setq decknix--agent-broker-replay-depth turns)
          (decknix--agent-broker-replay-notifications (cdr page)))))))

(defcustom decknix-agent-broker-inflight-stale-seconds 120
  "How recently a broker log must have grown for its turn to count as live.

An uncommitted turn alone does not mean the agent is working.  Measured on
13 live sessions, two held an in-flight turn whose log had not moved in
104 MINUTES -- a turn abandoned when the bridge went away, not one in
progress.  Reporting those as `working\=' would be a permanent lie, which is
worse than the `ready\=' it replaces, so staleness decides."
  :type 'integer
  :group 'decknix)

(defcustom decknix-agent-broker-tail-bytes 65536
  "How many bytes from the end of a broker log to read for a status check.

Never the whole file.  The status check runs once per session per sidebar
refresh, and these logs are append-only records of an entire session:
measured on 13 open sessions, the largest was 217 MB and reading them all
cost 452 MB PER REFRESH, which is what made Emacs unresponsive.

The tail only has to reach the last turn boundary.  When it does not, that
itself is the answer -- a log with no committed boundary in its last 64 KB
is one producing output, which is what `working\=' means."
  :type 'integer
  :group 'decknix)

(defun decknix--agent-broker-read-log-tail (log-path &optional bytes)
  "Return the last BYTES of LOG-PATH as lines, or nil when unreadable.

The leading line is usually torn, which costs nothing: every consumer
parses per line and a malformed line is skipped."
  (when (and log-path (file-readable-p log-path))
    (let* ((bytes (or bytes decknix-agent-broker-tail-bytes))
           (size (or (file-attribute-size (file-attributes log-path)) 0))
           (beg (max 0 (- size bytes))))
      (with-temp-buffer
        (insert-file-contents log-path nil beg size)
        (split-string (buffer-string) "\n" t)))))

(defun decknix--agent-broker-inflight-p (lines)
  "Non-nil when LINES end in an uncommitted turn carrying visible content.

Visible content is the test, not merely lines after the boundary: an idle
session still emits usage and mode updates after its last turn committed,
and counting those marks every session as working."
  (let* ((vec (vconcat lines))
         (n (length vec))
         (boundary (decknix--agent-broker-boundary-before vec n)))
    (if (< boundary 0)
        ;; No committed boundary in the window.  Over a bounded tail that
        ;; is itself the answer: a log whose last 64 KB holds no turn
        ;; boundary is one that has been producing output throughout it.
        (> n 0)
      (let ((i (1+ boundary)) (found nil))
        (while (and (< i n) (null found))
          (when (decknix--agent-broker-visible-notification
                 (decknix--agent-broker-parse-json-line (aref vec i)))
            (setq found t))
          (setq i (1+ i)))
        found))))

(defun decknix--agent-broker-log-fresh-p (key)
  "Non-nil when KEY\='s broker log grew within the staleness window."
  (when-let* ((log (decknix--agent-broker-log-path key))
              ((file-readable-p log))
              (mtime (file-attribute-modification-time
                      (file-attributes log))))
    (< (float-time (time-subtract (current-time) mtime))
       decknix-agent-broker-inflight-stale-seconds)))

(defvar decknix--agent-broker-working-cache (make-hash-table :test 'equal)
  "Broker key -> (MTIME SIZE INFLIGHT-P): the last probe and what it saw.

Keyed on the log\='s MTIME and SIZE rather than on a wall-clock TTL.  A log
that has not grown cannot have changed what the last turn looks like, so
the answer is still valid however long ago it was computed -- and a TTL
is guesswork against the tick interval besides.  The first attempt used a
2 second TTL while two timers tick every 2 seconds, so it almost never
hit.

Allocation, not CPU, is why this matters.  Each miss reads 64 KB, splits
it into hundreds of strings and JSON-parses each one; at 13 sessions
every 2 seconds that churn drives the GC, and GC is what interrupts
typing.  An unchanged log now costs one `file-attributes\=' and no
allocation at all.")

(defun decknix--agent-broker-inflight-cached-p (key attrs)
  "Return whether KEY\='s log ends mid-turn, reusing the last probe if valid.

ATTRS is KEY\='s log `file-attributes\='.  Re-reads only when the log has
grown or been replaced."
  (let* ((mtime (float-time (file-attribute-modification-time attrs)))
         (size (file-attribute-size attrs))
         (hit (gethash key decknix--agent-broker-working-cache)))
    (if (and hit (equal mtime (nth 0 hit)) (equal size (nth 1 hit)))
        (nth 2 hit)
      (let ((val (and (decknix--agent-broker-inflight-p
                       (decknix--agent-broker-read-log-tail
                        (decknix--agent-broker-log-path key)))
                      t)))
        (puthash key (list mtime size val)
                 decknix--agent-broker-working-cache)
        val))))

(defun decknix--agent-broker-working-p (&optional buffer)
  "Non-nil when BUFFER\='s agent is mid-turn according to its broker log.

Both conditions: an uncommitted turn with visible content, AND a log that
has grown recently.  Either alone is not evidence -- see
`decknix-agent-broker-inflight-stale-seconds\='.

Freshness is recomputed every call because it depends on the clock: a
fresh log goes stale with no file change, so caching that half would pin
an abandoned turn at `working\='.  Only the expensive half -- parsing the
log tail -- is cached, and on the file\='s own identity."
  (with-current-buffer (or buffer (current-buffer))
    (when-let* (((bound-and-true-p decknix--agent-broker-key))
                (key decknix--agent-broker-key)
                (log (decknix--agent-broker-log-path key))
                (attrs (file-attributes log)))
      (and (decknix--agent-broker-live-p key)
           ;; Cheap and clock-dependent, so computed from the stat we
           ;; already have rather than re-stat'ing inside a helper.
           (< (- (float-time (current-time))
                 (float-time (file-attribute-modification-time attrs)))
              decknix-agent-broker-inflight-stale-seconds)
           (decknix--agent-broker-inflight-cached-p key attrs)))))

(defun decknix--agent-broker-can-restore-p (&optional buffer)
  "Non-nil when BUFFER\='s history should come from the broker log.

True for a session whose broker is still ALIVE: the log holds the real
event stream, so replaying it restores the buffer styled, including
whatever the agent did while Emacs was down.

False once the broker has died, in which case the session is genuinely
historical and the transcript prepopulation is the only source left.
Deciding this BEFORE prepopulating is what stops the two paths both
rendering the same conversation."
  (with-current-buffer (or buffer (current-buffer))
    (and decknix-agent-broker-rehydrate-enable
         (bound-and-true-p decknix--agent-broker-key)
         (decknix--agent-broker-live-p decknix--agent-broker-key)
         (fboundp 'agent-shell--on-notification)
         (fboundp 'agent-shell--state)
         t)))

(defun decknix-agent-broker-replay-more (&optional _arg)
  "Load more of this session\='s history above what is shown.

Doubles the byte window read from the end of the broker log and replays
only the newly exposed region, so paging back costs the new bytes rather
than a fresh read of a file that can be 217 MB."
  (interactive "p")
  (unless (bound-and-true-p decknix--agent-broker-key)
    (user-error "Not a brokered session"))
  (let* ((key decknix--agent-broker-key)
         (log (decknix--agent-broker-log-path key))
         (size (decknix--agent-broker-log-size key))
         (old-window (or decknix--agent-broker-replay-window
                         decknix-agent-broker-replay-window-bytes))
         (new-window (* 2 old-window))
         (beg (max 0 (- size new-window)))
         (end (max 0 (- size old-window))))
    (cond
     ((<= size 0) (message "No broker log to read"))
     ((<= end 0) (message "Already showing the start of this session"))
     (t
      (let* ((lines (decknix--agent-broker-read-byte-range log beg end))
             (vec (and lines (vconcat lines)))
             ;; Snap to the first turn boundary in the new region, so the
             ;; replay does not begin mid-turn with a tool_call_update
             ;; whose tool_call is outside the window.
             (start (and vec (decknix--agent-broker-boundary-before
                              vec (length vec))))
             (notes (and vec (decknix--agent-broker-notifications-between
                              vec (if (and start (>= start 0)) start -1)
                              (length vec))))
             (inhibit-read-only t))
        (save-excursion
          (goto-char (point-min))
          (decknix--agent-broker-replay-notifications notes))
        (setq decknix--agent-broker-replay-window new-window)
        (message "Loaded %d more notification%s (%s)"
                 (length notes) (if (= 1 (length notes)) "" "s")
                 (if (<= beg 0) "start of session"
                   (format "%d KB deep" (/ new-window 1024)))))))))

(provide 'decknix-agent-broker-rehydrate)
;;; decknix-agent-broker-rehydrate.el ends here
