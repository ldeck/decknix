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
(declare-function decknix--agent-store-field-scan
                  "decknix-agent-conv-resolve" (convs session-id field))
(declare-function decknix--agent-current-conv-key
                  "decknix-agent-buffer-lookup" ())
(declare-function decknix--agent-current-session-id
                  "decknix-agent-session-id" ())

(defun decknix--agent-tags-for-session (session-id)
  "Return the list of tags for the conversation containing SESSION-ID.

Resolves via the session's first-message conv-key first, then falls back
to scanning the store for an entry LISTING the session-id.

The fallback is what makes a RESUMED session findable.  Its stored first
message is the resume primer (\"This message is a resumed continuation
of an earlier Claude session…\"), which since 2c0ada6 deliberately keys
no conversation -- so the conv-key lookup returns nil and this returned
nil with it.  Every resumed session therefore rendered UNTAGGED in the
`C-c s s' picker, showing the primer text as its preview, and could not
be found by searching for the tags it actually has (reported as a `day6'
session that had gone missing; it was present the whole time, just
nameless).

The session-id is stable across resumes, which is exactly why it works
where the first-message hash cannot."
  (let* ((conv-key (decknix--agent-conversation-key-for-session session-id t))
         (store (decknix--agent-tags-read))
         (convs (decknix--agent-tags-conversations store)))
    (or (when conv-key
          (let ((entry (gethash conv-key convs)))
            (when (hash-table-p entry)
              (gethash "tags" entry))))
        (and (fboundp 'decknix--agent-store-field-scan)
             (decknix--agent-store-field-scan convs session-id "tags")))))

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

(defun decknix--agent-tags-resolve (conv-key session-id)
  "Return tags for a session, by CONV-KEY or failing that SESSION-ID.

The conv-key is a hash of the first message, and the live-write and
transcript-read paths do not always agree on that string -- long prompts
truncate differently, an edited first message rehashes, and a session
resumed behind a continuation primer hashes to the primer.  Each
divergence mints a NEW conversation entry, so one session accumulates
entries: 5de16692 was found under TEN, nine of them empty.

A buffer therefore often holds a conv-key that is real but untagged,
while the tags sit under a sibling entry.  The session id is stable
across launch and resume -- `decknix-agent-session-broker' already calls
it the RELIABLE reattach link for exactly this reason -- so it is the
fallback here too.

Union rather than first-hit: when a resume splits tags across entries,
neither alone is the answer.  ONE resolver, called by every consumer:
the bug this fixes was two consumers doing it right and three not, and a
second copy of the fallback would reproduce that a level up."
  (let ((by-conv (and conv-key (decknix--agent-tags-for-conv-key conv-key)))
        (by-sid  (and session-id (decknix--agent-tags-for-session session-id))))
    (cond
     ((and by-conv by-sid)
      (delete-dups (append by-conv by-sid)))
     (by-conv)
     (by-sid))))

(defun decknix--agent-tags-for-buffer (buffer)
  "Return the tags for agent-shell BUFFER, or nil.

Resolves BUFFER's own conv-key and session id and hands both to
`decknix--agent-tags-resolve'.  Returns nil for a nil or dead BUFFER,
because callers iterate buffer lists that can go stale mid-render.

This exists because the resolver was not enough on its own.  It takes a
\(CONV-KEY SESSION-ID) pair, and almost every consumer holds a BUFFER --
sidebar rows, the header, the pickers, buffer naming.  Each would have
had to dig both values out itself, so twenty-five of them kept calling
`decknix--agent-tags-for-conv-key' and kept the bug.

Session 5de16692 is what that cost: its conv-key (523fdb64f335b839) is
real but untagged while its tags -- guidelines, policies, ai,
nurturecloud -- sit under a sibling entry keyed by session id.  The
buffer therefore named itself after its workspace, `*Claude:
nurturecloud*', and its sidebar row showed no tags at all.

One buffer-level entry point, so a consumer holding a buffer has no
reason left to ask the fragile key directly."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((conv-key (and (fboundp 'decknix--agent-current-conv-key)
                           (ignore-errors (decknix--agent-current-conv-key))))
            (sid (and (fboundp 'decknix--agent-current-session-id)
                      (ignore-errors (decknix--agent-current-session-id)))))
        (decknix--agent-tags-resolve conv-key sid)))))

(provide 'decknix-agent-tags-read)
;;; decknix-agent-tags-read.el ends here
