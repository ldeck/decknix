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
;; (`~/.config/decknix/agent-sockets/<key>.log') is a complete record of
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

;; ── log path + buffer replay ────────────────────────────────────────

(defun decknix--agent-broker-log-path (key)
  "Return the broker log path for session KEY, or nil when KEY is blank.
Mirrors the `decknix-agent-broker-attach' wrapper:
`$XDG_CONFIG_HOME/decknix/agent-sockets/<key>.log' (or `~/.config/…')."
  (when (and key (stringp key) (not (string-empty-p key)))
    (expand-file-name
     (format "%s.log" key)
     (expand-file-name "decknix/agent-sockets"
                       (or (getenv "XDG_CONFIG_HOME")
                           (expand-file-name ".config" "~"))))))

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

(defun decknix--agent-broker-rehydrate-buffer (&optional buffer)
  "Replay BUFFER's brokered in-flight turn from the broker log.
BUFFER defaults to the current buffer and must be a live agent-shell
buffer carrying a `decknix--agent-broker-key'.  No-op (returns nil) when
rehydrate is disabled, the buffer is not brokered, the renderer is
unavailable, or the log has no in-flight tail.  Returns the number of
notifications replayed."
  (with-current-buffer (or buffer (current-buffer))
    (when (and decknix-agent-broker-rehydrate-enable
               (bound-and-true-p decknix--agent-broker-key)
               (decknix--agent-broker-live-p decknix--agent-broker-key)
               (fboundp 'agent-shell--on-notification)
               (fboundp 'agent-shell--state))
      (let* ((log   (decknix--agent-broker-log-path decknix--agent-broker-key))
             (lines (decknix--agent-broker-read-log-lines log))
             (notes (and lines
                         (decknix--agent-broker-inflight-notifications lines))))
        (when notes
          (let ((state (agent-shell--state)))
            (dolist (n notes)
              (ignore-errors
                (agent-shell--on-notification :state state :notification n))))
          (length notes))))))

(provide 'decknix-agent-broker-rehydrate)
;;; decknix-agent-broker-rehydrate.el ends here
