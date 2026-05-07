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
;;   `decknix--agent-session-extract-history' -- single-pass turn
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
;;       the next user message or end-of-history, and finally taking
;;       the last N turns.  This pairs each user message with its
;;       real assistant response (the most recent interaction
;;       included) instead of the same entry's almost-always-empty
;;       `response_text' that an earlier backward-walk picked up.
;;
;; Both functions are pure: the path builder is `expand-file-name'
;; over a hardcoded base, and the extractor only reads JSON and
;; allocates cons cells -- no global state, no buffer or shell
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

(defun decknix--agent-session-extract-history (session-id n)
  "Extract the last N user-visible exchanges from SESSION-ID's local JSON.
Returns a list of (USER-MSG . ASSISTANT-RESP) cons cells, oldest first.

The auggie session JSON's `chatHistory' splits each user->assistant turn
across many entries: one entry carries the user text in `request_message'
(with `response_text' typically empty), and the assistant's reply is
spread across the *following* entries as response chunks (their
`request_message' is empty -- those entries are tool results / streaming
fragments attributed to the same turn).  A new turn starts when
`request_message' becomes non-empty again.

Single forward pass: accumulate `response_text' chunks under the current
user message; close the turn when the next user message arrives or the
history ends; finally take the last N turns.  This pairs each user
message with its real assistant response (the most recent interaction
included) instead of the same entry's almost-always-empty
`response_text', which the previous backward-walk picked up."
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
            (let* ((all (nreverse turns))
                   (len (length all)))
              (if (> len n) (nthcdr (- len n) all) all)))
        (error
         (message "Failed to read session history: %s"
                  (error-message-string err))
         nil)))))

(provide 'decknix-agent-session-history)
;;; decknix-agent-session-history.el ends here
