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

(provide 'decknix-agent-conv-resolve-test)
;;; decknix-agent-conv-resolve-test.el ends here
