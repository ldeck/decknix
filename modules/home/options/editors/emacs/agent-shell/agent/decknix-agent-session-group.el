;;; decknix-agent-session-group.el --- Conversation grouping + live label -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, session, group

;;; Commentary:
;;
;; Carved out of `decknix-agent-shell-main' (main-bulk) per AGENTS.md
;; Rule 2.  Two display-prep helpers that sit between the cached
;; session list and the consult picker / sidebar header:
;;
;;   `decknix--agent-session-group-by-conversation' (sessions
;;       &optional include-hidden) -- pure aggregation.  Buckets the
;;       flat session list into conversation triples (CONV-KEY
;;       LATEST-SESSION ALL-SESSIONS), drops hidden conversations
;;       unless asked, and sorts by max(modified, lastAccessed) so
;;       any tag/rename/resume bumps the conversation to the top of
;;       the picker.
;;
;;   `decknix--agent-session-live-label' (buf) -- short label for a
;;       live agent-shell buffer in the workspace sidebar / picker
;;       Live Sessions section.  Reads the buffer-local workspace
;;       and session-id, looks up tags, returns
;;       `<buf-name>  -- <ws-short>  #tag1 #tag2'.  Read-only over
;;       the buffer; no mutation, no process state.
;;
;; Both compose four sibling helpers (forward-declared at the top of
;; this file): `decknix--agent-conversation-key' (parse), `decknix--
;; agent-conversation-hidden-p' (still in main-bulk; tag-store read),
;; `decknix--agent-conv-last-accessed' (recency), and `decknix--agent-
;; tags-for-session' (tag-store read).  Tests stub all four via
;; `cl-letf' so the suite never reaches the real JSON store.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Forward declarations -- these symbols live in sibling agent/
;; packages (and one in main-bulk) and are loaded before this file by
;; the heredoc, so they always resolve at call time.
(declare-function decknix--agent-conversation-key
                  "decknix-agent-conv-resolve" (first-message))
(declare-function decknix--agent-conversation-hidden-p
                  "decknix-agent-shell-main" (conv-key))
(declare-function decknix--agent-conv-last-accessed
                  "decknix-agent-conv-recency" (conv-key))
(declare-function decknix--agent-tags-for-session
                  "decknix-agent-tags-read" (session-id))

;; Buffer-local defvars owned by `decknix-agent-shell-main'; declared
;; here so the byte-compiler knows they are special variables that we
;; read via `buffer-local-value' / `with-current-buffer'.
(defvar decknix--agent-session-workspace)
(defvar decknix--agent-auggie-session-id)

(defun decknix--agent-session-group-by-conversation
    (sessions &optional include-hidden)
  "Group SESSIONS by conversation (shared firstUserMessage).
Returns a list of (CONV-KEY LATEST-SESSION ALL-SESSIONS) triples,
sorted by most recently interacted first.

Hidden conversations (marked with hidden=true in agent-sessions.json)
are excluded unless INCLUDE-HIDDEN is non-nil.  Hidden sessions are
typically background/automated sessions like git hook commit reviews.

Inter-group sort uses max(session.modified, conversation.lastAccessed)
so that tag/rename/resume operations bump a conversation to the top,
not just augment writing to the session file."
  (let ((groups (make-hash-table :test 'equal)))
    (dolist (s sessions)
      (let* ((first-msg (alist-get 'firstUserMessage s ""))
             (conv-key (decknix--agent-conversation-key first-msg)))
        (when (and conv-key
                   (or include-hidden
                       (not (decknix--agent-conversation-hidden-p conv-key))))
          (let ((existing (gethash conv-key groups)))
            (puthash conv-key (cons s existing) groups)))))
    ;; Build result: (conv-key latest-session all-sessions)
    (let (result)
      (maphash (lambda (key sessions-list)
                 (let ((sorted (sort (copy-sequence sessions-list)
                                    (lambda (a b)
                                      (string> (or (alist-get 'modified a) "")
                                               (or (alist-get 'modified b) ""))))))
                   (push (list key (car sorted) sorted) result)))
               groups)
      ;; Sort by max(session.modified, lastAccessed) — any interaction
      ;; with a conversation (tagging, renaming, resuming) counts.
      (sort result (lambda (a b)
                     (let* ((mod-a (or (alist-get 'modified (cadr a)) ""))
                            (mod-b (or (alist-get 'modified (cadr b)) ""))
                            (acc-a (or (decknix--agent-conv-last-accessed (car a)) ""))
                            (acc-b (or (decknix--agent-conv-last-accessed (car b)) ""))
                            (eff-a (if (string> acc-a mod-a) acc-a mod-a))
                            (eff-b (if (string> acc-b mod-b) acc-b mod-b)))
                       (string> eff-a eff-b)))))))

(defun decknix--agent-session-live-label (buf)
  "Build a display label for live agent-shell buffer BUF."
  (let* ((ws (buffer-local-value
              'decknix--agent-session-workspace buf))
         (ws-short (when ws
                     (file-name-nondirectory
                      (directory-file-name ws))))
         (tags (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (when (and (boundp 'decknix--agent-auggie-session-id)
                              decknix--agent-auggie-session-id)
                     (decknix--agent-tags-for-session
                      decknix--agent-auggie-session-id)))))
         (tag-str (when tags
                    (mapconcat (lambda (tg) (format "#%s" tg))
                               tags " ")))
         (detail (string-join (delq nil (list ws-short tag-str)) "  ")))
    (format "%s%s"
            (buffer-name buf)
            (if (string-empty-p detail) ""
              (format "  — %s" detail)))))

(provide 'decknix-agent-session-group)
;;; decknix-agent-session-group.el ends here
