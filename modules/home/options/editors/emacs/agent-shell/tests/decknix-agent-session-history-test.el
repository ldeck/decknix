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

(provide 'decknix-agent-session-history-test)
