;;; decknix-agent-conv-resolve-test.el --- Tests for conv-key resolution -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-conv-resolve "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix-agent-conv-resolve' --
;; the conversation-key derivation + mergedInto resolution layer.
;;
;; Strategy: the module wires together three already-extracted
;; siblings (parse / tags-store / session-cache).  Tests stub the
;; sibling entry points via `cl-letf' so behaviour is exercised
;; without an actual `~/.config/decknix/agent-sessions.json' file
;; or a populated session list.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-conv-resolve)

(defun decknix-agent-conv-resolve-test--make-store (alist)
  "Build a v2 store with conversations from ALIST.
ALIST is a list of (CONV-KEY . MERGED-INTO-KEY-OR-NIL) cells."
  (let ((store (make-hash-table :test #'equal))
        (convs (make-hash-table :test #'equal)))
    (puthash "version" 2 store)
    (puthash "conversations" convs store)
    (dolist (cell alist)
      (let ((entry (make-hash-table :test #'equal)))
        (when (cdr cell)
          (puthash "mergedInto" (cdr cell) entry))
        (puthash (car cell) entry convs)))
    store))

;; -- conv-resolve-key --------------------------------------------

(ert-deftest decknix-agent-conv-resolve--no-store-returns-input ()
  "When the tag store is empty, the raw key is returned unchanged."
  (cl-letf (((symbol-function 'decknix--agent-tags-read)
             (lambda () nil)))
    (should (equal "abc123" (decknix--agent-conv-resolve-key "abc123")))))

(ert-deftest decknix-agent-conv-resolve--no-redirect-returns-input ()
  "An entry with no `mergedInto' key resolves to itself."
  (let ((store (decknix-agent-conv-resolve-test--make-store
                '(("alpha" . nil)))))
    (cl-letf (((symbol-function 'decknix--agent-tags-read)
               (lambda () store)))
      (should (equal "alpha" (decknix--agent-conv-resolve-key "alpha"))))))

(ert-deftest decknix-agent-conv-resolve--single-redirect-followed ()
  "A single mergedInto hop is followed to the target."
  (let ((store (decknix-agent-conv-resolve-test--make-store
                '(("alpha" . "beta")
                  ("beta"  . nil)))))
    (cl-letf (((symbol-function 'decknix--agent-tags-read)
               (lambda () store)))
      (should (equal "beta" (decknix--agent-conv-resolve-key "alpha"))))))

(ert-deftest decknix-agent-conv-resolve--chained-redirects-followed ()
  "Multiple chained redirects resolve to the final target."
  (let ((store (decknix-agent-conv-resolve-test--make-store
                '(("a" . "b")
                  ("b" . "c")
                  ("c" . nil)))))
    (cl-letf (((symbol-function 'decknix--agent-tags-read)
               (lambda () store)))
      (should (equal "c" (decknix--agent-conv-resolve-key "a"))))))

(ert-deftest decknix-agent-conv-resolve--cycle-bounded-by-hop-cap ()
  "A cycle of redirects terminates -- the 5-hop cap prevents an infinite loop."
  (let ((store (decknix-agent-conv-resolve-test--make-store
                '(("a" . "b") ("b" . "a")))))
    (cl-letf (((symbol-function 'decknix--agent-tags-read)
               (lambda () store)))
      ;; Just assert termination; the exact landing key is implementation
      ;; detail.  Both "a" and "b" are valid resting points.
      (should (member (decknix--agent-conv-resolve-key "a") '("a" "b"))))))

;; -- conversation-key (raw -> resolve) ---------------------------

(ert-deftest decknix-agent-conv-resolve--key-returns-nil-for-empty-input ()
  "An empty / nil first-message yields nil."
  (cl-letf (((symbol-function 'decknix--agent-conversation-key-raw)
             (lambda (_fm) nil))
            ((symbol-function 'decknix--agent-tags-read)
             (lambda () nil)))
    (should-not (decknix--agent-conversation-key ""))))

(ert-deftest decknix-agent-conv-resolve--key-passes-through-when-no-redirect ()
  "Hash from `parse' is returned unchanged when no mergedInto applies."
  (cl-letf (((symbol-function 'decknix--agent-conversation-key-raw)
             (lambda (_fm) "raw-key"))
            ((symbol-function 'decknix--agent-tags-read)
             (lambda () nil)))
    (should (equal "raw-key" (decknix--agent-conversation-key "hi")))))

(ert-deftest decknix-agent-conv-resolve--key-follows-merged-into ()
  "Hash from `parse' is rewritten through `mergedInto'."
  (let ((store (decknix-agent-conv-resolve-test--make-store
                '(("raw-key" . "merged-target")
                  ("merged-target" . nil)))))
    (cl-letf (((symbol-function 'decknix--agent-conversation-key-raw)
               (lambda (_fm) "raw-key"))
              ((symbol-function 'decknix--agent-tags-read)
               (lambda () store)))
      (should (equal "merged-target"
                     (decknix--agent-conversation-key "hello"))))))

;; -- conversation-key-for-session --------------------------------

(ert-deftest decknix-agent-conv-resolve--key-for-session-misses-cleanly ()
  "Unknown SESSION-ID returns nil rather than erroring."
  (cl-letf (((symbol-function 'decknix--agent-session-list)
             (lambda () nil)))
    (should-not (decknix--agent-conversation-key-for-session "ghost"))))

(ert-deftest decknix-agent-conv-resolve--key-for-session-hashes-first-message ()
  "Found session feeds its `firstUserMessage' through `conversation-key'."
  (cl-letf (((symbol-function 'decknix--agent-session-list)
             (lambda ()
               '(((sessionId . "S1") (firstUserMessage . "hello"))
                 ((sessionId . "S2") (firstUserMessage . "world")))))
            ((symbol-function 'decknix--agent-conversation-key)
             (lambda (fm) (concat "K:" fm))))
    (should (equal "K:hello"
                   (decknix--agent-conversation-key-for-session "S1")))
    (should (equal "K:world"
                   (decknix--agent-conversation-key-for-session "S2")))))

(ert-deftest decknix-agent-conv-resolve--key-for-session-blocks-by-default ()
  "Without NO-BLOCK the resolver uses the blocking `decknix--agent-session-list'
(the action/resume path that needs a definite answer)."
  (let ((blocking-called 0) (nonblocking-called 0))
    (cl-letf (((symbol-function 'decknix--agent-session-list)
               (lambda (&rest _) (cl-incf blocking-called) nil))
              ((symbol-function 'decknix--agent-session-list-warm-or-async)
               (lambda (&rest _) (cl-incf nonblocking-called) nil)))
      (decknix--agent-conversation-key-for-session "S1")
      (should (= blocking-called 1))
      (should (= nonblocking-called 0)))))

(ert-deftest decknix-agent-conv-resolve--key-for-session-nonblocking-with-flag ()
  "With NO-BLOCK the resolver uses the non-blocking `warm-or-async' accessor
so a cold `C-c b' / sidebar decoration never stalls on a synchronous scan."
  (let ((blocking-called 0) (nonblocking-called 0))
    (cl-letf (((symbol-function 'decknix--agent-session-list)
               (lambda (&rest _) (cl-incf blocking-called) nil))
              ((symbol-function 'decknix--agent-session-list-warm-or-async)
               (lambda (&rest _) (cl-incf nonblocking-called) nil)))
      (decknix--agent-conversation-key-for-session "S1" t)
      (should (= blocking-called 0))
      (should (= nonblocking-called 1)))))

;; -- latest-session-id-for-conv-key ------------------------------

(ert-deftest decknix-agent-conv-resolve--latest-nil-conv-key ()
  "Nil CONV-KEY short-circuits to nil."
  (should-not (decknix--agent-latest-session-id-for-conv-key nil)))

(ert-deftest decknix-agent-conv-resolve--latest-picks-newest-modified ()
  "Returns the session-id with the highest `modified' string for a conv-key."
  (cl-letf (((symbol-function 'decknix--agent-session-list)
             (lambda ()
               '(((sessionId . "old") (firstUserMessage . "x")
                  (modified . "2024-01-01T00:00:00Z"))
                 ((sessionId . "new") (firstUserMessage . "x")
                  (modified . "2025-02-02T00:00:00Z"))
                 ((sessionId . "mid") (firstUserMessage . "x")
                  (modified . "2024-06-01T00:00:00Z")))))
            ;; No store entry: exercises the pure hash-match path.  Stubbed
            ;; so the resolver's tag-store lookup does not touch the disk.
            ((symbol-function 'decknix--agent-tags-read) (lambda () nil))
            ((symbol-function 'decknix--agent-conversation-key)
             (lambda (_fm) "the-key")))
    (should (equal "new"
                   (decknix--agent-latest-session-id-for-conv-key "the-key")))))

(ert-deftest decknix-agent-conv-resolve--latest-skips-empty-first-message ()
  "Sessions with empty `firstUserMessage' are filtered out before the sort."
  (cl-letf (((symbol-function 'decknix--agent-session-list)
             (lambda ()
               '(((sessionId . "ghost") (firstUserMessage . "")
                  (modified . "2099-01-01T00:00:00Z"))
                 ((sessionId . "real") (firstUserMessage . "x")
                  (modified . "2025-01-01T00:00:00Z")))))
            ((symbol-function 'decknix--agent-tags-read) (lambda () nil))
            ((symbol-function 'decknix--agent-conversation-key)
             (lambda (_fm) "the-key")))
    (should (equal "real"
                   (decknix--agent-latest-session-id-for-conv-key "the-key")))))

;; -- conv-key-store-sessions + store-backed resolution ------------

(ert-deftest decknix-agent-conv-resolve--store-sessions-reads-and-follows-merge ()
  "`store-sessions' returns the recorded session-ids, following mergedInto,
and short-circuits on nil."
  (let ((store (make-hash-table :test #'equal))
        (convs (make-hash-table :test #'equal))
        (src (make-hash-table :test #'equal))
        (tgt (make-hash-table :test #'equal)))
    (puthash "mergedInto" "tgt" src)
    (puthash "sessions" '("s1" "s2") tgt)
    (puthash "src" src convs)
    (puthash "tgt" tgt convs)
    (puthash "conversations" convs store)
    (cl-letf (((symbol-function 'decknix--agent-tags-read) (lambda () store)))
      (should (equal '("s1" "s2")
                     (decknix--agent-conv-key-store-sessions "src")))
      (should-not (decknix--agent-conv-key-store-sessions nil)))))

(ert-deftest decknix-agent-conv-resolve--latest-matches-via-store-membership ()
  "A session whose first message hashes elsewhere still resolves when the
tag store lists its session-id under the conv-key (wrapper-first sessions:
`/slash-command' invocations, forked-session preambles)."
  (let ((store (make-hash-table :test #'equal))
        (convs (make-hash-table :test #'equal))
        (entry (make-hash-table :test #'equal)))
    (puthash "sessions" '("wrap") entry)
    (puthash "target" entry convs)
    (puthash "conversations" convs store)
    (cl-letf (((symbol-function 'decknix--agent-tags-read) (lambda () store))
              ((symbol-function 'decknix--agent-session-list)
               (lambda ()
                 '(((sessionId . "wrap")
                    (firstUserMessage . "<command-message>x</command-message>")
                    (modified . "2025-01-01T00:00:00Z")))))
              ((symbol-function 'decknix--agent-conversation-key)
               (lambda (_fm) "DIFFERENT")))
      (should (equal "wrap"
                     (decknix--agent-latest-session-id-for-conv-key "target"))))))

(ert-deftest decknix-agent-conv-resolve--latest-unions-store-and-hash-newest-wins ()
  "Store-matched and hash-matched sessions are unioned; newest modified wins."
  (let ((store (make-hash-table :test #'equal))
        (convs (make-hash-table :test #'equal))
        (entry (make-hash-table :test #'equal)))
    (puthash "sessions" '("store-old") entry)
    (puthash "k" entry convs)
    (puthash "conversations" convs store)
    (cl-letf (((symbol-function 'decknix--agent-tags-read) (lambda () store))
              ((symbol-function 'decknix--agent-session-list)
               (lambda ()
                 '(((sessionId . "store-old") (firstUserMessage . "wrap")
                    (modified . "2024-01-01T00:00:00Z"))
                   ((sessionId . "hash-new") (firstUserMessage . "real")
                    (modified . "2025-01-01T00:00:00Z")))))
              ((symbol-function 'decknix--agent-conversation-key)
               (lambda (fm) (if (equal fm "real") "k" "OTHER"))))
      (should (equal "hash-new"
                     (decknix--agent-latest-session-id-for-conv-key "k"))))))



;; -- store fallback when the transcript scan misses -----------------
;;
;; Observed 2026-09-11: session c9935439 was live behind a healthy broker
;; (seven days uptime) and did not come back after a switch, and could not
;; be found in the `C-c s s' picker either.
;;
;; The reattach chain resolved a conv-key and a broker key correctly, then
;; stopped because this returned nil. It returned nil because the session
;; was absent from the CACHED `decknix--agent-session-list'; a synchronous
;; refresh produced the very same 117 entries WITH it present. So a stale
;; cache silently cost a live session its buffer.
;;
;; The store already records the association and its own docstring calls it
;; "the authoritative association". Gating resume on a scan of transcript
;; files makes reattach depend on cache freshness for no benefit: the scan
;; can only ever confirm what the store already says.

(ert-deftest decknix-agent-conv-resolve--latest-falls-back-to-store-when-scan-misses ()
  "A session the scan has not indexed still resolves from the store."
  (let ((store (make-hash-table :test #'equal))
        (convs (make-hash-table :test #'equal))
        (entry (make-hash-table :test #'equal)))
    (puthash "sessions" '("only-in-store") entry)
    (puthash "k" entry convs)
    (puthash "conversations" convs store)
    (cl-letf (((symbol-function 'decknix--agent-tags-read) (lambda () store))
              ((symbol-function 'decknix--agent-session-list) (lambda () nil))
              ((symbol-function 'decknix--agent-conversation-key) (lambda (_fm) nil)))
      (should (equal "only-in-store"
                     (decknix--agent-latest-session-id-for-conv-key "k"))))))

(ert-deftest decknix-agent-conv-resolve--store-fallback-takes-the-most-recent ()
  "With several recorded sessions the newest wins, matching the scan path.
Sessions are appended as they are created, so the last entry is newest."
  (let ((store (make-hash-table :test #'equal))
        (convs (make-hash-table :test #'equal))
        (entry (make-hash-table :test #'equal)))
    (puthash "sessions" '("oldest" "middle" "newest") entry)
    (puthash "k" entry convs)
    (puthash "conversations" convs store)
    (cl-letf (((symbol-function 'decknix--agent-tags-read) (lambda () store))
              ((symbol-function 'decknix--agent-session-list) (lambda () nil))
              ((symbol-function 'decknix--agent-conversation-key) (lambda (_fm) nil)))
      (should (equal "newest"
                     (decknix--agent-latest-session-id-for-conv-key "k"))))))

(ert-deftest decknix-agent-conv-resolve--scan-still-wins-over-the-store ()
  "The fallback must not displace a real scan hit.
The scan carries `modified' timestamps, so when it has an answer it is the
better one; the store list has no ordering beyond append order."
  (let ((store (make-hash-table :test #'equal))
        (convs (make-hash-table :test #'equal))
        (entry (make-hash-table :test #'equal)))
    (puthash "sessions" '("store-a" "store-b") entry)
    (puthash "k" entry convs)
    (puthash "conversations" convs store)
    (cl-letf (((symbol-function 'decknix--agent-tags-read) (lambda () store))
              ((symbol-function 'decknix--agent-session-list)
               (lambda () '(((sessionId . "store-a") (firstUserMessage . "x")
                             (modified . "2026-01-01T00:00:00Z")))))
              ((symbol-function 'decknix--agent-conversation-key) (lambda (_fm) nil)))
      (should (equal "store-a"
                     (decknix--agent-latest-session-id-for-conv-key "k"))))))

(ert-deftest decknix-agent-conv-resolve--no-store-and-no-scan-is-still-nil ()
  "An unknown conversation must not invent a session id."
  (let ((store (make-hash-table :test #'equal))
        (convs (make-hash-table :test #'equal)))
    (puthash "conversations" convs store)
    (cl-letf (((symbol-function 'decknix--agent-tags-read) (lambda () store))
              ((symbol-function 'decknix--agent-session-list) (lambda () nil))
              ((symbol-function 'decknix--agent-conversation-key) (lambda (_fm) nil)))
      (should-not (decknix--agent-latest-session-id-for-conv-key "k")))))

;; -- session-id metadata fallback (store-field-scan) ---------------

(defun decknix-cr-test--entry (sessions &rest kv)
  "Build a conv ENTRY hash with SESSIONS and KV plist of field/value."
  (let ((h (make-hash-table :test 'equal)))
    (puthash "sessions" sessions h)
    (while kv (puthash (pop kv) (pop kv) h))
    h))

(defun decknix-cr-test--convs (&rest pairs)
  (let ((h (make-hash-table :test 'equal)))
    (dolist (p pairs) (puthash (car p) (cdr p) h))
    h))

(ert-deftest decknix-cr/field-scan--found ()
  (let ((convs (decknix-cr-test--convs
                (cons "ck1" (decknix-cr-test--entry '("sid-A") "tags" '("x")))
                (cons "ck2" (decknix-cr-test--entry '("sid-B") "model" "opus")))))
    (should (equal (decknix--agent-store-field-scan convs "sid-A" "tags") '("x")))
    (should (equal (decknix--agent-store-field-scan convs "sid-B" "model") "opus"))))

(ert-deftest decknix-cr/field-scan--skips-empty-fragment ()
  "An untagged fragment must not shadow a tagged one for the same session."
  (let ((convs (decknix-cr-test--convs
                ;; empty fragment sorts first by conv-key
                (cons "aaa" (decknix-cr-test--entry '("sid-X") "tags" nil))
                (cons "bbb" (decknix-cr-test--entry '("sid-X") "tags" '("claude" "decknix"))))))
    (should (equal (decknix--agent-store-field-scan convs "sid-X" "tags")
                   '("claude" "decknix")))))

(ert-deftest decknix-cr/field-scan--none ()
  (let ((convs (decknix-cr-test--convs
                (cons "ck1" (decknix-cr-test--entry '("sid-A") "tags" '("x"))))))
    (should (null (decknix--agent-store-field-scan convs "sid-Z" "tags")))
    (should (null (decknix--agent-store-field-scan convs "sid-A" "model")))
    (should (null (decknix--agent-store-field-scan nil "sid-A" "tags")))))


;; -- conv-key-for-session-id (stable write key) -------------------

(ert-deftest decknix-cr/conv-key-scan--prefers-entry-with-metadata ()
  "Reuse the conversation's established (metadata-bearing) key, not a bare
fragment, so a write consolidates instead of scattering."
  (let ((convs (decknix-cr-test--convs
                ;; a bare fragment (sorts first) listing the session
                (cons "aaa" (decknix-cr-test--entry '("sid-X")))
                ;; the real entry carrying metadata
                (cons "bbb" (decknix-cr-test--entry '("sid-X") "brokerKey" "s-1")))))
    (should (equal (decknix--agent-conv-key-scan-for-session-id convs "sid-X")
                   "bbb"))))

(ert-deftest decknix-cr/conv-key-scan--falls-back-to-any ()
  "When no matching entry has metadata, return any entry listing the session."
  (let ((convs (decknix-cr-test--convs
                (cons "zzz" (decknix-cr-test--entry '("sid-Y")))
                (cons "mmm" (decknix-cr-test--entry '("sid-Y"))))))
    ;; deterministic: lexicographically smallest matching key
    (should (equal (decknix--agent-conv-key-scan-for-session-id convs "sid-Y")
                   "mmm"))))

(ert-deftest decknix-cr/conv-key-scan--none ()
  (let ((convs (decknix-cr-test--convs
                (cons "ck1" (decknix-cr-test--entry '("sid-A") "tags" '("x"))))))
    (should (null (decknix--agent-conv-key-scan-for-session-id convs "sid-Z")))
    (should (null (decknix--agent-conv-key-scan-for-session-id nil "sid-A")))))

;; -- contested claims: which tagged conversation owns the session? ----
;;
;; A session can end up listed under SEVERAL conversations (43 of 371 in
;; the live store; 12 with more than one TAGGED claimant).  The scan then
;; decides which conversation's tags the session displays under -- and it
;; decided by lexicographic conv-key, which is deterministic but
;; arbitrary: it has nothing to do with which conversation is right.
;;
;; Observed: session 122adc26 belonged to `756afa19' (day6, dos, log,
;; july, 28) and was also claimed by `2a94df56' (fix).  `2' sorts before
;; `7', so it displayed as `fix' and the user could not find their day6
;; session at all.
;;
;; ANCHORING is the ground truth available here: a conversation is
;; anchored when its key is the hash of a member's own first message, so
;; it is a real conversation rather than an accretion container.  In the
;; observed case day6 was anchored and `fix' was not -- all five of its
;; members were resume primers, which all hash alike.

(ert-deftest decknix-cr/conv-key-scan--anchored-beats-alphabetical ()
  "An anchored conversation wins over one that merely sorts first.
This is the day6-vs-fix case: without it the session shows the wrong
tags purely because `2' < `7'."
  (let ((convs (decknix-cr-test--convs
                (cons "2a94df56" (decknix-cr-test--entry '("sid-X") "tags" '("fix")))
                (cons "756afa19" (decknix-cr-test--entry '("sid-X") "tags" '("day6"))))))
    (should (equal (decknix--agent-conv-key-scan-for-session-id
                    convs "sid-X" (lambda (k) (equal k "756afa19")))
                   "756afa19"))))

(ert-deftest decknix-cr/conv-key-scan--recency-breaks-unanchored-ties ()
  "With no anchor, the most recently used conversation wins.
Where you last worked is a better guess than alphabetical order."
  (let ((convs (decknix-cr-test--convs
                (cons "aaa" (decknix-cr-test--entry
                             '("sid-X") "tags" '("old")
                             "lastAccessed" "2026-07-01T00:00:00.000Z"))
                (cons "zzz" (decknix-cr-test--entry
                             '("sid-X") "tags" '("recent")
                             "lastAccessed" "2026-08-30T00:00:00.000Z")))))
    (should (equal (decknix--agent-conv-key-scan-for-session-id convs "sid-X")
                   "zzz"))))

(ert-deftest decknix-cr/conv-key-scan--anchor-outranks-recency ()
  "A stale but anchored conversation still beats a recent container.
day6 was last touched 2026-08-25 and `fix' 2026-08-31, so recency alone
would have kept the wrong answer."
  (let ((convs (decknix-cr-test--convs
                (cons "container" (decknix-cr-test--entry
                                   '("sid-X") "tags" '("fix")
                                   "lastAccessed" "2026-08-31T00:00:00.000Z"))
                (cons "real" (decknix-cr-test--entry
                              '("sid-X") "tags" '("day6")
                              "lastAccessed" "2026-08-25T00:00:00.000Z")))))
    (should (equal (decknix--agent-conv-key-scan-for-session-id
                    convs "sid-X" (lambda (k) (equal k "real")))
                   "real"))))

(ert-deftest decknix-cr/conv-key-scan--still-deterministic-without-signals ()
  "With neither anchor nor timestamps, fall back to sorted key.
Determinism is retained so the resolution never flickers between calls."
  (let ((convs (decknix-cr-test--convs
                (cons "zzz" (decknix-cr-test--entry '("sid-Y") "tags" '("a")))
                (cons "mmm" (decknix-cr-test--entry '("sid-Y") "tags" '("b"))))))
    (should (equal (decknix--agent-conv-key-scan-for-session-id convs "sid-Y")
                   "mmm"))))

(ert-deftest decknix-cr/conv-key-scan--metadata-still-beats-bare ()
  "The original contract holds: a tagged entry outranks an untagged one,
however the untagged one sorts or when it was last touched."
  (let ((convs (decknix-cr-test--convs
                (cons "aaa" (decknix-cr-test--entry
                             '("sid-X") "lastAccessed" "2026-09-01T00:00:00.000Z"))
                (cons "bbb" (decknix-cr-test--entry '("sid-X") "tags" '("real"))))))
    (should (equal (decknix--agent-conv-key-scan-for-session-id convs "sid-X")
                   "bbb"))))

;; -- session conv-key with the session-id fallback --------------------
;;
;; The pattern that has now bitten in four places.  A session's conv-key
;; is derived by hashing its own first message, but a RESUMED session's
;; first message is the resume primer and a FORKED session's is the fork
;; preamble -- and since 2c0ada6 neither keys a conversation.  So every
;; caller that resolves "which conversation is this session in?" from the
;; first message alone gets nil for exactly those sessions:
;;
;;   tags-for-session          picker row tags        (fixed ec7b161)
;;   session-display-name      buffer name            (fixed ec7b161)
;;   saved-source ws filter    session vanishes       (this sweep)
;;   conversation-key-for-session   central resolver  (this sweep)
;;
;; The session-id is stable across resume and fork, which is why the
;; store scan succeeds where the hash cannot.

(ert-deftest decknix-cr/session-conv-key--prefers-the-first-message ()
  "A session whose own first message keys a conversation uses that key."
  (cl-letf (((symbol-function 'decknix--agent-conversation-key)
             (lambda (_) "from-message"))
            ((symbol-function 'decknix--agent-conv-key-for-session-id)
             (lambda (_) "from-store")))
    (should (equal (decknix--agent-session-conv-key
                    '((sessionId . "sid-1") (firstUserMessage . "real prompt")))
                   "from-message"))))

(ert-deftest decknix-cr/session-conv-key--falls-back-to-the-store ()
  "A resumed/forked session resolves via its stable session-id.
This is the case that made day6 invisible: the primer keys nothing, so
without the fallback the session has no conversation at all."
  (cl-letf (((symbol-function 'decknix--agent-conversation-key)
             (lambda (_) nil))
            ((symbol-function 'decknix--agent-conv-key-for-session-id)
             (lambda (sid) (when (equal sid "sid-1") "756afa19"))))
    (should (equal (decknix--agent-session-conv-key
                    '((sessionId . "sid-1")
                      (firstUserMessage . "This message is a resumed continuation")))
                   "756afa19"))))

(ert-deftest decknix-cr/session-conv-key--nil-when-neither-resolves ()
  "Unknown session with an unkeyable message yields nil, not an error."
  (cl-letf (((symbol-function 'decknix--agent-conversation-key)
             (lambda (_) nil))
            ((symbol-function 'decknix--agent-conv-key-for-session-id)
             (lambda (_) nil)))
    (should-not (decknix--agent-session-conv-key
                 '((sessionId . "sid-x") (firstUserMessage . "primer"))))))

(ert-deftest decknix-cr/session-conv-key--tolerates-missing-fields ()
  "A session alist missing either field must not error.
It runs over every row the picker builds."
  (cl-letf (((symbol-function 'decknix--agent-conversation-key)
             (lambda (_) nil))
            ((symbol-function 'decknix--agent-conv-key-for-session-id)
             (lambda (_) nil)))
    (should-not (decknix--agent-session-conv-key nil))
    (should-not (decknix--agent-session-conv-key '((sessionId . "s"))))
    (should-not (decknix--agent-session-conv-key '((firstUserMessage . "m"))))))

(provide 'decknix-agent-conv-resolve-test)
;;; decknix-agent-conv-resolve-test.el ends here
