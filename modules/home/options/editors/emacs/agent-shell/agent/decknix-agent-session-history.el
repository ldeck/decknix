;;; decknix-agent-session-history.el --- Local session JSON path + history extractor -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, session, history

;;; Commentary:
;;
;; Pure reader for the on-disk auggie session JSON carved out of
;; `decknix-agent-shell-main' (main-bulk) into the same
;; `agent-shell/agent/' cluster as the rest of the per-conversation
;; persistence helpers.  Two entry points:
;;
;;   `decknix--agent-session-file' -- pure path builder that maps a
;;       SESSION-ID to the full local JSON path under
;;       `~/.augment/sessions/'.  Used by the in-buffer resume flow
;;       (`decknix--agent-session-prepopulate' /
;;       `--restore-input-ring' in main-bulk), the grep
;;       jump-to-match flow, the compose history streamer, and the
;;       backup / cleanup commands.
;;
;;   `decknix--agent-session-extract-all-turns' -- single-pass turn
;;       grouper over the session's `chatHistory' array.  The auggie
;;       JSON splits each user->assistant turn across many entries:
;;       one entry carries the user text in `request_message' (with
;;       `response_text' typically empty), and the assistant's reply
;;       is spread across the *following* entries as response chunks
;;       (their `request_message' is empty -- those entries are
;;       tool-result / streaming fragments attributed to the same
;;       turn).  A new turn opens whenever `request_message' becomes
;;       non-empty again.
;;
;;       Walks the array forward once, accumulating `response_text'
;;       chunks under the current user message, closing the turn on
;;       the next user message or end-of-history.  Returns the full
;;       turn list oldest-first so callers (timeline navigation,
;;       jump-to-match) can index into it without re-parsing.
;;
;;   `decknix--agent-session-extract-history' -- thin wrapper that
;;       delegates to `extract-all-turns' and then takes the last N
;;       turns.  Preserves the original (pre-#136) contract.
;;
;;   `decknix--agent-session-window-clamp' -- pure window math.
;;       Returns CURSOR clamped to [0, max(0, TOTAL-COUNT)] so the
;;       window [cursor, cursor+count) sits inside [0, TOTAL).  Used
;;       by the buffer-side `[' / `]' timeline navigation in
;;       main-bulk.
;;
;;   `decknix--agent-session-take-window' -- pure list slicer.
;;       Returns up to COUNT turns from TURNS starting at the
;;       window-clamped CURSOR.
;;
;;   `decknix--agent-session-find-turn-containing' -- pure search.
;;       Returns the 0-based index of the first turn (oldest-first)
;;       whose user message OR assistant response matches REGEXP
;;       (case-insensitive).  Used by the session-grep jump-to-match
;;       flow (#136) when the matched turn lies outside the loaded
;;       `decknix-agent-session-history-count' window: the buffer
;;       seeds its `decknix--agent-history-cursor' so the matched
;;       turn lands at the bottom of the rendered window.
;;
;; All functions are pure: the path builder is `expand-file-name'
;; over a hardcoded base, the extractors only read JSON and
;; allocate cons cells, and the window helpers do arithmetic on
;; integers and lists -- no global state, no buffer or shell
;; side-effects.  The companion writer / mutation paths
;; (`decknix--agent-session-restore-input-ring',
;; `decknix--agent-session-prepopulate') stay in main-bulk per
;; AGENTS.md Rule 2 because they touch `comint-input-ring' and
;; insert text into the agent buffer.

;;; Code:

(require 'json)
(require 'subr-x)

(defun decknix--agent-session-file (session-id)
  "Return the path to the local session JSON for SESSION-ID."
  (expand-file-name (concat session-id ".json")
                    (expand-file-name "sessions" "~/.augment")))

(defun decknix--agent-session-extract-all-turns (session-id)
  "Extract ALL user-visible exchanges from SESSION-ID's local JSON.
Returns a list of (USER-MSG . ASSISTANT-RESP) cons cells, oldest
first.  Returns nil if the file does not exist or fails to parse.

The auggie session JSON's `chatHistory' splits each user->assistant
turn across many entries: one entry carries the user text in
`request_message' (with `response_text' typically empty), and the
assistant's reply is spread across the *following* entries as
response chunks (their `request_message' is empty -- those entries
are tool results / streaming fragments attributed to the same
turn).  A new turn starts when `request_message' becomes non-empty
again.

Single forward pass: accumulate `response_text' chunks under the
current user message; close the turn when the next user message
arrives or the history ends.  This pairs each user message with
its real assistant response (the most recent interaction included)
instead of the same entry's almost-always-empty `response_text',
which the previous backward-walk picked up.

Used by `decknix--agent-session-extract-history' (which then takes
the last N turns) and by the timeline navigation / jump-to-match
flow (#136) which needs the full list to index into."
  (let ((file (decknix--agent-session-file session-id)))
    (when (file-exists-p file)
      (condition-case err
          (let* ((json-array-type 'list)
                 (json-object-type 'alist)
                 (json-key-type 'symbol)
                 (data (json-read-file file))
                 (history (alist-get 'chatHistory data))
                 (turns nil)
                 (cur-user nil)
                 (cur-resp nil))
            (dolist (entry history)
              (let* ((ex (alist-get 'exchange entry))
                     (req (alist-get 'request_message ex ""))
                     (resp (alist-get 'response_text ex "")))
                (when (and (stringp req)
                           (not (string-empty-p (string-trim req))))
                  ;; Close out the previous turn (if any).
                  (when cur-user
                    (push (cons cur-user
                                (mapconcat #'identity
                                           (nreverse cur-resp) "\n"))
                          turns))
                  (setq cur-user req
                        cur-resp nil))
                (when (and cur-user
                           (stringp resp)
                           (not (string-empty-p resp)))
                  (push resp cur-resp))))
            ;; Close out the final turn so the most recent interaction
            ;; is always included.
            (when cur-user
              (push (cons cur-user
                          (mapconcat #'identity (nreverse cur-resp) "\n"))
                    turns))
            (nreverse turns))
        (error
         (message "Failed to read session history: %s"
                  (error-message-string err))
         nil)))))

(defun decknix--agent-session-extract-history (session-id n)
  "Extract the last N user-visible exchanges from SESSION-ID's local JSON.
Returns a list of (USER-MSG . ASSISTANT-RESP) cons cells, oldest first.

Thin wrapper around `decknix--agent-session-extract-all-turns'
that takes the last N turns -- preserves the pre-#136 contract."
  (let* ((all (decknix--agent-session-extract-all-turns session-id))
         (len (length all)))
    (if (> len n) (nthcdr (- len n) all) all)))

(defun decknix--agent-session-window-clamp (cursor count total)
  "Clamp CURSOR so the window [cursor, cursor+COUNT) sits within [0, TOTAL).
Returns 0 when TOTAL is 0 or COUNT is non-positive, so renderers
get a usable starting point even on an empty session.  Otherwise
returns CURSOR clamped to the closed range [0, max(0, TOTAL-COUNT)]
-- callers (timeline `[' / `]') can pass in arbitrarily-out-of-range
cursors and get back a value safe to pass to
`decknix--agent-session-take-window'."
  (cond
   ((or (<= total 0) (<= count 0)) 0)
   ((<= total count) 0)
   (t (max 0 (min cursor (- total count))))))

(defun decknix--agent-session-take-window (turns cursor count)
  "Return up to COUNT turns from TURNS starting at clamped CURSOR.
CURSOR is run through `decknix--agent-session-window-clamp' against
TURNS' length so out-of-range values are silently corrected.
Returns nil when TURNS is empty or COUNT is non-positive."
  (when (and turns (> count 0))
    (let* ((total (length turns))
           (start (decknix--agent-session-window-clamp cursor count total))
           (rest (nthcdr start turns))
           (taken nil)
           (i 0))
      (while (and rest (< i count))
        (push (car rest) taken)
        (setq rest (cdr rest)
              i (1+ i)))
      (nreverse taken))))

(defun decknix--agent-session-find-turn-containing (turns regexp)
  "Return 0-based index of first turn in TURNS whose text matches REGEXP.
Searches both the user message (car) and assistant response (cdr)
of each turn, case-insensitively (`case-fold-search' bound to t).
Returns nil if TURNS is empty, REGEXP is nil/empty, or no turn
matches.

Used by the session-grep jump-to-match flow (#136): the typed
search term that ripgrep matched against the on-disk JSON is
re-scanned against the same parsed turn list so the buffer-side
caller can position the timeline cursor on the matched turn."
  (when (and turns
             (stringp regexp)
             (not (string-empty-p regexp)))
    (let ((case-fold-search t)
          (idx 0))
      (catch 'found
        (dolist (turn turns)
          (when (or (and (stringp (car turn))
                         (string-match-p regexp (car turn)))
                    (and (stringp (cdr turn))
                         (string-match-p regexp (cdr turn))))
            (throw 'found idx))
          (setq idx (1+ idx)))
        nil))))

(provide 'decknix-agent-session-history)
;;; decknix-agent-session-history.el ends here
