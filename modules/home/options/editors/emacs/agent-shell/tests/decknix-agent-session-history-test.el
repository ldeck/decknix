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

;; -- extract-all-turns --------------------------------------------

(ert-deftest decknix-agent-session-history/all-turns-no-truncation ()
  "extract-all-turns returns every turn even past N=2 default."
  (decknix-agent-session-history-test--with-fixture
      "{\"chatHistory\":[
         {\"exchange\":{\"request_message\":\"q1\",\"response_text\":\"r1\"}},
         {\"exchange\":{\"request_message\":\"q2\",\"response_text\":\"r2\"}},
         {\"exchange\":{\"request_message\":\"q3\",\"response_text\":\"r3\"}},
         {\"exchange\":{\"request_message\":\"q4\",\"response_text\":\"r4\"}}
       ]}"
    (let ((turns (decknix--agent-session-extract-all-turns sid)))
      (should (= 4 (length turns)))
      (should (equal '(("q1" . "r1") ("q2" . "r2")
                       ("q3" . "r3") ("q4" . "r4"))
                     turns)))))

(ert-deftest decknix-agent-session-history/all-turns-missing-file ()
  "Missing session file returns nil from extract-all-turns."
  (cl-letf (((symbol-function 'decknix--agent-session-file)
             (lambda (_id) "/tmp/decknix-does-not-exist.json")))
    (should (null (decknix--agent-session-extract-all-turns "ghost")))))

;; -- window-clamp -------------------------------------------------

(ert-deftest decknix-agent-session-history/clamp-empty-total ()
  "TOTAL=0 always yields cursor=0 regardless of inputs."
  (should (= 0 (decknix--agent-session-window-clamp 5 2 0)))
  (should (= 0 (decknix--agent-session-window-clamp -3 2 0)))
  (should (= 0 (decknix--agent-session-window-clamp 0 0 0))))

(ert-deftest decknix-agent-session-history/clamp-non-positive-count ()
  "Non-positive COUNT short-circuits to cursor=0."
  (should (= 0 (decknix--agent-session-window-clamp 7 0 10)))
  (should (= 0 (decknix--agent-session-window-clamp 7 -1 10))))

(ert-deftest decknix-agent-session-history/clamp-fits-everything ()
  "When COUNT >= TOTAL the only valid cursor is 0."
  (should (= 0 (decknix--agent-session-window-clamp 5 10 4)))
  (should (= 0 (decknix--agent-session-window-clamp 0 10 10))))

(ert-deftest decknix-agent-session-history/clamp-bottom-of-range ()
  "Negative cursor clamps up to 0."
  (should (= 0 (decknix--agent-session-window-clamp -100 3 10))))

(ert-deftest decknix-agent-session-history/clamp-top-of-range ()
  "Cursor past max clamps down to TOTAL-COUNT."
  (should (= 7 (decknix--agent-session-window-clamp 999 3 10)))
  (should (= 7 (decknix--agent-session-window-clamp 7 3 10))))

(ert-deftest decknix-agent-session-history/clamp-mid-range-passthrough ()
  "Cursor inside [0, TOTAL-COUNT] passes through unchanged."
  (should (= 4 (decknix--agent-session-window-clamp 4 3 10))))

;; -- take-window --------------------------------------------------

(ert-deftest decknix-agent-session-history/take-window-mid-slice ()
  "Mid-list cursor returns COUNT consecutive turns."
  (let ((turns '(("q1" . "r1") ("q2" . "r2") ("q3" . "r3")
                 ("q4" . "r4") ("q5" . "r5"))))
    (should (equal '(("q2" . "r2") ("q3" . "r3"))
                   (decknix--agent-session-take-window turns 1 2)))))

(ert-deftest decknix-agent-session-history/take-window-out-of-range-clamps ()
  "Out-of-range cursor clamps and returns the tail."
  (let ((turns '(("q1" . "r1") ("q2" . "r2") ("q3" . "r3"))))
    (should (equal '(("q2" . "r2") ("q3" . "r3"))
                   (decknix--agent-session-take-window turns 99 2)))))

(ert-deftest decknix-agent-session-history/take-window-empty-or-zero ()
  "Empty TURNS or non-positive COUNT yields nil."
  (should (null (decknix--agent-session-take-window nil 0 5)))
  (should (null (decknix--agent-session-take-window '(("q" . "r")) 0 0))))

(ert-deftest decknix-agent-session-history/take-window-count-exceeds-list ()
  "COUNT larger than list returns whole list."
  (let ((turns '(("q1" . "r1") ("q2" . "r2"))))
    (should (equal turns
                   (decknix--agent-session-take-window turns 0 99)))))

;; -- find-turn-containing -----------------------------------------

(ert-deftest decknix-agent-session-history/find-turn-user-side ()
  "Match in the user message returns that turn's index."
  (let ((turns '(("ask about zebras" . "...")
                 ("ask about MOUSE" . "...")
                 ("ask about ducks" . "..."))))
    (should (= 1 (decknix--agent-session-find-turn-containing
                  turns "mouse")))))

(ert-deftest decknix-agent-session-history/find-turn-response-side ()
  "Match in the assistant response returns that turn's index."
  (let ((turns '(("a" . "alpha")
                 ("b" . "BRAVO needle here")
                 ("c" . "charlie"))))
    (should (= 1 (decknix--agent-session-find-turn-containing
                  turns "needle")))))

(ert-deftest decknix-agent-session-history/find-turn-case-insensitive ()
  "Search is case-insensitive."
  (let ((turns '(("Foo" . "Bar"))))
    (should (= 0 (decknix--agent-session-find-turn-containing
                  turns "FOO")))
    (should (= 0 (decknix--agent-session-find-turn-containing
                  turns "BAR")))))

(ert-deftest decknix-agent-session-history/find-turn-no-match-returns-nil ()
  "No match returns nil; nil/empty regexp returns nil."
  (let ((turns '(("a" . "b"))))
    (should (null (decknix--agent-session-find-turn-containing
                   turns "xyz")))
    (should (null (decknix--agent-session-find-turn-containing
                   turns nil)))
    (should (null (decknix--agent-session-find-turn-containing
                   turns "")))
    (should (null (decknix--agent-session-find-turn-containing
                   nil "a")))))

(ert-deftest decknix-agent-session-history/find-turn-first-match-wins ()
  "Returns index of the first matching turn (oldest-first)."
  (let ((turns '(("first match" . "x")
                 ("second match" . "y")
                 ("third match" . "z"))))
    (should (= 0 (decknix--agent-session-find-turn-containing
                  turns "match")))))

(provide 'decknix-agent-session-history-test)
;;; decknix-agent-session-history-test.el ends here
