;;; decknix-agent-resume-primer.el --- Resume continuation primer -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, session, resume

;;; Commentary:
;;
;; Pure helper for the resume "continuation primer" (#143).
;;
;; Auggie's `--resume <id>' CLI flag natively reloads the prior
;; transcript into the model's context, so a resumed auggie session
;; already knows the conversation.  The separate-bridge providers
;; (Claude via `claude-agent-acp', Pi via `pi-acp') do NOT: their
;; `--resume' flag is a no-op, the ACP session starts on a fresh
;; `session/new', and only the Emacs BUFFER is repopulated from the
;; on-disk transcript (see `decknix--agent-session-prepopulate').  The
;; model itself boots with an empty context window, so `/show-context'
;; and the agent behave as if there were no prior session.
;;
;; To close that gap without an ACP `session/load' round-trip, the
;; resume path auto-sends a lightweight "primer" as the first user
;; message once the resumed session reports ready (mirroring the fork
;; hand-off, `decknix-agent-fork.el').  The primer tells the model it
;; is continuing an ongoing conversation and points it at the prior
;; transcript file so it can reload as much context as it needs — the
;; same cost auggie pays on a native resume, but paid lazily by the
;; model rather than pasted inline (which would bloat the first prompt).
;;
;; One pure function here so it can be exercised by ERT without a live
;; session; the orchestration (provider lookups,
;; `agent-shell-subscribe-to', `shell-maker-submit') stays in main-bulk
;; per AGENTS.md Rule 2:
;;
;;   (decknix--agent-resume-primer-message
;;      PROVIDER-LABEL SESSION-ID DATA-PATH TAGS LAST-USER-MESSAGE)
;;     -> plain-text first-message, or nil when SESSION-ID is missing.

;;; Code:

(defconst decknix--agent-resume-primer-last-message-width 400
  "Max width of the \"most recently\" excerpt in a resume primer.
The last user message is a one-line grounding cue only — the full
history lives in the transcript file the primer points at — so it is
collapsed to a single line and truncated to this width to keep the
first prompt small.")

(defun decknix--agent-resume-primer-message (provider-label session-id
                                                            data-path tags
                                                            last-user-message)
  "Build the continuation primer for a resumed agent session.

PROVIDER-LABEL is the human-readable label of the resumed session's
provider (e.g. \"Claude\"); nil degrades to generic phrasing.
SESSION-ID is the resumed session id.  DATA-PATH is the best-effort
on-disk transcript location (see
`decknix--agent-fork-source-data-path').  TAGS is the list of
conversation tag strings.  LAST-USER-MESSAGE is the most recent user
turn, used as a one-line grounding cue.

Returns a plain-text message suitable for auto-sending as the resumed
session's first user message, or nil when SESSION-ID is nil/empty
\(nothing to resume, so nothing to prime).  Detail lines for unknown
fields (nil / empty) are omitted so the message degrades gracefully
when metadata is missing.  Plain text only — the comint buffer renders
markdown literally and the prompt should read cleanly to any provider."
  (when (and session-id (stringp session-id) (not (string-empty-p session-id)))
    (let* ((have-label (and provider-label (stringp provider-label)
                            (not (string-empty-p provider-label))))
           (header (if have-label
                       (format
                        (concat "This message is a resumed continuation of an "
                                "earlier %s session -- the same ongoing "
                                "conversation, not a new one.")
                        provider-label)
                     (concat "This message is a resumed continuation of an "
                             "earlier agent session -- the same ongoing "
                             "conversation, not a new one.")))
           (lines (list header
                        (concat "Everything before this point already "
                                "happened; you are picking the thread back up.")
                        "")))
      (setq lines (append lines
                          (list (format "Source session id: %s" session-id))))
      (when (and data-path (stringp data-path) (not (string-empty-p data-path)))
        (setq lines (append lines
                            (list (format "Prior transcript: %s" data-path)))))
      (when tags
        (setq lines (append lines
                            (list (format "Source tags: %s"
                                          (mapconcat (lambda (tag) (concat "#" tag))
                                                     tags " "))))))
      (when (and last-user-message (stringp last-user-message)
                 (not (string-empty-p (string-trim last-user-message))))
        (let ((excerpt (truncate-string-to-width
                        ;; Collapse to one line so the cue stays compact.
                        (replace-regexp-in-string
                         "[ \t\n\r]+" " " (string-trim last-user-message))
                        decknix--agent-resume-primer-last-message-width
                        nil nil "...")))
          (setq lines (append lines
                              (list ""
                                    "Most recently in this conversation:"
                                    (concat "> " excerpt))))))
      (setq lines
            (append lines
                    (list
                     ""
                     (concat
                      "To restore full context, read the prior transcript file "
                      "above before continuing. If it is not accessible, ask me "
                      "for whatever context you need rather than assuming a "
                      "fresh start. Reply with a brief note of where we left "
                      "off, then wait for my next instruction."))))
      (mapconcat #'identity lines "\n"))))

(provide 'decknix-agent-resume-primer)
;;; decknix-agent-resume-primer.el ends here
