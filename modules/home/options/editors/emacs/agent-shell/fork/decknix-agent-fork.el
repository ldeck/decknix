;;; decknix-agent-fork.el --- Fork context hand-off message -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, session, fork

;;; Commentary:
;;
;; Pure helpers for `decknix-agent-session-fork' (C-c s f / C-c A f).
;;
;; When a session is forked the new session may run a *different* agent
;; provider than the source.  To give the new agent a foothold on the
;; prior context, the fork command auto-sends a "context hand-off"
;; message as the new session's first user message.  This module builds
;; that message from already-resolved primitives so it can be exercised
;; by ERT without touching live buffers, the provider registry, or the
;; filesystem.
;;
;; Two pure functions, per AGENTS.md Rule 2 (interactive orchestration,
;; provider lookups, `agent-shell-subscribe-to', and `shell-maker-submit'
;; all stay in main-bulk):
;;
;;   (decknix--agent-fork-source-data-path SESSIONS-DIR EXTENSION SESSION-ID)
;;     -> best-effort filesystem path to the source transcript, or nil.
;;
;;   (decknix--agent-fork-handoff-message LABEL SESSION-ID DATA-PATH TAGS)
;;     -> plain-text first-message naming the source provenance.
;;
;; The message embeds the source SESSION-ID so two forks of *different*
;; sources derive distinct conversation keys (the key is the SHA of the
;; first message); forks of the same source intentionally share identity.

;;; Code:

(defun decknix--agent-fork-source-data-path (sessions-dir extension session-id)
  "Return a best-effort path to the source session transcript.

SESSIONS-DIR is the source provider's session directory (already
expanded by the caller).  EXTENSION is the transcript file extension
\(e.g. \".json\"); nil or empty yields the bare id.  SESSION-ID is the
source session id.

Returns nil when SESSION-ID is nil or empty, since without it no
specific file can be named.  The path is best-effort: some providers
\(e.g. Claude Code) nest transcripts under a project hash, so the
returned path still locates the directory and id even when the exact
on-disk filename differs."
  (when (and session-id (stringp session-id) (not (string-empty-p session-id)))
    (let ((file (concat session-id (or extension ""))))
      (if (and sessions-dir (stringp sessions-dir)
               (not (string-empty-p sessions-dir)))
          (file-name-concat sessions-dir file)
        file))))

(defun decknix--agent-fork-handoff-message (provider-label session-id
                                                           data-path tags)
  "Build the context hand-off message for a forked agent session.

PROVIDER-LABEL is the human-readable label of the SOURCE session's
provider (e.g. \"Auggie\"); nil degrades to generic phrasing.
SESSION-ID is the source session id.  DATA-PATH is the best-effort
location of the source transcript (see
`decknix--agent-fork-source-data-path').  TAGS is the list of
source-session tag strings.

Returns a plain-text message suitable for sending as the new session's
first user message.  Detail lines for unknown fields (nil / empty) are
omitted so the message degrades gracefully when metadata is missing.
Plain text only — the comint buffer renders markdown literally and the
prompt should read cleanly to any provider."
  (let* ((have-label (and provider-label (stringp provider-label)
                          (not (string-empty-p provider-label))))
         (header (if have-label
                     (format
                      "This session was forked from an existing %s agent session."
                      provider-label)
                   "This session was forked from an existing agent session."))
         (lines (list header "")))
    (when have-label
      (setq lines (append lines
                          (list (format "Source provider: %s" provider-label)))))
    (when (and session-id (stringp session-id) (not (string-empty-p session-id)))
      (setq lines (append lines
                          (list (format "Source session id: %s" session-id)))))
    (when (and data-path (stringp data-path) (not (string-empty-p data-path)))
      (setq lines (append lines
                          (list (format "Source session data: %s" data-path)))))
    (when tags
      (setq lines (append lines
                          (list (format "Source tags: %s"
                                        (mapconcat (lambda (tag) (concat "#" tag))
                                                   tags " "))))))
    (setq lines
          (append lines
                  (list
                   ""
                   (concat
                    "For continuity you may read the source session data "
                    "file above to load the earlier conversation context "
                    "before continuing. If it is not accessible, treat this "
                    "as a fresh start and ask me for any context you need."))))
    (mapconcat #'identity lines "\n")))

(provide 'decknix-agent-fork)
;;; decknix-agent-fork.el ends here
