;;; decknix-agent-session-format.el --- Pure session display formatters -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, session, format

;;; Commentary:
;;
;; Pure formatters that turn a session alist (as produced by
;; `decknix--agent-session-parse' from the session-cache jq feed) into
;; user-visible strings.  Carved out of `decknix-agent-shell-main'
;; (main-bulk) per AGENTS.md Rule 2: no buffer writes, no global
;; mutation, just `format' / `truncate-string-to-width' / `string-join'
;; over the input alist plus tag-store / conv-resolve / time-formatter
;; lookups (forward-declared below; resolved at runtime by the
;; heredoc's load order).
;;
;; Public surface:
;;
;;   `decknix--agent-session-preview' (session) -- one-line picker
;;       row: `<sid8>  <ago>  <Nx>  <preview>[ #tags]'.  Drives the
;;       saved-sessions section of the `consult--multi' picker and
;;       the conversation-collapsed header line.
;;
;;   `decknix--agent-session-display-name' (session) -- short buffer
;;       name preferred order: tags joined by `/' if any, else a
;;       40-char first-message preview, else the 8-char session id
;;       prefix.  Drives the `*Auggie: <name>*' rename on resume.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Forward declarations -- these symbols live in sibling agent/
;; packages and are loaded immediately before this file by the
;; heredoc, so they always resolve at call time.
(declare-function decknix--agent-tags-for-session "decknix-agent-tags-read" (session-id))
(declare-function decknix--agent-tags-for-conv-key "decknix-agent-tags-read" (conv-key))
(declare-function decknix--agent-conversation-key "decknix-agent-conv-resolve" (first-message))
(declare-function decknix--agent-session-time-ago "decknix-agent-format" (iso-time))

(defun decknix--agent-session-preview (session)
  "Format a one-line preview for a saved SESSION, including tags."
  (let* ((id (alist-get 'sessionId session))
         (modified (alist-get 'modified session))
         (exchanges (alist-get 'exchangeCount session 0))
         (first-msg (alist-get 'firstUserMessage session ""))
         (preview (car (split-string first-msg "\n" t)))
         (tags (decknix--agent-tags-for-session id))
         (tag-str (if tags (format " [%s]" (string-join tags ", ")) ""))
         (truncated (truncate-string-to-width (or preview "") 50 nil nil "...")))
    (format "%-8s  %-8s  %3dx  %s%s"
            (substring id 0 (min 8 (length id)))
            (if modified (decknix--agent-session-time-ago modified) "?")
            exchanges
            truncated
            tag-str)))

(defun decknix--agent-session-display-name (session)
  "Derive a short buffer display name from SESSION data.
Uses tags if available, otherwise truncates the first user message."
  (let* ((sid (alist-get 'sessionId session ""))
         (first-msg (alist-get 'firstUserMessage session ""))
         (conv-key (decknix--agent-conversation-key first-msg))
         (tags (when conv-key (decknix--agent-tags-for-conv-key conv-key)))
         (preview (car (split-string first-msg "\n" t))))
    (cond
     ;; If there are tags, use them as the name
     (tags (string-join tags "/"))
     ;; Otherwise use a truncated preview of the first message
     ((and preview (not (string-empty-p preview)))
      (truncate-string-to-width preview 40 nil nil "..."))
     ;; Fallback to session ID prefix
     (t (substring sid 0 (min 8 (length sid)))))))

(provide 'decknix-agent-session-format)
;;; decknix-agent-session-format.el ends here
