;;; decknix-agent-conv-resolve.el --- Conversation-key derivation + mergedInto resolution -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-parse "0.1") (decknix-agent-tags-store "0.1") (decknix-agent-session-cache "0.1"))
;; Keywords: agent, agent-shell, decknix, conversation

;;; Commentary:
;;
;; Canonical conversation-key resolution layer extracted from the
;; agent-shell heredoc (main-bulk).  Bridges the raw SHA-256 hash
;; from `decknix-agent-parse' with the persisted `mergedInto'
;; redirects in `decknix-agent-tags-store', and provides two
;; session-aware lookups built on top of `decknix-agent-session-cache'.
;;
;; Five entry points:
;;
;;   `decknix--agent-conversation-key'
;;       Derive the canonical conv-key from a first-message string,
;;       following any `mergedInto' redirect so that merged
;;       conversations resolve to the target.
;;   `decknix--agent-conv-resolve-key'
;;       Resolve a raw conv-key (already hashed) by following
;;       `mergedInto' redirects.  Caps at 5 hops to defend against
;;       cycles caused by misconfiguration.
;;   `decknix--agent-conversation-key-for-session'
;;       Look up the conv-key for a given SESSION-ID by reading the
;;       cached session list.
;;   `decknix--agent-conv-key-store-sessions'
;;       Given a conv-key, return the session-ids the tag store has
;;       recorded under it (the authoritative association).
;;   `decknix--agent-latest-session-id-for-conv-key'
;;       Given a conv-key, return the most recently modified matching
;;       session-id -- matching either by first-message hash or by tag-
;;       store membership, so wrapper-first sessions still resolve.
;;
;; The module sits at the cross-roads of the three already-extracted
;; agent/ packages so it can't live in any one of them; placing it
;; alongside them keeps the conversation-key story discoverable in
;; one directory.

;;; Code:

(require 'seq)
(require 'decknix-agent-parse)
(require 'decknix-agent-tags-store)
(require 'decknix-agent-session-cache)

(defun decknix--agent-conversation-key (first-message)
  "Derive the canonical conversation key from FIRST-MESSAGE.
Computes SHA-256 hash truncated to 16 chars, then follows any
mergedInto redirect in agent-sessions.json so that merged
conversations resolve to the target conversation key."
  (let ((raw (decknix--agent-conversation-key-raw first-message)))
    (if raw (decknix--agent-conv-resolve-key raw) raw)))

(defun decknix--agent-conv-resolve-key (conv-key)
  "Resolve CONV-KEY by following mergedInto redirects.
Returns the canonical conversation key.  Follows at most 5 hops
to avoid infinite loops from misconfiguration."
  (let ((store (decknix--agent-tags-read))
        (key conv-key)
        (hops 0))
    (when store
      (let ((convs (decknix--agent-tags-conversations store)))
        (while (and key (< hops 5))
          (let ((entry (gethash key convs)))
            (if (and (hash-table-p entry)
                     (gethash "mergedInto" entry))
                (progn
                  (setq key (gethash "mergedInto" entry))
                  (setq hops (1+ hops)))
              (setq hops 5))))))  ;; break
    (or key conv-key)))

(defun decknix--agent-conversation-key-for-session (session-id &optional no-block)
  "Look up the conversation key for SESSION-ID from cached session data.
With NO-BLOCK non-nil, use the non-blocking `warm-or-async' accessor: a
cold cache returns nil (no key yet) and warms in the background rather
than blocking on a synchronous scan.  Passive decoration paths (tags,
live-session recording) pass NO-BLOCK so a cold `C-c b' / sidebar never
stalls; the value self-heals via `decknix-agent-session-cache-refresh-
functions' once the async scan lands.  Action paths that need a definite
answer (resume, require-conv-key) omit it and accept the brief block."
  (let* ((sessions (if no-block
                       (decknix--agent-session-list-warm-or-async)
                     (decknix--agent-session-list)))
         (match (seq-find (lambda (s)
                            (string= (alist-get 'sessionId s) session-id))
                          sessions)))
    (when match
      (decknix--agent-conversation-key
       (alist-get 'firstUserMessage match "")))))

(defun decknix--agent-conv-key-store-sessions (conv-key)
  "Return the session-ids recorded under CONV-KEY in the tag store.
The store (`agent-sessions.json') maps each conversation key to the set
of session-ids that belong to it -- the authoritative association that
`decknix-agent-tags-store' builds and maintains.  Follows any
`mergedInto' redirect first so a merged conversation resolves to its
target.  Returns nil when CONV-KEY is nil or the store has no entry."
  (when conv-key
    (let* ((canonical (decknix--agent-conv-resolve-key conv-key))
           (store (decknix--agent-tags-read))
           (convs (and store (decknix--agent-tags-conversations store)))
           (entry (and (hash-table-p convs) (gethash canonical convs))))
      (when (hash-table-p entry)
        (gethash "sessions" entry)))))

(defun decknix--agent-latest-session-id-for-conv-key (conv-key)
  "Return the session-id of the most recently modified snapshot for CONV-KEY.
Returns nil when CONV-KEY is nil or no session matches.  Auggie writes
a fresh session file whenever a conversation is interrupted/composed,
so a single conv-key typically owns many session-ids; this picks the
latest so resume flows pull in the full recent context, not an older
snapshot.

A session matches when EITHER its first message hashes back to CONV-KEY
OR its session-id is listed under CONV-KEY in the tag store.  The store
path rescues sessions whose on-disk first message is a synthetic wrapper
-- a `/slash-command' invocation or a forked-session preamble -- that
hashes to a different key than the one the conversation was tagged with;
without it those sessions are unrecoverable at restore time (the caller
falls through to \"Cannot restore: no session ID\")."
  (when conv-key
    (let* ((sessions (decknix--agent-session-list))
           (store-sids (decknix--agent-conv-key-store-sessions conv-key))
           (matches
            (seq-filter
             (lambda (s)
               (or (and store-sids
                        (member (alist-get 'sessionId s) store-sids))
                   (let ((fm (alist-get 'firstUserMessage s "")))
                     (and (not (string-empty-p fm))
                          (string= (decknix--agent-conversation-key fm)
                                   conv-key)))))
             sessions))
           (sorted (sort (copy-sequence matches)
                         (lambda (a b)
                           (string> (or (alist-get 'modified a) "")
                                    (or (alist-get 'modified b) ""))))))
      (when sorted
        (alist-get 'sessionId (car sorted))))))

(provide 'decknix-agent-conv-resolve)
;;; decknix-agent-conv-resolve.el ends here
