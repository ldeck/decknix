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
;;   `decknix--agent-session-derive-name'
;;       (tags &optional workspace branch first-message sid) -- canonical
;;       buffer name derivation shared by new-session creation and resume.
;;       Priority: tags joined by `/' > <dir>/<branch> from workspace >
;;       40-char first-message preview > 8-char session id prefix.
;;
;;   `decknix--agent-session-display-name' (session) -- thin wrapper
;;       around `decknix--agent-session-derive-name' for the resume path:
;;       extracts tags, first-message, and session-id from SESSION and
;;       delegates.  Drives the `*Auggie: <name>*' rename on resume.
;;
;;   `decknix--agent-session-canonical-buffer-name'
;;       (label tags &optional workspace branch first-message sid) --
;;       wrap `decknix--agent-session-derive-name' in the provider's
;;       `*<label>: <name>*' buffer-name shell.  Single source of truth
;;       for the full buffer name shared by new-session creation,
;;       resume, and the rename-from-tags re-canonicalisation command.

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
(declare-function decknix-agent-provider-glyph-for-session
                  "decknix-agent-provider" (session))

(defun decknix--agent-session-preview (session)
  "Format a one-line preview for a saved SESSION, including tags.
Prefixed with the session's provider glyph (A/C/P)."
  (let* ((id (alist-get 'sessionId session))
         (modified (alist-get 'modified session))
         (exchanges (alist-get 'exchangeCount session 0))
         (first-msg (alist-get 'firstUserMessage session ""))
         (preview (car (split-string first-msg "\n" t)))
         (tags (decknix--agent-tags-for-session id))
         (tag-str (if tags (format " [%s]" (string-join tags ", ")) ""))
         (truncated (truncate-string-to-width (or preview "") 50 nil nil "...")))
    (format "%s %-8s  %-8s  %3dx  %s%s"
            (decknix-agent-provider-glyph-for-session session)
            (substring id 0 (min 8 (length id)))
            (if modified (decknix--agent-session-time-ago modified) "?")
            exchanges
            truncated
            tag-str)))

(defun decknix--agent-session-derive-name
    (tags &optional workspace branch first-message sid)
  "Derive a canonical session buffer name from the given parameters.
Priority:
  1. TAGS joined by '/' (if any)
  2. <dir>/<BRANCH> or <dir> from WORKSPACE (if provided)
  3. Truncated FIRST-MESSAGE preview (40 chars, first line only)
  4. SID prefix (8 chars)

This is the single source of truth for session naming, shared by new
session creation and resume.  New sessions supply WORKSPACE and BRANCH
but not FIRST-MESSAGE (not sent yet); resumed sessions supply
FIRST-MESSAGE and SID but not workspace details."
  (let ((dir-name (when workspace
                    (file-name-nondirectory
                     (directory-file-name (expand-file-name workspace))))))
    (cond
     (tags (string-join tags "/"))
     ((and dir-name branch) (format "%s/%s" dir-name branch))
     (dir-name dir-name)
     ((and first-message
           (not (string-empty-p first-message)))
      (let ((preview (car (split-string first-message "\n" t))))
        (if (and preview (not (string-empty-p preview)))
            (truncate-string-to-width preview 40 nil nil "...")
          (if sid (substring sid 0 (min 8 (length sid))) ""))))
     (sid (substring sid 0 (min 8 (length sid))))
     (t ""))))

(defun decknix--agent-session-display-name (session)
  "Derive a short buffer display name from SESSION data.
Thin wrapper around `decknix--agent-session-derive-name' for the resume
path.  Extracts tags via conv-key lookup, plus first-message and
session-id from SESSION, then delegates.  Priority: slug (Claude sub-agent)
> tags > first-message preview > session-id prefix."
  (let* ((sid (alist-get 'sessionId session ""))
         (slug (alist-get 'slug session))
         (first-msg (alist-get 'firstUserMessage session ""))
         (conv-key (decknix--agent-conversation-key first-msg))
         (tags (when conv-key (decknix--agent-tags-for-conv-key conv-key))))
    (if (and (stringp slug) (not (string-empty-p slug)))
        slug
      (decknix--agent-session-derive-name tags nil nil first-msg sid))))

(defun decknix--agent-session-canonical-buffer-name
    (label tags &optional workspace branch first-message sid)
  "Return the canonical `*LABEL: NAME*' buffer name.
LABEL is the provider's human-readable label (e.g. \"Auggie\").  NAME
is derived by `decknix--agent-session-derive-name' from TAGS with the
optional WORKSPACE / BRANCH / FIRST-MESSAGE / SID fallbacks.

This wraps the inner name in the provider buffer-name shell so the
full buffer name has one source of truth shared by new-session
creation, resume, and the rename-from-tags re-canonicalisation
command.  Kept provider-agnostic (LABEL is a plain string) so the
pure formatter carries no dependency on the provider registry."
  (format "*%s: %s*"
          label
          (decknix--agent-session-derive-name
           tags workspace branch first-message sid)))

(provide 'decknix-agent-session-format)
;;; decknix-agent-session-format.el ends here
