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
;; Four entry points:
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
;;   `decknix--agent-latest-session-id-for-conv-key'
;;       Inverse of the above: given a conv-key, return the most
;;       recently modified session-id that hashes back to it.
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

(defun decknix--agent-conversation-key-for-session (session-id)
  "Look up the conversation key for SESSION-ID from cached session data."
  (let* ((sessions (decknix--agent-session-list))
         (match (seq-find (lambda (s)
                            (string= (alist-get 'sessionId s) session-id))
                          sessions)))
    (when match
      (decknix--agent-conversation-key
       (alist-get 'firstUserMessage match "")))))

(defun decknix--agent-latest-session-id-for-conv-key (conv-key)
  "Return the session-id of the most recently modified snapshot for CONV-KEY.
Returns nil when CONV-KEY is nil or no session matches.  Auggie writes
a fresh session file whenever a conversation is interrupted/composed,
so a single conv-key typically owns many session-ids; this picks the
latest so resume flows pull in the full recent context, not an older
snapshot."
  (when conv-key
    (let* ((sessions (decknix--agent-session-list))
           (matches
            (seq-filter
             (lambda (s)
               (let ((fm (alist-get 'firstUserMessage s "")))
                 (and (not (string-empty-p fm))
                      (string= (decknix--agent-conversation-key fm)
                               conv-key))))
             sessions))
           (sorted (sort (copy-sequence matches)
                         (lambda (a b)
                           (string> (or (alist-get 'modified a) "")
                                    (or (alist-get 'modified b) ""))))))
      (when sorted
        (alist-get 'sessionId (car sorted))))))

(provide 'decknix-agent-conv-resolve)
;;; decknix-agent-conv-resolve.el ends here
