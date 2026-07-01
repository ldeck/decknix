;;; decknix-agent-conv-format.el --- Pure conversation-row formatter -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, session, format

;;; Commentary:
;;
;; Pure formatter that turns a conversation group (as produced by
;; `decknix--agent-session-group-by-conversation' from
;; `decknix-agent-session-group', PR B.56) into a one-line picker row.
;; Carved out of `decknix-agent-shell-main' (main-bulk) per AGENTS.md
;; Rule 2: no buffer writes, no global mutation, just `format' /
;; `truncate-string-to-width' / `string-join' over the input plus
;; tag-store / workspace-resolve / time-formatter lookups
;; (forward-declared below; resolved at runtime by the heredoc's load
;; order).
;;
;; Public surface:
;;
;;   `decknix--agent-conversation-preview' (conv-group) -- one-line
;;       picker row for a collapsed conversation:
;;         `<sid8>  <ago>  <Nx>  <preview>[ #tags][ (N sessions)][ @ws]'
;;       Sibling of `decknix--agent-session-preview' in
;;       `decknix-agent-session-format' (B.54), with the additional
;;       `(N sessions)' count and trailing `@workspace' shortname so
;;       collapsed rows reveal both the conversation breadth and the
;;       project root at a glance.
;;
;; CONV-GROUP is the (CONV-KEY LATEST-SESSION ALL-SESSIONS) triple
;; emitted by `group-by-conversation'; the latest session drives the
;; sid / age / exchange / preview columns and the `(N sessions)'
;; suffix surfaces only when more than one snapshot is rolled up.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Forward declarations -- these symbols live in sibling agent/
;; packages and are loaded immediately before this file by the
;; heredoc, so they always resolve at call time.
(declare-function decknix--agent-tags-for-conv-key
                  "decknix-agent-tags-read" (conv-key))
(declare-function decknix--agent-workspace-for-conv-key
                  "decknix-agent-session-workspace" (conv-key))
(declare-function decknix--agent-session-time-ago
                  "decknix-agent-format" (iso-time))
(declare-function decknix-agent-provider-glyph-for-session
                  "decknix-agent-provider" (session))

(defun decknix--agent-conversation-preview (conv-group)
  "Format a one-line preview for a conversation CONV-GROUP.
CONV-GROUP is (CONV-KEY LATEST-SESSION ALL-SESSIONS).
Prefixed with the latest session's provider glyph (A/C/P).
Shows: glyph id  age  exchanges  preview [tags] (N sessions) @workspace"
  (let* ((conv-key (car conv-group))
         (latest (cadr conv-group))
         (all (caddr conv-group))
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
         (workspace (when conv-key
                      (decknix--agent-workspace-for-conv-key conv-key)))
         (ws-str (if workspace
                     (let ((abbr (abbreviate-file-name workspace)))
                       (format " @%s"
                               (if (string-match "/\\([^/]+\\)/?$" abbr)
                                   (match-string 1 abbr)
                                 abbr)))
                   ""))
         (truncated (truncate-string-to-width (or preview "") 50 nil nil "...")))
    (format "%s %-8s  %-8s  %4dx  %s%s%s%s"
            (decknix-agent-provider-glyph-for-session latest)
            (substring id 0 (min 8 (length id)))
            (if modified (decknix--agent-session-time-ago modified) "?")
            exchanges
            truncated
            tag-str
            count-str
            ws-str)))

(provide 'decknix-agent-conv-format)
;;; decknix-agent-conv-format.el ends here
