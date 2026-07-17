;;; decknix-agent-tags-read.el --- Tags accessors for sessions / conversations -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, tags

;;; Commentary:
;;
;; Two read-only accessors for the per-conversation `tags' list
;; in `~/.config/decknix/agent-sessions.json'.  Sister of the
;; existing `decknix-agent-tags-store' (which owns load / save /
;; conversations) and the persistence pairs `decknix-agent-
;; session-{model,workspace}' / `decknix-agent-conv-recency'.
;;
;; Three entry points:
;;
;;   `decknix--agent-tags-for-session'
;;       Resolves SESSION-ID -> CONV-KEY via
;;       `decknix--agent-conversation-key-for-session', then
;;       returns the tags list for that conversation (or nil).
;;
;;   `decknix--agent-tags-for-conv-key'
;;       Direct accessor when CONV-KEY is already in hand.
;;       Returns the tags list (or nil).
;;
;;   `decknix--agent-tags-all'
;;       Aggregation across all conversations -- returns a
;;       sorted list of unique tag strings.  Used by the
;;       interactive verbs that prompt with completing-read over
;;       the existing tag vocabulary (rename / remove / filter
;;       global pickers).
;;
;; All three are pure with respect to the store -- they read but
;; do not mutate.  The interactive verbs that *write* tags
;; (`decknix--agent-tag-add' / `-tag-remove' / `-tags-clear' /
;; `-tags-rename', etc.) stay in main-bulk per AGENTS.md Rule 2
;; -- they refresh the sidebar buffer and may call into other
;; UI machinery.

;;; Code:

(require 'cl-lib)

;; Forward declarations for the tags-store accessors and the
;; session->conv-key resolver this module depends on.  All three
;; live in sibling modules under `agent-shell/agent/' loaded
;; earlier in the heredoc -- declaring them here keeps the
;; byte-compile warning-clean without taking a hard dependency
;; in `packageRequires' (sibling .el files in the same `src' dir
;; resolve via trivialBuild's load-path).
(declare-function decknix--agent-tags-read "decknix-agent-tags-store")
(declare-function decknix--agent-tags-conversations
                  "decknix-agent-tags-store" (store))
(declare-function decknix--agent-conversation-key-for-session
                  "decknix-agent-conv-resolve" (session-id &optional no-block))

(defun decknix--agent-tags-for-session (session-id)
  "Return the list of tags for the conversation containing SESSION-ID."
  (let* ((conv-key (decknix--agent-conversation-key-for-session session-id t))
         (store (decknix--agent-tags-read))
         (convs (decknix--agent-tags-conversations store)))
    (when conv-key
      (let ((entry (gethash conv-key convs)))
        (when (hash-table-p entry)
          (gethash "tags" entry))))))

(defun decknix--agent-tags-for-conv-key (conv-key)
  "Return the list of tags for conversation CONV-KEY."
  (let* ((store (decknix--agent-tags-read))
         (convs (decknix--agent-tags-conversations store)))
    (let ((entry (gethash conv-key convs)))
      (when (hash-table-p entry)
        (gethash "tags" entry)))))

(defun decknix--agent-tags-all ()
  "Return a sorted list of all unique tags across all conversations."
  (let* ((store (decknix--agent-tags-read))
         (convs (decknix--agent-tags-conversations store))
         (all-tags nil))
    (maphash (lambda (_key entry)
               (when (hash-table-p entry)
                 (dolist (tag (gethash "tags" entry))
                   (cl-pushnew tag all-tags :test #'string=))))
             convs)
    (sort all-tags #'string<)))

(provide 'decknix-agent-tags-read)
;;; decknix-agent-tags-read.el ends here
