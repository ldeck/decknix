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

START is the window\='s start index, so a caller can ask for the next page
further back.  Returns nil when the log has no live attach marker."
  (let* ((vec (vconcat lines))
         (end (decknix--agent-broker-attach-index vec)))
    (when end
      (let ((start (decknix--agent-broker-window-start vec end turns)))
        (cons start (decknix--agent-broker-notifications-between
                     vec start end))))))

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
         (= 0 (call-process "kill" nil nil nil "-0" (number-to-string pid))))))

(defvar-local decknix--agent-broker-replay-start nil
  "Index in the broker log where this buffer\='s restored history begins.
Nil when nothing has been replayed.  `decknix-agent-broker-replay-more\='
walks it further back, which is how older history loads on demand instead
of all of it loading at open.")

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
`decknix-agent-broker-replay-turns\=') plus any in-flight tail, backwards
from the live attach marker.  BUFFER defaults to the current buffer and
must be a live agent-shell buffer carrying a `decknix--agent-broker-key\='.

No-op (nil) when replay is disabled, the buffer is not brokered, its
broker is dead, the renderer is unavailable, or the log has no attach
marker.  Returns the number of notifications replayed."
  (with-current-buffer (or buffer (current-buffer))
    (when (and decknix-agent-broker-rehydrate-enable
               (bound-and-true-p decknix--agent-broker-key)
               (decknix--agent-broker-live-p decknix--agent-broker-key)
               (fboundp 'agent-shell--on-notification)
               (fboundp 'agent-shell--state))
      (let* ((turns (or turns decknix-agent-broker-replay-turns))
             (log   (decknix--agent-broker-log-path decknix--agent-broker-key))
             (lines (decknix--agent-broker-read-log-lines log))
             (page  (and lines (decknix--agent-broker-page lines turns))))
        (when page
          (setq decknix--agent-broker-replay-start (car page))
          (setq decknix--agent-broker-replay-depth turns)
          (decknix--agent-broker-replay-notifications (cdr page)))))))

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

(defun decknix-agent-broker-replay-more (&optional turns)
  "Load TURNS more turns of this session\='s history above what is shown.

Reads further back in the broker log and prepends the result, so history
arrives on demand rather than all of it being replayed at open -- the
longest live log measured 95872 lines."
  (interactive "p")
  (unless (bound-and-true-p decknix--agent-broker-key)
    (user-error "Not a brokered session"))
  (let* ((turns (max 1 (or turns 1)))
         (log (decknix--agent-broker-log-path decknix--agent-broker-key))
         (lines (decknix--agent-broker-read-log-lines log))
         (vec (and lines (vconcat lines)))
         (end (or decknix--agent-broker-replay-start
                  (and vec (decknix--agent-broker-attach-index vec)))))
    (cond
     ((or (null vec) (null end))
      (message "No broker log to read"))
     ((<= end 0)
      (message "Already at the start of this session"))
     (t
      (let* ((start (decknix--agent-broker-window-start vec end (1- turns)))
             (notes (decknix--agent-broker-notifications-between vec start end))
             (inhibit-read-only t))
        (save-excursion
          (goto-char (point-min))
          (decknix--agent-broker-replay-notifications notes))
        (setq decknix--agent-broker-replay-start start)
        (setq decknix--agent-broker-replay-depth
              (+ (or decknix--agent-broker-replay-depth 0) turns))
        (message "Loaded %d more notification%s (%s)"
                 (length notes) (if (= 1 (length notes)) "" "s")
                 (if (<= start 0) "start of session"
                   (format "%d turns deep" decknix--agent-broker-replay-depth))))))))

(provide 'decknix-agent-broker-rehydrate)
;;; decknix-agent-broker-rehydrate.el ends here
