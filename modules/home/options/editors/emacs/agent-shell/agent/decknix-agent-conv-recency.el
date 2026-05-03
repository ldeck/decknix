;;; decknix-agent-conv-recency.el --- Per-conversation lastAccessed stamp -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, recency

;;; Commentary:
;;
;; Tiny persistence pair carved out of `decknix-agent-shell-main'
;; (main-bulk) into the same `agent-shell/agent/' cluster as
;; `decknix-agent-tags-store' / `-link-store' / `-conv-resolve' /
;; `-session-model' / `-session-workspace'.  Owns the two
;; primitives that mediate the `lastAccessed' field in
;; `~/.config/decknix/agent-sessions.json' so any user-facing
;; operation (tag, rename, resume, create) can bump a
;; conversation's recency for the conversation-grouped picker's
;; sort.
;;
;; Two entry points:
;;
;;   `decknix--agent-conv-touch'
;;       Stamps `lastAccessed' on CONV-KEY's entry with an ISO
;;       timestamp (UTC).  No-op when CONV-KEY is nil or no entry
;;       exists for it -- the touch never auto-creates an entry,
;;       since recency only matters for conversations the system
;;       has already learned about.
;;
;;   `decknix--agent-conv-last-accessed'
;;       Returns the `lastAccessed' string for CONV-KEY, or nil
;;       (when conv-key is nil, the entry is missing, or the
;;       field is absent).  Two call sites in main-bulk use the
;;       value as a string-comparison sort key for the
;;       conversation-grouped picker.
;;
;; AGENTS.md Rule 2 keeps the call sites in main-bulk -- the
;; `decknix--agent-conv-touch' is invoked from session-creation /
;; tag / resume flows that own the surrounding side-effects, and
;; the `last-accessed' lookup is embedded inside a `sort'
;; comparator.  This module only owns the pure persistence pair.

;;; Code:

;; Forward declarations for the tags-store accessors this module
;; relies on.  They live in `decknix-agent-tags-store-el', which
;; is loaded earlier in the heredoc -- declaring them here keeps
;; the byte-compile warning-clean without taking a hard
;; dependency in `packageRequires' (sibling .el files in the same
;; `src' dir resolve via trivialBuild's load-path).
(declare-function decknix--agent-tags-read "decknix-agent-tags-store")
(declare-function decknix--agent-tags-write "decknix-agent-tags-store" (store))
(declare-function decknix--agent-tags-conversations
                  "decknix-agent-tags-store" (store))

(defun decknix--agent-conv-touch (conv-key)
  "Stamp lastAccessed on CONV-KEY so it sorts to the top.
Called by user-facing operations (tag, rename, resume, create)
so that any interaction with a conversation bumps its recency,
not just augment writing to the session file."
  (when conv-key
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (gethash conv-key convs)))
      (when entry
        (puthash "lastAccessed"
                 (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t)
                 entry)
        (decknix--agent-tags-write store)))))

(defun decknix--agent-conv-last-accessed (conv-key)
  "Return the lastAccessed timestamp for CONV-KEY, or nil."
  (when conv-key
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (gethash conv-key convs)))
      (when entry (gethash "lastAccessed" entry)))))

(provide 'decknix-agent-conv-recency)
;;; decknix-agent-conv-recency.el ends here
