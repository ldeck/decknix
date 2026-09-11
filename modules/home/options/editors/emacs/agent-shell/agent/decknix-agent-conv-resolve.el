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

(declare-function decknix--agent-session-file
                  "decknix-agent-session-history" (session-id &optional provider-id))
(defvar decknix-agent-provider-registry)

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
      (decknix--agent-session-conv-key match))))

(defun decknix--agent-session-conv-key (session)
  "Return the conversation key for SESSION (a session alist), or nil.

Hashes the session's own first message first, then falls back to
scanning the store for an entry LISTING its session-id.

The fallback is not an optimisation, it is the only thing that works for
a RESUMED or FORKED session.  Their first messages are the resume primer
and the fork preamble, and since 2c0ada6 neither keys a conversation --
by design, because those preambles are identical across sessions and
used to collapse them all into one bucket.  Deriving a session's
conversation from its first message therefore yields nil for exactly
those sessions, and every caller that did so lost them:

    tags-for-session         the picker row showed no tags
    session-display-name     the buffer had no name
    saved-source ws filter   the session vanished from `C-c s s'

The session-id is stable across resume and fork, which is precisely why
the store scan succeeds where the hash cannot.

Callers holding a session alist should use THIS rather than
`decknix--agent-conversation-key' on the raw first message."
  (when session
    (let ((fm (alist-get 'firstUserMessage session ""))
          (sid (alist-get 'sessionId session)))
      (or (and fm (decknix--agent-conversation-key fm))
          (and sid (stringp sid) (not (string-empty-p sid))
               (decknix--agent-conv-key-for-session-id sid))))))

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

(defun decknix--agent-session-mtime-for-sid (session-id)
  "Return the modification time of SESSION-ID's transcript, or nil.
Searches every registered provider, because a conversation's store entry
records session ids without saying which backend wrote them."
  (when (stringp session-id)
    (let ((best nil))
      (dolist (entry (if (boundp 'decknix-agent-provider-registry)
                         decknix-agent-provider-registry
                       nil)
                     best)
        (let* ((p-id (car entry))
               (file (ignore-errors
                       (decknix--agent-session-file session-id p-id))))
          (when (and file (stringp file) (not (string-empty-p file))
                     (file-exists-p file))
            (let ((mt (float-time (file-attribute-modification-time
                                   (file-attributes file)))))
              (when (or (null best) (> mt best)) (setq best mt)))))))))

(defun decknix--agent-newest-session-id (session-ids)
  "Return the most recently modified of SESSION-IDS, or nil.

Dates each candidate from its transcript rather than trusting its
position.  Position was the original guess and it resumed the WRONG
session: `conn/contact/ghost' records its sessions newest-first, so
taking the last one reopened the previous day's transcript and the agent
continued from stale assumptions.

Falls back to the FIRST id when nothing can be dated, since the store
records newest-first, which makes the head the better guess than the
tail."
  (let ((best nil) (best-mt nil))
    (dolist (sid session-ids)
      (let ((mt (decknix--agent-session-mtime-for-sid sid)))
        (when (and mt (or (null best-mt) (> mt best-mt)))
          (setq best sid best-mt mt))))
    (or best (car session-ids))))

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
falls through to \"Cannot restore: no session ID\").

When the scan yields nothing at all, falls back to the LAST session id the
store records for CONV-KEY.  The scan is an index of transcript files and
is cached; the store is, per
`decknix--agent-conv-key-store-sessions', the authoritative association.
Gating on the scan therefore made resume depend on cache freshness while
the scan could only ever confirm what the store already said.

That cost a live session its buffer.  On 2026-09-11 session c9935439 sat
behind a healthy broker (seven days uptime) and did not come back after a
switch, nor appear in the `C-c s s' picker: it was missing from the CACHED
session list, and a synchronous refresh produced the same 117 entries with
it present.  Reattach resolved the conv-key and the broker key correctly,
then stopped here on a nil.

The scan still wins when it has an answer: it carries `modified'
timestamps.  The store fallback dates each candidate from its transcript
rather than trusting list order -- see
`decknix--agent-newest-session-id'."
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
      (or (when sorted (alist-get 'sessionId (car sorted)))
          (decknix--agent-newest-session-id store-sids)))))

;; ── session-id metadata fallback (heals conv-key fragmentation) ──────
;;
;; The conv-key is derived from the first message, which the live write path
;; (comint input) and the transcript-read path hash differently for long or
;; edited prompts — so one conversation scatters across many conv-key store
;; entries and its tags/model/mode/workspace/brokerKey land on whichever key
;; was current at write time.  The session-id is stable across launch and
;; resume, so when a conv-key lookup misses we fall back to it: scan the conv
;; entries listing the session-id and return the requested FIELD from one that
;; carries it.  Mirrors `decknix--agent-broker-scan-key-for-session-id'.

(defun decknix--agent-store-field-scan (convs session-id field)
  "Pure: return non-empty FIELD from a CONVS entry listing SESSION-ID, or nil.
CONVS is the conversations hash-table (conv-key -> entry hash-table); FIELD
is a store key string (e.g. \"tags\", \"model\", \"sessionMode\").  Scans by
sorted conv-key for deterministic tie-breaking; skips nil / empty-sequence
values so an untagged fragment never shadows a tagged one."
  (when (and (hash-table-p convs) session-id field)
    (let ((keys nil))
      (maphash (lambda (k _) (push k keys)) convs)
      (catch 'hit
        (dolist (k (sort keys #'string<))
          (let ((entry (gethash k convs)))
            (when (and (hash-table-p entry)
                       (member session-id (gethash "sessions" entry)))
              (let ((val (gethash field entry)))
                (when (and val (or (not (sequencep val)) (> (length val) 0)))
                  (throw 'hit val))))))
        nil))))

(defun decknix--agent-conv-key-scan-for-session-id (convs session-id &optional anchored-p)
  "Pure: a conv-key whose CONVS entry lists SESSION-ID, or nil.

Prefers an entry carrying metadata (brokerKey/tags/model/mode) so a WRITE
reuses the conversation's established key instead of minting a fresh
fragment.  Among those, precedence is:

  1. ANCHORED   ANCHORED-P, when supplied, is a predicate on a conv-key
                that answers whether the key is the hash of one of its
                members' own first messages -- i.e. a real conversation
                rather than an accretion container.  Ground truth, so it
                wins outright.
  2. RECENCY    otherwise the largest `lastAccessed' (ISO-8601, so
                `string>' orders it).  Where you last worked is a better
                guess than nothing.
  3. SORTED KEY otherwise the lexicographically smallest key, purely so
                the answer is stable across calls.

A session can legitimately be listed under several conversations, and
43 of 371 in one live store were -- 12 of them claimed by more than one
TAGGED conversation, which is what decides the tags the session displays
under.  Ordering by conv-key alone made that decision arbitrary: session
122adc26 belonged to `756afa19' (day6, dos, log, july, 28) and was also
claimed by `2a94df56' (fix); `2' sorts before `7', so it showed as `fix'
and the day6 conversation could not be found.  `fix' was an accretion
container -- all five of its members were resume primers, which hash
alike -- while day6 was anchored, so the anchor test is what separates
them, and it has to outrank recency because the container had been
touched more recently than the real conversation."
  (when (and (hash-table-p convs) session-id)
    (let ((keys nil) (meta nil) (any nil))
      (maphash (lambda (k _) (push k keys)) convs)
      (dolist (k (sort keys #'string<))
        (let ((e (gethash k convs)))
          (when (and (hash-table-p e)
                     (member session-id (gethash "sessions" e)))
            (unless any (setq any k))
            (when (or (gethash "brokerKey" e) (gethash "tags" e)
                      (gethash "model" e) (gethash "mode" e))
              (push k meta)))))
      (setq meta (nreverse meta))       ; back into sorted-key order
      (or (and meta
               (or
                ;; 1. anchored
                (and anchored-p (seq-find anchored-p meta))
                ;; 2. most recently accessed
                (car (sort (copy-sequence meta)
                           (lambda (a b)
                             (string> (or (gethash "lastAccessed" (gethash a convs)) "")
                                      (or (gethash "lastAccessed" (gethash b convs)) "")))))
                ;; 3. sorted key
                (car meta)))
          any))))

(defun decknix--agent-conv-key-for-session-id (session-id)
  "Return an existing conv-key that owns SESSION-ID in the tag store, or nil.
Lets the write path reuse a conversation's established key instead of
minting a fresh fragment from a diverging first-message hash."
  (when (and session-id (stringp session-id) (not (string-empty-p session-id)))
    (decknix--agent-conv-key-scan-for-session-id
     (decknix--agent-tags-conversations (decknix--agent-tags-read))
     session-id)))

(defun decknix--agent-store-field-for-session-id (session-id field)
  "Return store FIELD for SESSION-ID via the tag store, or nil.
Stable fallback for when the conv-key lookup misses because the
conversation fragmented across conv-keys (see
`decknix--agent-store-field-scan')."
  (when (and session-id (stringp session-id) (not (string-empty-p session-id)))
    (decknix--agent-store-field-scan
     (decknix--agent-tags-conversations (decknix--agent-tags-read))
     session-id field)))

(provide 'decknix-agent-conv-resolve)
;;; decknix-agent-conv-resolve.el ends here
