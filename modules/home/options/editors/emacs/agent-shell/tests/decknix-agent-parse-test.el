;;; decknix-agent-parse-test.el --- Tests for agent pure parsers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-parse "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning current behaviour of the pure parsing helpers
;; extracted from the agent-shell heredoc.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-parse)

;; -- session-parse -------------------------------------------------

(ert-deftest decknix-agent-session-parse--empty ()
  "Empty input returns nil."
  (should (null (decknix--agent-session-parse "")))
  (should (null (decknix--agent-session-parse "   "))))

(ert-deftest decknix-agent-session-parse--malformed ()
  "Malformed JSON returns nil instead of throwing."
  (should (null (decknix--agent-session-parse "not json")))
  (should (null (decknix--agent-session-parse "{not closed"))))

(ert-deftest decknix-agent-session-parse--basic-array ()
  "Valid array of session objects parses to alists with symbol keys."
  (let ((result (decknix--agent-session-parse
                 "[{\"sessionId\": \"abc\", \"firstUserMessage\": \"hi\"}]")))
    (should (listp result))
    (should (= (length result) 1))
    (should (equal (alist-get 'sessionId (car result)) "abc"))
    (should (equal (alist-get 'firstUserMessage (car result)) "hi"))))

(ert-deftest decknix-agent-session-parse--multiple-sessions ()
  (let ((result (decknix--agent-session-parse
                 "[{\"sessionId\": \"a\"},{\"sessionId\": \"b\"}]")))
    (should (= (length result) 2))
    (should (equal (alist-get 'sessionId (nth 0 result)) "a"))
    (should (equal (alist-get 'sessionId (nth 1 result)) "b"))))

(ert-deftest decknix-agent-session-parse--trailing-process-noise ()
  "Trailing 'Process ... finished' after the closing ] is tolerated."
  (let ((result (decknix--agent-session-parse
                 "[{\"sessionId\": \"x\"}]\nProcess auggie-session-list finished")))
    (should (= (length result) 1))
    (should (equal (alist-get 'sessionId (car result)) "x"))))

(ert-deftest decknix-agent-session-parse--leading-whitespace ()
  "Leading whitespace before the array is stripped via string-trim."
  (let ((result (decknix--agent-session-parse
                 "   [{\"sessionId\": \"y\"}]   ")))
    (should (= (length result) 1))))

(ert-deftest decknix-agent-session-parse--non-array-rejected ()
  "Input not starting with `[' returns nil (string-prefix-p check)."
  (should (null (decknix--agent-session-parse
                 "{\"sessionId\": \"z\"}"))))

;; -- session-parse-object ------------------------------------------
;;
;; The sequential per-file jq path (`decknix--session-parse-file')
;; emits ONE bare `{...}' object per file, whereas the bulk path wraps
;; results in an array.  `decknix--agent-session-parse' only accepts
;; the array form, so a dedicated single-object parser feeds the
;; per-file path.  Regression guard for the bug where Claude sessions
;; (always <20 files -> sequential path) never surfaced because the
;; bare object was rejected by the array parser.

(ert-deftest decknix-agent-session-parse-object--empty ()
  "Empty / whitespace input returns nil."
  (should (null (decknix--agent-session-parse-object "")))
  (should (null (decknix--agent-session-parse-object "   "))))

(ert-deftest decknix-agent-session-parse-object--malformed ()
  "Malformed JSON returns nil instead of throwing."
  (should (null (decknix--agent-session-parse-object "not json")))
  (should (null (decknix--agent-session-parse-object "{not closed"))))

(ert-deftest decknix-agent-session-parse-object--basic ()
  "A bare JSON object parses to a single alist with symbol keys."
  (let ((result (decknix--agent-session-parse-object
                 "{\"sessionId\": \"abc\", \"firstUserMessage\": \"hi\"}")))
    (should (consp result))
    ;; A single alist, not a list-of-alists: keys are read directly.
    (should (equal (alist-get 'sessionId result) "abc"))
    (should (equal (alist-get 'firstUserMessage result) "hi"))))

(ert-deftest decknix-agent-session-parse-object--trailing-process-noise ()
  "Trailing text after the closing `}' is tolerated."
  (let ((result (decknix--agent-session-parse-object
                 "{\"sessionId\": \"x\"}\nProcess agent-session finished")))
    (should (equal (alist-get 'sessionId result) "x"))))

(ert-deftest decknix-agent-session-parse-object--leading-whitespace ()
  "Leading whitespace before the object is stripped via string-trim."
  (let ((result (decknix--agent-session-parse-object
                 "   {\"sessionId\": \"y\"}   ")))
    (should (equal (alist-get 'sessionId result) "y"))))

(ert-deftest decknix-agent-session-parse-object--array-rejected ()
  "Array input (handled by `decknix--agent-session-parse') is rejected here."
  (should (null (decknix--agent-session-parse-object
                 "[{\"sessionId\": \"z\"}]"))))

;; -- prompt-search-parse -------------------------------------------

(ert-deftest decknix-prompt-search-parse--empty ()
  (should (null (decknix--prompt-search-parse "")))
  (should (null (decknix--prompt-search-parse "   \n   "))))

(ert-deftest decknix-prompt-search-parse--single-line ()
  "Single jq line produces a flat list of strings."
  (let ((result (decknix--prompt-search-parse
                 "[\"first prompt\",\"second prompt\"]")))
    (should (equal result '("first prompt" "second prompt")))))

(ert-deftest decknix-prompt-search-parse--multiple-lines ()
  "Multiple jq lines are flattened in source order."
  (let ((result (decknix--prompt-search-parse
                 "[\"a\",\"b\"]\n[\"c\"]")))
    (should (equal result '("a" "b" "c")))))

(ert-deftest decknix-prompt-search-parse--dedup ()
  "Duplicate prompts across lines are dropped (first occurrence wins)."
  (let ((result (decknix--prompt-search-parse
                 "[\"a\",\"b\"]\n[\"b\",\"c\"]\n[\"a\"]")))
    (should (equal result '("a" "b" "c")))))

(ert-deftest decknix-prompt-search-parse--skips-empty-strings ()
  "Empty / whitespace-only strings are skipped."
  (let ((result (decknix--prompt-search-parse
                 "[\"a\",\"\",\"   \",\"b\"]")))
    (should (equal result '("a" "b")))))

(ert-deftest decknix-prompt-search-parse--malformed-line-tolerated ()
  "A malformed line in the middle does not abort the rest."
  (let ((result (decknix--prompt-search-parse
                 "[\"a\"]\nnot json\n[\"b\"]")))
    (should (equal result '("a" "b")))))

(ert-deftest decknix-prompt-search-parse--rejects-non-string-elements ()
  "Non-string elements (numbers, nulls) are silently dropped."
  (let ((result (decknix--prompt-search-parse
                 "[\"a\",42,null,\"b\"]")))
    (should (equal result '("a" "b")))))

;; -- conversation-key-raw ------------------------------------------

(ert-deftest decknix-agent-conversation-key-raw--nil ()
  (should (null (decknix--agent-conversation-key-raw nil))))

(ert-deftest decknix-agent-conversation-key-raw--empty ()
  "Empty string returns nil (treated as 'no message')."
  (should (null (decknix--agent-conversation-key-raw ""))))

(ert-deftest decknix-agent-conversation-key-raw--length ()
  "Returned key is exactly 16 hex chars."
  (let ((key (decknix--agent-conversation-key-raw "hello world")))
    (should (stringp key))
    (should (= (length key) 16))
    (should (string-match-p "^[0-9a-f]\\{16\\}$" key))))

(ert-deftest decknix-agent-conversation-key-raw--deterministic ()
  "Same input always yields the same key."
  (let ((k1 (decknix--agent-conversation-key-raw "test message"))
        (k2 (decknix--agent-conversation-key-raw "test message")))
    (should (equal k1 k2))))

(ert-deftest decknix-agent-conversation-key-raw--differs-on-different-input ()
  "Different inputs yield different keys."
  (let ((k1 (decknix--agent-conversation-key-raw "message one"))
        (k2 (decknix--agent-conversation-key-raw "message two")))
    (should-not (equal k1 k2))))

(ert-deftest decknix-agent-conversation-key-raw--known-vector ()
  "Pin known SHA-256 prefix for \"hello\" — guards against accidental
algorithm changes."
  ;; SHA-256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
  (should (equal (decknix--agent-conversation-key-raw "hello")
                 "2cf24dba5fb0a30e")))

;; -- surrounding-whitespace normalization --------------------------
;;
;; Regression: the live write path (flush hook) hashes raw comint
;; input, which carries a trailing newline ("hello\n"), while the
;; transcript-read paths (picker, resume) hash the stored first
;; message with none ("hello").  Both must map to the SAME key or a
;; resumed conversation loses its tags / brokerKey / model / mode.

(ert-deftest decknix-agent-conversation-key-raw--ignores-trailing-newline ()
  "\"hello\\n\" (raw comint input) keys the same as \"hello\" (transcript)."
  (should (equal (decknix--agent-conversation-key-raw "hello\n")
                 (decknix--agent-conversation-key-raw "hello")))
  ;; ... and specifically the transcript-form key, not sha256("hello\n").
  (should (equal (decknix--agent-conversation-key-raw "hello\n")
                 "2cf24dba5fb0a30e")))

(ert-deftest decknix-agent-conversation-key-raw--ignores-surrounding-ws ()
  "Leading/trailing spaces, tabs and newlines do not change the key."
  (let ((base (decknix--agent-conversation-key-raw "hello world")))
    (dolist (variant '("  hello world" "hello world  " "\thello world\n"
                       "\n hello world \t"))
      (should (equal (decknix--agent-conversation-key-raw variant) base)))))

(ert-deftest decknix-agent-conversation-key-raw--whitespace-only-nil ()
  "A whitespace-only message is treated as 'no message' (nil key)."
  (should (null (decknix--agent-conversation-key-raw "   \n\t"))))

;; -- canonical-length truncation -----------------------------------
;;
;; The jq filter that builds the read-side `firstUserMessage' field
;; slices `request_message[:200]'.  Without matching truncation on the
;; write side, messages longer than the canonical length produced
;; orphaned conversation entries whose tags / workspace / linked-PR
;; metadata could never be resolved by the picker, sidebar or header.

(ert-deftest decknix-agent-conv-key--canonical-length-defconst ()
  "The canonical truncation length matches the jq `[:200]' slice."
  (should (= 200 decknix--agent-conv-key-canonical-length)))

(ert-deftest decknix-agent-conversation-key-raw--truncates-long-input ()
  "Inputs longer than 200 chars hash the same as their 200-char prefix."
  (let* ((prefix (make-string 200 ?a))
         (long (concat prefix (make-string 50 ?b))))
    (should (= 250 (length long)))
    (should (equal (decknix--agent-conversation-key-raw long)
                   (decknix--agent-conversation-key-raw prefix)))))

(ert-deftest decknix-agent-conversation-key-raw--exact-200-no-truncation ()
  "Inputs of exactly 200 chars are hashed unmodified."
  (let* ((s (make-string 200 ?x))
         (s+1 (concat s "y")))
    (should-not (equal (decknix--agent-conversation-key-raw s)
                       (decknix--agent-conversation-key-raw "x")))
    ;; The 201st char does not change the hash because it is sliced off.
    (should (equal (decknix--agent-conversation-key-raw s)
                   (decknix--agent-conversation-key-raw s+1)))))

(ert-deftest decknix-agent-conversation-key-raw--short-unaffected ()
  "Inputs shorter than the canonical length are unaffected by the cap.
Pinned against the well-known SHA-256(\"hello\") prefix."
  (should (equal (decknix--agent-conversation-key-raw "hello")
                 "2cf24dba5fb0a30e")))

(ert-deftest decknix-agent-conversation-key-raw--long-pinned-vector ()
  "Pin the canonical hash for a known long input.
Computed independently: SHA-256 of 200 lowercase `a' chars."
  ;; `python3 -c "import hashlib; print(hashlib.sha256(b'a'*200).hexdigest()[:16])"'
  ;; -> "c2a908d98f5df987"
  (should (equal (decknix--agent-conversation-key-raw (make-string 200 ?a))
                 "c2a908d98f5df987")))

;; -- command-message canonicalisation (slash-command wrappers) -----

(defconst decknix-agent-parse-test--wrapper
  (concat "<command-message>review-bot-pr</command-message>\n"
          "<command-name>/review-bot-pr</command-name>\n"
          "<command-args>https://github.com/o/r/pull/1</command-args>")
  "A representative Claude slash-command first-message wrapper.")

(ert-deftest decknix-agent-canonicalize-command-message--wrapper ()
  "A command wrapper collapses to `<name> <args>' (the literal command)."
  (should (equal (decknix--agent-canonicalize-command-message
                  decknix-agent-parse-test--wrapper)
                 "/review-bot-pr https://github.com/o/r/pull/1")))

(ert-deftest decknix-agent-canonicalize-command-message--no-args ()
  "A wrapper without args collapses to just the command name."
  (should (equal (decknix--agent-canonicalize-command-message
                  "<command-name>/review</command-name>")
                 "/review")))

(ert-deftest decknix-agent-canonicalize-command-message--plain-unchanged ()
  "Non-wrapper messages pass through untouched."
  (let ((plain "please review this and tell me what you think"))
    (should (equal (decknix--agent-canonicalize-command-message plain) plain))))

(ert-deftest decknix-agent-conversation-key-raw--wrapper-matches-literal ()
  "The core fix: a slash-command wrapper and the literal command the
launcher auto-sends resolve to the SAME conversation key, so
launcher-written tags are found on the wrapper-recorded transcript."
  (should (equal (decknix--agent-conversation-key-raw
                  decknix-agent-parse-test--wrapper)
                 (decknix--agent-conversation-key-raw
                  "/review-bot-pr https://github.com/o/r/pull/1"))))

(ert-deftest decknix-agent-conversation-key-raw--distinct-prs-distinct-keys ()
  "Wrappers for different PRs still key distinctly (args are part of the key)."
  (should-not
   (equal (decknix--agent-conversation-key-raw
           (concat "<command-name>/review-service-pr</command-name>"
                   "<command-args>https://github.com/o/r/pull/1</command-args>"))
          (decknix--agent-conversation-key-raw
           (concat "<command-name>/review-service-pr</command-name>"
                   "<command-args>https://github.com/o/r/pull/2</command-args>")))))

;; -- machine-generated preambles must not key a conversation ----------
;;
;; The conv-key hashes the first 200 characters of the first user message.
;; Claude opens every RESUMED session with an identical primer, and every
;; FORKED session with a near-identical preamble, both far longer than the
;; cap -- so each one hashes to the same value regardless of which
;; conversation it continues.  Measured over 231 transcripts: 25 distinct
;; sessions collapsed onto the single key 887e38e509a9ee3e.
;;
;; That bucket is a spurious "conversation" with no real identity.  It is
;; also a live tag-write target: anything that flushes pending metadata
;; while the first message is a preamble lands its tags on the bucket
;; rather than on the session's own conversation.  A preamble therefore
;; keys NOTHING -- callers already treat a nil key as "not yet known" and
;; fall back to store membership, which is where a resumed session's real
;; identity lives.

(ert-deftest decknix-parse--resume-primer-does-not-key ()
  "Claude's resume primer never produces a conversation key."
  (should-not (decknix--agent-conversation-key-raw
               (concat "This message is a resumed continuation of an earlier "
                       "Claude session -- the same ongoing conversation, not a "
                       "new one. Most recently in this conversation: we were "
                       "fixing the sidebar refresh.")))
  ;; Leading whitespace/decoration must not smuggle it past the check.
  (should-not (decknix--agent-conversation-key-raw
               "\n  This message is a resumed continuation of an earlier Claude session")))

(ert-deftest decknix-parse--fork-preamble-does-not-key ()
  "A forked session's preamble never produces a conversation key."
  (should-not (decknix--agent-conversation-key-raw
               (concat "This session was forked from an existing Claude agent "
                       "session.\n\nSource provider: Claude\nSource session id: "
                       "d8d1f0c2-1111-2222-3333-444455556666\n"))))

(ert-deftest decknix-parse--distinct-primers-would-have-collided ()
  "Two different resumes share a key when keyed -- which is why they must not be.
Pins the actual collision rather than merely asserting nil, so a future
change that re-enables keying for preambles fails loudly here."
  ;; The real primer verbatim: its first 200 characters (the hashing cap)
  ;; are fixed boilerplate, and the only distinguishing content -- the
  ;; source session id -- falls AFTER the cap.  That is the collision.
  (let* ((base (concat "This message is a resumed continuation of an earlier "
                       "Claude session -- the same ongoing conversation, not a "
                       "new one.\nEverything before this point already happened; "
                       "you are picking the thread back up.\n\nSource session id: "))
         (a (concat base "b22de91c-dffd-46a2-a071-c2a79265a5a0\n"))
         (b (concat base "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0\n")))
    ;; Identical within the 200-char cap -> identical hash if keyed at all.
    (should (equal (substring a 0 200) (substring b 0 200)))
    (should-not (decknix--agent-conversation-key-raw a))
    (should-not (decknix--agent-conversation-key-raw b))))

(ert-deftest decknix-parse--ordinary-message-still-keys ()
  "A real user message is unaffected -- including one that merely mentions a resume."
  (should (decknix--agent-conversation-key-raw
           "Looking at this slack thread, what is worth demoing on Monday?"))
  ;; Discussing the primer is not being one: only a message that STARTS
  ;; with the preamble is machine-generated.
  (should (decknix--agent-conversation-key-raw
           "Why does 'This message is a resumed continuation' keep colliding?")))

(provide 'decknix-agent-parse-test)
;;; decknix-agent-parse-test.el ends here
