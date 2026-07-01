;;; decknix-agent-grep-format.el --- Pure formatters for the session-grep picker -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, session, grep, format

;;; Commentary:
;;
;; Pure formatters that turn a session alist (or a list of them, with
;; conversation grouping) into the candidate strings consumed by
;; `decknix-agent-session-grep' (M-x C-c A g).  Carved out of
;; `decknix-agent-shell-main' (main-bulk) per AGENTS.md Rule 2: no
;; buffer writes, no global mutation, no process state -- just
;; `format' / `truncate-string-to-width' / `string-join' over the
;; input alist plus four sibling lookups (forward-declared below;
;; resolved at runtime by the heredoc's load order).
;;
;; Public surface:
;;
;;   `decknix--agent-session-grep-candidate' (session) -- one row of
;;       the expanded grep results (one entry per session snapshot):
;;       `<sid8>  <ago>  <Nx>[ #tags]  <80-char preview>'.  Sibling
;;       of `decknix--agent-session-preview' in `session-format' --
;;       same shape, wider preview cap (80 vs 50) so grep matches
;;       further into the message stay visible.
;;
;;   `decknix--agent-session-grep-build-entries' (sessions expand)
;;       -- the consult candidate list builder.  EXPAND non-nil
;;       fans out one row per session via `grep-candidate' above;
;;       nil collapses by conversation via `group-by-conversation'
;;       (B.56) and renders one row per conversation with a
;;       trailing `(N sessions)' count when there's more than one.
;;
;; Both return cons cells `(STRING . (session . SESSION-ALIST))' so
;; the consult :action handler can recover the source alist for
;; downstream actions (resume, jump-to-match landing, etc.).

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Forward declarations -- these symbols live in sibling agent/
;; packages and are loaded immediately before this file by the
;; heredoc, so they always resolve at call time.
(declare-function decknix--agent-tags-for-session
                  "decknix-agent-tags-read" (session-id))
(declare-function decknix--agent-tags-for-conv-key
                  "decknix-agent-tags-read" (conv-key))
(declare-function decknix--agent-session-time-ago
                  "decknix-agent-format" (iso-time))
(declare-function decknix--agent-session-group-by-conversation
                  "decknix-agent-session-group"
                  (sessions &optional include-hidden))
(declare-function decknix-agent-provider-glyph-for-session
                  "decknix-agent-provider" (session))

(defun decknix--agent-session-grep-candidate (session)
  "Build a candidate string for SESSION in grep results.
Prefixed with the session's provider glyph (A/C/P)."
  (let* ((id (alist-get 'sessionId session))
         (modified (alist-get 'modified session))
         (exchanges (alist-get 'exchangeCount session 0))
         (first-msg (alist-get 'firstUserMessage session ""))
         (preview (car (split-string first-msg "\n" t)))
         (tags (decknix--agent-tags-for-session id))
         (tag-str (if tags (format " [%s]" (string-join tags ", ")) ""))
         (time-ago (if modified
                       (decknix--agent-session-time-ago modified)
                     "?"))
         (msg-preview (truncate-string-to-width
                       (or preview "") 80 nil nil "...")))
    (format "%s %-8s  %-8s  %4dx%s  %s"
            (decknix-agent-provider-glyph-for-session session)
            (substring id 0 (min 8 (length id)))
            time-ago exchanges tag-str msg-preview)))

(defun decknix--agent-session-grep-build-entries (sessions expand)
  "Build candidate entries from SESSIONS for grep results.
If EXPAND is non-nil, show all individual sessions.
Otherwise collapse by conversation."
  (if expand
      (mapcar (lambda (session)
                (cons (decknix--agent-session-grep-candidate session)
                      (cons 'session session)))
              sessions)
    (let ((conv-groups
           (decknix--agent-session-group-by-conversation sessions)))
      (mapcar (lambda (group)
                (let* ((conv-key (car group))
                       (latest (cadr group))
                       (all (caddr group))
                       (session-count (length all))
                       (id (alist-get 'sessionId latest))
                       (modified (alist-get 'modified latest))
                       (exchanges (alist-get 'exchangeCount latest 0))
                       (first-msg (alist-get 'firstUserMessage latest ""))
                       (preview (car (split-string first-msg "\n" t)))
                       (tags (decknix--agent-tags-for-conv-key conv-key))
                       (tag-str (if tags (format " [%s]" (string-join tags ", ")) ""))
                       (count-str (if (> session-count 1)
                                      (format " (%d sessions)" session-count)
                                    ""))
                       (time-ago (if modified
                                     (decknix--agent-session-time-ago modified)
                                   "?"))
                       (msg-preview (truncate-string-to-width
                                     (or preview "") 80 nil nil "...")))
                  (cons (format "%s %-8s  %-8s  %4dx%s%s  %s"
                                (decknix-agent-provider-glyph-for-session latest)
                                (substring id 0 (min 8 (length id)))
                                time-ago exchanges tag-str count-str
                                msg-preview)
                        (cons 'session latest))))
              conv-groups))))

(provide 'decknix-agent-grep-format)
;;; decknix-agent-grep-format.el ends here
