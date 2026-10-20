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
(require 'cl-lib)

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
return nil.

No `string-trim': its trailing-whitespace regexp is matched from every
position of a line that can run to 14 KB, and the status probe calls this
for every line of a 64 KB tail.  The JSON parser skips the whitespace
itself."
  (when (and line (stringp line))
    (let ((i (string-match-p "[^ \t\r\n]" line)))
      (when (and i (eq (aref line i) ?{))
        (ignore-errors
          (json-parse-string line :object-type 'alist
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

;; A substring test before the parse.  Most lines of a busy log are
;; neither a turn boundary nor visible content, and a `string-search' over
;; a line costs far less than parsing it into an alist only to discard it.
;; Neither key can appear outside its own object unescaped, so the filter
;; never rejects a line the parse would have accepted.

(defun decknix--agent-broker-line-boundary-p (line)
  "Non-nil when raw LINE is a committed turn boundary."
  (and (string-search "\"stopReason\"" line)
       (decknix--agent-broker-result-stop-reason-p
        (decknix--agent-broker-parse-json-line line))))

(defun decknix--agent-broker-line-notification (line)
  "Return raw LINE parsed when it is a replayable notification, else nil."
  (and (string-search "\"sessionUpdate\"" line)
       (decknix--agent-broker-visible-notification
        (decknix--agent-broker-parse-json-line line))))

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
          (when (decknix--agent-broker-line-boundary-p (aref vec i))
            (setq boundary-idx i))
          (setq i (1- i))))
      ;; visible agent notifications in (boundary-idx, attach-idx)
      (let ((out nil) (i (1+ boundary-idx)))
        (while (< i attach-idx)
          (when-let* ((obj (decknix--agent-broker-line-notification
                            (aref vec i))))
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
      (when (decknix--agent-broker-line-boundary-p (aref vec i))
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
      (when-let* ((obj (decknix--agent-broker-line-notification (aref vec i))))
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
    (split-string (decknix--agent-broker-read-bytes log-path beg end) "\n" t)))

(defun decknix--agent-broker-log-size (key)
  "Return the size in bytes of KEY\='s broker log, or 0."
  (or (when-let* ((log (decknix--agent-broker-log-path key)))
        (file-attribute-size (file-attributes log)))
      0))

;; ── log path + buffer replay ────────────────────────────────────────

(defvar decknix--agent-broker-dir-memo nil
  "(XDG_STATE_HOME . DIR) from the last `decknix--agent-broker-dir\=' call.
The dir is resolved on every status query of every session, and
`expand-file-name\=' plus `getenv\=' showed in the sidebar's paint profile.
Keyed on the env value so a changed XDG_STATE_HOME still takes effect.")

(defun decknix--agent-broker-dir ()
  "Return the broker runtime dir for sockets/pidfiles/logs/registry.
A STATE dir (`$XDG_STATE_HOME/decknix/agent-sockets', or
`~/.local/state/…'), NOT under `~/.config/decknix' — that is the system
flake's source tree, which nix copies on every `decknix switch', and a
live unix-socket file there aborts the build.  MUST stay in sync with the
`decknix-agent-broker-attach' wrapper's `reg_dir'."
  (let ((env (getenv "XDG_STATE_HOME")))
    (if (and decknix--agent-broker-dir-memo
             (equal env (car decknix--agent-broker-dir-memo)))
        (cdr decknix--agent-broker-dir-memo)
      (let ((dir (expand-file-name "decknix/agent-sockets"
                                   (or env (expand-file-name ".local/state" "~")))))
        (setq decknix--agent-broker-dir-memo (cons env dir))
        dir))))

(defun decknix--agent-broker-log-path (key)
  "Return the broker log path for session KEY, or nil when KEY is blank."
  (when (and key (stringp key) (not (string-empty-p key)))
    (concat (file-name-as-directory (decknix--agent-broker-dir)) key ".log")))

(defmacro decknix--agent-broker-without-file-hooks (&rest body)
  "Run BODY with file-name handlers and coding detection out of the way.
Every broker file is a local plain file, so TRAMP-style handler dispatch
can only cost.  More to the point, a plain `insert-file-contents\=' runs
`set-auto-coding\=', which the editorconfig package advises to walk up
the directory tree looking for `.editorconfig\=' files: a quarter of
the status probe\='s time, for a pidfile holding five digits."
  (declare (indent 0) (debug t))
  `(let ((file-name-handler-alist nil))
     ,@body))

(defun decknix--agent-broker-read-bytes (file &optional beg end)
  "Return FILE\='s raw bytes between BEG and END as a unibyte string.
Literal: no coding detection, no format decoding, no hooks (see
`decknix--agent-broker-without-file-hooks\=').  The JSON parser accepts
UTF-8 bytes directly, so nothing downstream needs them decoded."
  (decknix--agent-broker-without-file-hooks
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file nil beg end)
      (buffer-string))))

(defun decknix--agent-broker-read-log-lines (log-path)
  "Return LOG-PATH's contents as a list of lines, or nil when unreadable."
  (when (and log-path (file-readable-p log-path))
    (split-string (decknix--agent-broker-read-bytes log-path) "\n" t)))

(defun decknix--agent-broker-pidfile-path (key)
  "Return the broker pidfile path for KEY (`<dir>/<key>.sock.pid'), or nil."
  (when (and key (stringp key) (not (string-empty-p key)))
    (concat (file-name-as-directory (decknix--agent-broker-dir)) key ".sock.pid")))

(defvar decknix--agent-broker-pid-cache (make-hash-table :test 'equal)
  "Pidfile path -> (MTIME SIZE . PID) as last read.
A broker writes its pidfile once at spawn, yet the status chain read it
on every query: the external `sample\=' of a sluggish daemon put 35% of
main-thread time in this one read, most of it in `open(2)\='.  A stat
is enough to know the file is the one already read.")

(defun decknix--agent-broker-pidfile-pid (pf)
  "Return the pid recorded in pidfile PF, or nil.  Cached on PF\='s stat."
  (let ((attrs (decknix--agent-broker-without-file-hooks
                 (file-attributes pf))))
    (if (null attrs)
        (progn (remhash pf decknix--agent-broker-pid-cache) nil)
      (let ((mtime (float-time (file-attribute-modification-time attrs)))
            (size (file-attribute-size attrs))
            (hit (gethash pf decknix--agent-broker-pid-cache)))
        (if (and hit (equal mtime (car hit)) (equal size (cadr hit)))
            (cddr hit)
          (let ((pid (ignore-errors
                       (string-to-number
                        (string-trim (decknix--agent-broker-read-bytes pf))))))
            (puthash pf (cons mtime (cons size pid))
                     decknix--agent-broker-pid-cache)
            pid))))))

(defun decknix--agent-broker-live-p (key)
  "Non-nil when KEY's broker process is running, per its pidfile.
Rehydrate is gated on this: a resumed session whose broker has died is
historical — its transcript prepopulation already covers it, and
replaying a stale in-flight tail would be wrong."
  (when-let* ((pf (decknix--agent-broker-pidfile-path key))
              (pid (decknix--agent-broker-pidfile-pid pf)))
    (and (integerp pid) (> pid 0)
         ;; `signal-process' rather than `call-process' to "kill": this runs
         ;; once per session per status query, and forking 13 `kill' processes
         ;; measured 0.33 s against 0.0000 s for the builtin -- the dominant
         ;; cost of a status sweep, and what made the buffer picker lag.
         ;;
         ;; Signal 0 probes without delivering.  A -1 means no such process
         ;; (or not ours, which cannot happen for a broker we spawned).
         ;; Probed every call, never cached: a broker can die and leave
         ;; its pidfile behind.
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
      (split-string (decknix--agent-broker-read-bytes log-path beg size)
                    "\n" t))))

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
          (when (decknix--agent-broker-line-notification (aref vec i))
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

;; ── incremental working state ──────────────────────────────────────
;;
;; A log that is being written is exactly the log whose answer matters,
;; and an mtime+size key always misses on it: the four actively written
;; logs re-read and re-parsed a 64 KB tail on every status query.  So the
;; cache remembers HOW FAR it has read, and a grown log costs only the
;; bytes appended since.  Lines are consumed only up to the last newline,
;; so a line torn by a concurrent write is read whole next time rather
;; than lost -- losing a `stopReason' line would pin `working' until the
;; staleness window.

(defvar decknix--agent-broker-working-cache (make-hash-table :test 'equal)
  "Broker key -> (MTIME SIZE OFFSET INFLIGHT-P PROBED-AT).

MTIME and SIZE identify the log as last seen; an unchanged log costs one
`file-attributes\=' and no allocation.  OFFSET is the byte just past the
last complete line consumed, INFLIGHT-P the running answer, PROBED-AT the
`float-time\=' of the last read.

Allocation, not CPU, is why this matters.  Each full probe reads 64 KB,
splits it into hundreds of strings and JSON-parses the candidates; at a
dozen sessions every 2 seconds that churn drives the GC, and GC is what
interrupts typing.")

(defcustom decknix-agent-broker-working-reprobe-seconds 3
  "Minimum seconds between reads of a broker log that keeps growing.

A busy log grows between every pair of status queries, so without a floor
it is opened on each one, and `open(2)\=' dominated the sampled probe.
The cost is lag: a turn that ends is seen as ended at most this many
seconds late.  An unchanged log is never re-read whatever this is."
  :type 'number
  :group 'decknix)

(defun decknix--agent-broker-complete-lines (bytes)
  "Return (CONSUMED . LINES) for the complete lines of BYTES.
CONSUMED counts bytes through the last newline; a trailing partial line
is left for the next read."
  (let ((nl (cl-position ?\n bytes :from-end t)))
    (if (null nl)
        (cons 0 nil)
      (cons (1+ nl) (split-string (substring bytes 0 nl) "\n" t)))))

(defun decknix--agent-broker-inflight-advance (inflight lines)
  "Return INFLIGHT after reading LINES, appended in file order.
A boundary ends the turn; visible content after it starts one.  Anything
else (usage, mode updates, markers) leaves the answer as it was.  This is
`decknix--agent-broker-inflight-p\=' read forwards, so it can resume."
  (dolist (line lines inflight)
    (cond ((decknix--agent-broker-line-boundary-p line) (setq inflight nil))
          ((decknix--agent-broker-line-notification line) (setq inflight t)))))

(defun decknix--agent-broker-probe-full (log size)
  "Read LOG\='s last tail and return (OFFSET . INFLIGHT-P)."
  (let* ((beg (max 0 (- size decknix-agent-broker-tail-bytes)))
         (part (decknix--agent-broker-complete-lines
                (decknix--agent-broker-read-bytes log beg size))))
    (cons (+ beg (car part))
          (and (decknix--agent-broker-inflight-p (cdr part)) t))))

(defun decknix--agent-broker-probe-append (log offset size inflight)
  "Read LOG\='s bytes OFFSET..SIZE and return (OFFSET . INFLIGHT-P)."
  (let ((part (decknix--agent-broker-complete-lines
               (decknix--agent-broker-read-bytes log offset size))))
    (cons (+ offset (car part))
          (and (decknix--agent-broker-inflight-advance inflight (cdr part)) t))))

(defun decknix--agent-broker-inflight-cached-p (key attrs &optional now)
  "Return whether KEY\='s log ends mid-turn, reading as little as possible.

ATTRS is KEY\='s log `file-attributes\='.  An unchanged log is not read.
A grown one is read from where the last read stopped, at most once per
`decknix-agent-broker-working-reprobe-seconds\='.  A shrunk or replaced log, or
one that grew by more than a tail, is probed afresh.  NOW defaults to
`float-time\='."
  (let* ((now (or now (float-time)))
         (mtime (float-time (file-attribute-modification-time attrs)))
         (size (file-attribute-size attrs))
         (hit (gethash key decknix--agent-broker-working-cache))
         (offset (nth 2 hit)))
    (cond
     ((and hit (equal mtime (nth 0 hit)) (equal size (nth 1 hit)))
      (nth 3 hit))
     ((and hit (>= size offset)
           (< (- now (nth 4 hit)) decknix-agent-broker-working-reprobe-seconds))
      (nth 3 hit))
     (t
      (let* ((log (decknix--agent-broker-log-path key))
             (res (if (and hit (>= size offset)
                           (<= (- size offset) decknix-agent-broker-tail-bytes))
                      (decknix--agent-broker-probe-append
                       log offset size (nth 3 hit))
                    (decknix--agent-broker-probe-full log size))))
        (puthash key (list mtime size (car res) (cdr res) now)
                 decknix--agent-broker-working-cache)
        (cdr res))))))

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
