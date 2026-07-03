;;; decknix-agent-session-history-test.el --- Tests for session history extractor -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'decknix-agent-session-history)
(require 'decknix-agent-provider)

(defmacro decknix-agent-session-history-test--with-fixture (json-string &rest body)
  "Write JSON-STRING to a temp file and stub `-session-file' to return it."
  (declare (indent 1))
  ;; Bind the default provider to the one we register so these tests are
  ;; independent of the shipped `decknix-agent-default-provider' value:
  ;; `decknix--agent-session-extract-history' falls back to the default when
  ;; no provider is passed, and an unregistered default would error.
  `(let* ((sid "test-sid-0000")
          (tmp (make-temp-file "decknix-history-" nil ".json"))
          (decknix-agent-provider-registry nil)
          (decknix-agent-default-provider 'auggie))
     (decknix-agent-register-provider 'auggie
       '(:sessions-dir "~/.augment/sessions" :session-file-extension ".json"))
     (unwind-protect
         (progn
           (with-temp-file tmp (insert ,json-string))
           (cl-letf (((symbol-function 'decknix--agent-session-file)
                      (lambda (_id &optional _p) tmp)))
             ,@body))
       (when (file-exists-p tmp) (delete-file tmp)))))

(ert-deftest decknix-agent-session-history/jsonl-claude-turns ()
  "Claude-style JSONL extraction groups multiple assistant lines into one turn."
  (let ((sid "claude-sid-123")
        (tmp (make-temp-file "claude-history-" nil ".jsonl")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello\"},\"timestamp\":\"2026-01-19T10:00:00Z\"}\n")
            (insert "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"part1\"}]},\"timestamp\":\"2026-01-19T10:00:01Z\"}\n")
            (insert "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"part2\"}]},\"timestamp\":\"2026-01-19T10:00:02Z\"}\n")
            (insert "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"bye\"},\"timestamp\":\"2026-01-19T10:01:00Z\"}\n"))
          (let ((decknix-agent-provider-registry nil))
            (decknix-agent-register-provider 'claude-code
              '(:session-file-extension ".jsonl"))
            (cl-letf (((symbol-function 'decknix--agent-session-file)
                       (lambda (_id &optional _p) tmp)))
              (let ((turns (decknix--agent-session-extract-all-turns sid 'claude-code)))
                (should (= 2 (length turns)))
                (should (equal "hello" (caar turns)))
                (should (equal "part1\npart2" (cdar turns)))
                (should (equal "bye" (caadr turns)))
                (should (equal "" (cdadr turns)))))))
      (when (file-exists-p tmp) (delete-file tmp)))))

(ert-deftest decknix-agent-session-history/file-path-shape ()
  "Path expands under ~/.augment/sessions/<sid>.json."
  (let ((decknix-agent-provider-registry nil))
    (decknix-agent-register-provider 'auggie
      '(:sessions-dir "~/.augment/sessions" :session-file-extension ".json"))
    (let ((path (decknix--agent-session-file "abc-def-123" 'auggie)))
      (should (string-suffix-p "/.augment/sessions/abc-def-123.json" path))
      (should (file-name-absolute-p path)))))

(ert-deftest decknix-agent-session-history/empty-history ()
  (decknix-agent-session-history-test--with-fixture "{\"chatHistory\":[]}"
    (should (null (decknix--agent-session-extract-history sid 5)))))

(ert-deftest decknix-agent-session-history/all-empty-request-messages ()
  (decknix-agent-session-history-test--with-fixture
      "{\"chatHistory\":[
         {\"exchange\":{\"request_message\":\"\",\"response_text\":\"orphan\"}},
         {\"exchange\":{\"request_message\":\"   \",\"response_text\":\"\"}}
       ]}"
    (should (null (decknix--agent-session-extract-history sid 5)))))

(ert-deftest decknix-agent-session-history/single-turn-multi-chunk-reply ()
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

(ert-deftest decknix-agent-session-history/multi-project-path-memoised ()
  "Multi-project (Claude) resolution runs the `find' shell-out once.
The session transcript path is stable, so once resolved it is cached
keyed on (provider . sid) and revalidated by `file-exists-p'.  A second
lookup must NOT re-invoke the (expensive) shell-out — this is what keeps
the 2-second sidebar refresh from spawning a `find' per live Claude
session.  Deleting the file forces a re-scan."
  (let* ((decknix-agent-provider-registry nil)
         (decknix--agent-session-file-cache (make-hash-table :test 'equal))
         (tmp (make-temp-file "decknix-claude-" nil ".jsonl"))
         (find-calls 0))
    (decknix-agent-register-provider 'claude-code
      '(:sessions-dir "~/.claude/projects"
        :session-file-extension ".jsonl"
        :history-file "~/.claude/history.jsonl"))
    (unwind-protect
        (cl-letf (((symbol-function 'shell-command-to-string)
                   (lambda (&rest _)
                     (setq find-calls (1+ find-calls))
                     (concat tmp "\n"))))
          ;; First lookup: cold cache → one shell-out.
          (should (equal tmp (decknix--agent-session-file "sid-1" 'claude-code)))
          (should (= 1 find-calls))
          ;; Second lookup: warm cache, file still present → no shell-out.
          (should (equal tmp (decknix--agent-session-file "sid-1" 'claude-code)))
          (should (= 1 find-calls))
          ;; File disappears → cache invalidated → re-scan.
          (delete-file tmp)
          (decknix--agent-session-file "sid-1" 'claude-code)
          (should (= 2 find-calls)))
      (when (file-exists-p tmp) (delete-file tmp)))))

(ert-deftest decknix-agent-session-history/single-dir-not-cached ()
  "Auggie single-dir resolution stays a pure `expand-file-name' (no cache).
It must never touch the shell-out path nor the memo table."
  (let* ((decknix-agent-provider-registry nil)
         (decknix--agent-session-file-cache (make-hash-table :test 'equal)))
    (decknix-agent-register-provider 'auggie
      '(:sessions-dir "~/.augment/sessions" :session-file-extension ".json"))
    (let ((path (decknix--agent-session-file "abc-def-123" 'auggie)))
      (should (string-suffix-p "/.augment/sessions/abc-def-123.json" path))
      (should (= 0 (hash-table-count decknix--agent-session-file-cache))))))

(ert-deftest decknix-agent-session-history/missing-file-returns-nil ()
  (let ((decknix-agent-provider-registry nil)
        (decknix-agent-default-provider 'auggie))
    (decknix-agent-register-provider 'auggie
      '(:sessions-dir "~/.augment/sessions" :session-file-extension ".json"))
    (cl-letf (((symbol-function 'decknix--agent-session-file)
               (lambda (_id &optional _p) "/tmp/decknix-does-not-exist.json")))
      (should (null (decknix--agent-session-extract-history "ghost" 5))))))

(ert-deftest decknix-agent-session-history/malformed-json-returns-nil ()
  (decknix-agent-session-history-test--with-fixture "{not valid json"
    (should (null (decknix--agent-session-extract-history sid 5)))))

(ert-deftest decknix-agent-session-history/all-turns-no-truncation ()
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

;; -- Claude JSONL user `content' as a list of blocks (#stringp-restore) --
;;
;; In Claude's JSONL a `user' message's `content' is a string for a real
;; prompt, but a LIST of Anthropic content blocks when it delivers a tool
;; result (`{type:"tool_result", content:"...", is_error:...}').  Storing
;; that raw list as the turn's user field caused a
;; `wrong-type-argument stringp' the moment the restore path inserted it,
;; and it also spawned a bogus "turn" for what is really part of the
;; assistant's own work loop.

(ert-deftest decknix-agent-session-history/jsonl-user-text-helper ()
  "`-jsonl-user-text' returns a string (or nil), never the raw block list."
  ;; Plain string content passes through untouched.
  (should (equal "plain" (decknix--agent-session-jsonl-user-text "plain")))
  ;; A list of text blocks concatenates their text.
  (should (equal "a\nb"
                 (decknix--agent-session-jsonl-user-text
                  '(((type . "text") (text . "a"))
                    ((type . "text") (text . "b"))))))
  ;; A tool_result-only message carries no user-authored text → nil, so the
  ;; caller skips it instead of starting a spurious (and non-string) turn.
  (should (null
           (decknix--agent-session-jsonl-user-text
            '(((tool_use_id . "toolu_01") (type . "tool_result")
               (content . "BUILD OK") (is_error . :json-false)))))))

(ert-deftest decknix-agent-session-history/jsonl-tool-result-not-a-turn ()
  "A user tool_result message does not create a turn and never yields a list.
The tool_result is the output of the assistant's own tool call, so the
following assistant text continues the SAME turn; the extracted user
field must always be a string."
  (let ((sid "claude-tr-sid")
        (tmp (make-temp-file "claude-history-" nil ".jsonl")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"do the build\"},\"timestamp\":\"2026-01-19T10:00:00Z\"}\n")
            (insert "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"running build\"}]},\"timestamp\":\"2026-01-19T10:00:01Z\"}\n")
            (insert "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"tool_use_id\":\"toolu_01\",\"type\":\"tool_result\",\"content\":\"BUILD OK\",\"is_error\":false}]},\"timestamp\":\"2026-01-19T10:00:02Z\"}\n")
            (insert "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"build passed\"}]},\"timestamp\":\"2026-01-19T10:00:03Z\"}\n"))
          (let ((decknix-agent-provider-registry nil))
            (decknix-agent-register-provider 'claude-code
              '(:session-file-extension ".jsonl"))
            (cl-letf (((symbol-function 'decknix--agent-session-file)
                       (lambda (_id &optional _p) tmp)))
              (let ((turns (decknix--agent-session-extract-all-turns sid 'claude-code)))
                ;; One turn only — the tool_result did not split it.
                (should (= 1 (length turns)))
                ;; User field is a STRING (regression guard for the stringp bug).
                (should (stringp (caar turns)))
                (should (equal "do the build" (caar turns)))
                ;; Assistant text before AND after the tool_result is grouped.
                (should (equal "running build\nbuild passed" (cdar turns)))))))
      (when (file-exists-p tmp) (delete-file tmp)))))

(ert-deftest decknix-agent-session-history/jsonl-user-content-text-blocks ()
  "A genuine user message whose content is a list of text blocks extracts text."
  (let ((sid "claude-tb-sid")
        (tmp (make-temp-file "claude-history-" nil ".jsonl")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hello there\"}]},\"timestamp\":\"2026-01-19T10:00:00Z\"}\n")
            (insert "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]},\"timestamp\":\"2026-01-19T10:00:01Z\"}\n"))
          (let ((decknix-agent-provider-registry nil))
            (decknix-agent-register-provider 'claude-code
              '(:session-file-extension ".jsonl"))
            (cl-letf (((symbol-function 'decknix--agent-session-file)
                       (lambda (_id &optional _p) tmp)))
              (let ((turns (decknix--agent-session-extract-all-turns sid 'claude-code)))
                (should (= 1 (length turns)))
                (should (equal "hello there" (caar turns)))
                (should (equal "hi" (cdar turns)))))))
      (when (file-exists-p tmp) (delete-file tmp)))))

;; -- Sub-agent lookup memoization -------------------------------------------
;; Guards the fix for the post-throttle sidebar stall: the sidebar repaints
;; the full live-session tree on every tick and called
;; `decknix--agent-session-subagents' once per live buffer each time; an
;; external `sample' put ~54% of main-thread CPU in that walk.  The result is
;; now memoized per session for a short window.

(ert-deftest decknix-agent-session-subagents/memoizes-within-throttle ()
  "A second lookup within the throttle window reuses the memoized result."
  (let ((decknix--agent-session-subagents-cache (make-hash-table :test 'equal))
        (decknix--agent-session-subagents-throttle 3.0)
        (calls 0))
    (cl-letf (((symbol-function 'decknix--agent-session-subagents-compute)
               (lambda (_sid _pid) (cl-incf calls) '((a . 1)))))
      (should (equal (decknix--agent-session-subagents "sid-1" 'claude-code) '((a . 1))))
      (should (equal (decknix--agent-session-subagents "sid-1" 'claude-code) '((a . 1))))
      (should (= calls 1)))))

(ert-deftest decknix-agent-session-subagents/throttle-zero-recomputes ()
  "A throttle of 0 recomputes on every call (previous behaviour)."
  (let ((decknix--agent-session-subagents-cache (make-hash-table :test 'equal))
        (decknix--agent-session-subagents-throttle 0)
        (calls 0))
    (cl-letf (((symbol-function 'decknix--agent-session-subagents-compute)
               (lambda (_sid _pid) (cl-incf calls) nil)))
      (decknix--agent-session-subagents "sid-1" 'claude-code)
      (decknix--agent-session-subagents "sid-1" 'claude-code)
      (should (= calls 2)))))

(ert-deftest decknix-agent-session-subagents/distinct-sessions-cache-separately ()
  "Different session ids are memoized under distinct keys."
  (let ((decknix--agent-session-subagents-cache (make-hash-table :test 'equal))
        (decknix--agent-session-subagents-throttle 3.0)
        (calls 0))
    (cl-letf (((symbol-function 'decknix--agent-session-subagents-compute)
               (lambda (sid _pid) (cl-incf calls) (list (cons 'sid sid)))))
      (should (equal (decknix--agent-session-subagents "sid-1" 'claude-code) '((sid . "sid-1"))))
      (should (equal (decknix--agent-session-subagents "sid-2" 'claude-code) '((sid . "sid-2"))))
      (should (= calls 2)))))

(provide 'decknix-agent-session-history-test)
