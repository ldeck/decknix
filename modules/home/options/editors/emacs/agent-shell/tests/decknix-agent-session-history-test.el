;;; decknix-agent-session-history-test.el --- Tests for session history extractor -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-session-history "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix--agent-session-extract-history'
;; and `decknix--agent-session-file' (carved from
;; `decknix-agent-shell-main' / main-bulk).  Pins the turn-grouping
;; contract: a non-empty `request_message' opens a turn, subsequent
;; entries' `response_text' values accumulate under it, and the last
;; N turns are returned oldest-first.
;;
;; Tests stage temp JSON files via a small helper that intercepts
;; `decknix--agent-session-file' through `cl-letf' so the extractor
;; never reaches the real `~/.augment/sessions/' tree.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'decknix-agent-session-history)

(defmacro decknix-agent-session-history-test--with-fixture (json-string &rest body)
  "Write JSON-STRING to a temp file and stub `-session-file' to return it.
Inside BODY the symbol `sid' is bound to a synthetic session ID."
  (declare (indent 1))
  `(let* ((sid "test-sid-0000")
          (tmp (make-temp-file "decknix-history-" nil ".json")))
     (unwind-protect
         (progn
           (with-temp-file tmp (insert ,json-string))
           (cl-letf (((symbol-function 'decknix--agent-session-file)
                      (lambda (_id) tmp)))
             ,@body))
       (when (file-exists-p tmp) (delete-file tmp)))))

;; -- session-file -------------------------------------------------

(ert-deftest decknix-agent-session-history/file-path-shape ()
  "Path expands under ~/.augment/sessions/<sid>.json."
  (let ((path (decknix--agent-session-file "abc-def-123")))
    (should (string-suffix-p "/.augment/sessions/abc-def-123.json" path))
    (should (file-name-absolute-p path))))

;; -- extract-history ----------------------------------------------

(ert-deftest decknix-agent-session-history/empty-history ()
  "Empty chatHistory returns nil (no turns to take)."
  (decknix-agent-session-history-test--with-fixture "{\"chatHistory\":[]}"
    (should (null (decknix--agent-session-extract-history sid 5)))))

(ert-deftest decknix-agent-session-history/all-empty-request-messages ()
  "Entries with only empty request_message produce no turns."
  (decknix-agent-session-history-test--with-fixture
      "{\"chatHistory\":[
         {\"exchange\":{\"request_message\":\"\",\"response_text\":\"orphan\"}},
         {\"exchange\":{\"request_message\":\"   \",\"response_text\":\"\"}}
       ]}"
    (should (null (decknix--agent-session-extract-history sid 5)))))

(ert-deftest decknix-agent-session-history/single-turn-multi-chunk-reply ()
  "One user message followed by N response_text chunks groups into one turn,
joined by newline in dolist order."
  (decknix-agent-session-history-test--with-fixture
      "{\"chatHistory\":[
         {\"exchange\":{\"request_message\":\"hello\",\"response_text\":\"\"}},
         {\"exchange\":{\"request_message\":\"\",\"response_text\":\"chunk-a\"}},
         {\"exchange\":{\"request_message\":\"\",\"response_text\":\"chunk-b\"}},
         {\"exchange\":{\"request_message\":\"\",\"response_text\":\"chunk-c\"}}
       ]}"
    (let ((turns (decknix--agent-session-extract-history sid 5)))
      (should (= 1 (length turns)))
      (should (equal "hello" (caar turns)))
      (should (equal "chunk-a\nchunk-b\nchunk-c" (cdar turns))))))

(ert-deftest decknix-agent-session-history/take-last-n-truncates ()
  "More turns than N requested returns only the last N, oldest-first."
  (decknix-agent-session-history-test--with-fixture
      "{\"chatHistory\":[
         {\"exchange\":{\"request_message\":\"q1\",\"response_text\":\"r1\"}},
         {\"exchange\":{\"request_message\":\"q2\",\"response_text\":\"r2\"}},
         {\"exchange\":{\"request_message\":\"q3\",\"response_text\":\"r3\"}},
         {\"exchange\":{\"request_message\":\"q4\",\"response_text\":\"r4\"}}
       ]}"
    (let ((turns (decknix--agent-session-extract-history sid 2)))
      (should (= 2 (length turns)))
      (should (equal '(("q3" . "r3") ("q4" . "r4")) turns)))))

(ert-deftest decknix-agent-session-history/most-recent-turn-included ()
  "Final turn is always closed even when no following user message marks it."
  (decknix-agent-session-history-test--with-fixture
      "{\"chatHistory\":[
         {\"exchange\":{\"request_message\":\"older\",\"response_text\":\"old-r\"}},
         {\"exchange\":{\"request_message\":\"newer\",\"response_text\":\"\"}},
         {\"exchange\":{\"request_message\":\"\",\"response_text\":\"trailing-chunk\"}}
       ]}"
    (let ((turns (decknix--agent-session-extract-history sid 5)))
      (should (= 2 (length turns)))
      (should (equal "newer" (caadr turns)))
      (should (equal "trailing-chunk" (cdadr turns))))))

(ert-deftest decknix-agent-session-history/missing-file-returns-nil ()
  "Non-existent session file returns nil without erroring."
  (cl-letf (((symbol-function 'decknix--agent-session-file)
             (lambda (_id) "/tmp/decknix-does-not-exist.json")))
    (should (null (decknix--agent-session-extract-history "ghost" 5)))))

(ert-deftest decknix-agent-session-history/malformed-json-returns-nil ()
  "Parse failure logs a message and returns nil rather than propagating."
  (decknix-agent-session-history-test--with-fixture "{not valid json"
    (should (null (decknix--agent-session-extract-history sid 5)))))

(ert-deftest decknix-agent-session-history/orphan-response-before-first-user ()
  "Response chunks before the first user message are dropped (no cur-user)."
  (decknix-agent-session-history-test--with-fixture
      "{\"chatHistory\":[
         {\"exchange\":{\"request_message\":\"\",\"response_text\":\"orphan-1\"}},
         {\"exchange\":{\"request_message\":\"\",\"response_text\":\"orphan-2\"}},
         {\"exchange\":{\"request_message\":\"first\",\"response_text\":\"\"}},
         {\"exchange\":{\"request_message\":\"\",\"response_text\":\"reply\"}}
       ]}"
    (let ((turns (decknix--agent-session-extract-history sid 5)))
      (should (= 1 (length turns)))
      (should (equal "first" (caar turns)))
      (should (equal "reply" (cdar turns))))))

(provide 'decknix-agent-session-history-test)
;;; decknix-agent-session-history-test.el ends here
