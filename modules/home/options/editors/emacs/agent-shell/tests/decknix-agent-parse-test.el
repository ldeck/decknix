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

(provide 'decknix-agent-parse-test)
;;; decknix-agent-parse-test.el ends here
