;;; decknix-agent-session-cache-test.el --- Tests for session cache -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)

(unless (fboundp 'decknix--agent-session-parse)
  (defun decknix--agent-session-parse (_raw) nil))

;; `decknix--session-parse-file' parses the bare single-object jq output
;; via `decknix--agent-session-parse-object' (the array parser above only
;; accepts `[...]').  The parse module isn't loaded here, so stub it.
(unless (fboundp 'decknix--agent-session-parse-object)
  (defun decknix--agent-session-parse-object (_raw) nil))

(require 'decknix-agent-session-cache)
(require 'decknix-agent-provider)

(defmacro decknix-agent-session-cache-test--with-provider (&rest body)
  `(let ((decknix-agent-provider-registry nil)
         (decknix--agent-session-jq-filter-map (make-hash-table :test 'eq))
         (decknix--agent-session-cache-map (make-hash-table :test 'eq))
         (decknix--agent-session-cache-time-map (make-hash-table :test 'eq)))
     (decknix-agent-register-provider 'test-auggie
       '(:sessions-dir "/tmp/test-sessions"
         :session-file-extension ".json"
         :session-jq-filter "{sessionId, firstUserMessage}"
         :label "Test Auggie"
         :glyph "A"
         :supports-workspace-root t))
     ,@body))

(ert-deftest decknix-agent-session-cache--jq-filter-fields ()
  (decknix-agent-session-cache-test--with-provider
    (let ((path (decknix--agent-session-ensure-jq-filter 'test-auggie)))
      (unwind-protect
          (let ((body (with-temp-buffer (insert-file-contents path) (buffer-string))))
            (should (string-match-p "sessionId" body))
            (should (string-match-p "firstUserMessage" body)))
        (when (file-exists-p path) (delete-file path))))))

(ert-deftest decknix-agent-session-cache--jq-filter-cached ()
  (decknix-agent-session-cache-test--with-provider
    (let ((p1 (decknix--agent-session-ensure-jq-filter 'test-auggie)))
      (unwind-protect
          (let ((p2 (decknix--agent-session-ensure-jq-filter 'test-auggie)))
            (should (equal p1 p2)))
        (when (file-exists-p p1) (delete-file p1))))))

(ert-deftest decknix-agent-session-cache--jq-cmd-shape ()
  (decknix-agent-session-cache-test--with-provider
    (let ((decknix--agent-session-cache-max-files 200)
          (cmd (decknix--agent-session-jq-cmd 'test-auggie)))
      (should (string-match-p "ls -t1" cmd))
      (should (string-match-p "test-sessions" cmd))
      (should (string-match-p "\\.json" cmd))
      (should (string-match-p "head -200" cmd)))))

;; ---------------------------------------------------------------------------
;; claude-code :session-jq-filter — crash-safety + first-text-block extraction
;;
;; Regression: the Claude provider filter used `.message.content[0].text',
;; which (1) crashed jq with "Cannot index string with number" on any
;; session whose user turns store `.message.content' as a plain STRING
;; (very common — plain follow-ups, forked-session preambles, tool-result
;; turns).  Because `decknix--session-parse-file' runs jq with 2>/dev/null
;; and treats empty output as "no data", a crashed session was silently
;; dropped from the list / picker / conv-key resolution.  A dropped session
;; has no firstUserMessage, so `decknix--agent-latest-session-id-for-conv-key'
;; can never match it and "restore previous session" fails with
;; "Cannot restore: no session ID".  (2) Only inspecting `content[0]' also
;; missed the first *text* block when a turn led with a tool_result/image.
;;
;; KEEP THE FILTER STRING BELOW IN SYNC with the `claude-code'
;; `:session-jq-filter' in `agent-shell.nix'.  The tests shell out to the
;; real filter so a regression there turns these red.
;; ---------------------------------------------------------------------------

(defconst decknix-agent-session-cache-test--claude-jq-filter
  "(map(select(.type == \"user\" or .type == \"assistant\")) | {sessionId: (first | .sessionId), created: (first | .timestamp), modified: (last | .timestamp), exchangeCount: (map(select(.type == \"user\")) | length), firstUserMessage: ([ .[] | select(.type == \"user\") | .message.content | if type == \"array\" then (.[] | select(.type == \"text\") | .text) else . end | select(type == \"string\" and length > 0) ] | (first // \"\"))[:200]})"
  "Mirror of the claude-code provider `:session-jq-filter' (agent-shell.nix).
Kept here so the ERT cases exercise the real filter.  Update both together.")

(defun decknix-agent-session-cache-test--jq-available-p ()
  "Return non-nil when `jq' is on PATH."
  (executable-find "jq"))

(defmacro decknix-agent-session-cache-test--with-claude-filter (&rest body)
  "Register a claude-shaped provider carrying the real filter; run BODY."
  `(let ((decknix-agent-provider-registry nil)
         (decknix--agent-session-jq-filter-map (make-hash-table :test 'eq)))
     (decknix-agent-register-provider 'test-claude-filter
       (list :sessions-dir "/tmp/test-claude-filter"
             :session-file-extension ".jsonl"
             :history-file "/tmp/test-claude-filter/history.jsonl"
             :session-jq-filter decknix-agent-session-cache-test--claude-jq-filter
             :label "Test Claude" :glyph "C"))
     ,@body))

(defun decknix-agent-session-cache-test--run-claude-filter (jsonl)
  "Write JSONL to a tmp file, run the real filter via slurped `jq'.
Returns a plist (:exit CODE :out STRING).  Mirrors the production
invocation shape (`jq -Mcs -f FILTER FILE') so a crash surfaces as a
non-zero exit code."
  (let ((fixture (make-temp-file "decknix-claude-" nil ".jsonl"))
        (filter (decknix--agent-session-ensure-jq-filter 'test-claude-filter)))
    (unwind-protect
        (progn
          (with-temp-file fixture (insert jsonl))
          (with-temp-buffer
            (let ((code (call-process "jq" nil t nil "-Mcs" "-f" filter fixture)))
              (list :exit code :out (buffer-string)))))
      (when (file-exists-p fixture) (delete-file fixture))
      (when (and filter (file-exists-p filter)) (delete-file filter)))))

(ert-deftest decknix-claude-jq-filter--survives-string-content ()
  "A user turn whose `.message.content' is a plain string must not crash
jq (regression: `.message.content[0]' aborted the whole program, dropping
the session)."
  (skip-unless (decknix-agent-session-cache-test--jq-available-p))
  (decknix-agent-session-cache-test--with-claude-filter
    (let* ((jsonl (concat
                   "{\"type\":\"user\",\"sessionId\":\"sid-1\",\"timestamp\":\"t0\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"HELLO FIRST\"}]}}\n"
                   "{\"type\":\"assistant\",\"sessionId\":\"sid-1\",\"timestamp\":\"t1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}\n"
                   "{\"type\":\"user\",\"sessionId\":\"sid-1\",\"timestamp\":\"t2\",\"message\":{\"role\":\"user\",\"content\":\"a plain string turn\"}}\n"
                   "{\"type\":\"user\",\"sessionId\":\"sid-1\",\"timestamp\":\"t3\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"x\",\"content\":\"out\"}]}}\n"))
           (res (decknix-agent-session-cache-test--run-claude-filter jsonl)))
      (should (= (plist-get res :exit) 0))
      (let ((obj (json-parse-string (plist-get res :out) :object-type 'alist)))
        (should (equal (alist-get 'sessionId obj) "sid-1"))
        (should (equal (alist-get 'firstUserMessage obj) "HELLO FIRST"))
        (should (= (alist-get 'exchangeCount obj) 3))))))

(ert-deftest decknix-claude-jq-filter--scans-past-nontext-lead-block ()
  "firstUserMessage is the first *text* block, skipping a leading
tool_result turn (regression: `content[0]' only saw the lead block)."
  (skip-unless (decknix-agent-session-cache-test--jq-available-p))
  (decknix-agent-session-cache-test--with-claude-filter
    (let* ((jsonl (concat
                   "{\"type\":\"user\",\"sessionId\":\"sid-2\",\"timestamp\":\"t0\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"x\",\"content\":\"o\"}]}}\n"
                   "{\"type\":\"user\",\"sessionId\":\"sid-2\",\"timestamp\":\"t1\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"REAL PROMPT\"}]}}\n"))
           (res (decknix-agent-session-cache-test--run-claude-filter jsonl)))
      (should (= (plist-get res :exit) 0))
      (let ((obj (json-parse-string (plist-get res :out) :object-type 'alist)))
        (should (equal (alist-get 'firstUserMessage obj) "REAL PROMPT"))))))

(ert-deftest decknix-claude-jq-filter--string-first-turn-used-verbatim ()
  "When the first user turn's content is a bare string, it is used as-is."
  (skip-unless (decknix-agent-session-cache-test--jq-available-p))
  (decknix-agent-session-cache-test--with-claude-filter
    (let* ((jsonl "{\"type\":\"user\",\"sessionId\":\"sid-3\",\"timestamp\":\"t0\",\"message\":{\"role\":\"user\",\"content\":\"bare string prompt\"}}\n")
           (res (decknix-agent-session-cache-test--run-claude-filter jsonl)))
      (should (= (plist-get res :exit) 0))
      (let ((obj (json-parse-string (plist-get res :out) :object-type 'alist)))
        (should (equal (alist-get 'firstUserMessage obj) "bare string prompt"))))))

(ert-deftest decknix-session-meta--cache-hit ()
  (let ((decknix--session-meta-cache (make-hash-table :test 'equal))
        (parse-called 0))
    (puthash "/tmp/test.json" (list :mtime 1000.0 :data '((sessionId . "abc"))) decknix--session-meta-cache)
    (cl-letf (((symbol-function 'decknix--session-file-mtime) (lambda (_p) 1000.0))
              ((symbol-function 'decknix--session-parse-file) (lambda (_provider _p) (cl-incf parse-called) nil)))
      (let ((result (decknix--session-meta 'test-auggie "/tmp/test.json")))
        (should (equal result '((sessionId . "abc"))))
        (should (= parse-called 0))))))

(ert-deftest decknix-session-meta--cache-miss-reparses ()
  (let ((decknix--session-meta-cache (make-hash-table :test 'equal))
        (parse-called 0))
    (puthash "/tmp/test.json" (list :mtime 999.0 :data '((sessionId . "old"))) decknix--session-meta-cache)
    (cl-letf (((symbol-function 'decknix--session-file-mtime) (lambda (_p) 1001.0))
              ((symbol-function 'decknix--session-parse-file) (lambda (_provider _p) (cl-incf parse-called) '((sessionId . "new")))))
      (let ((result (decknix--session-meta 'test-auggie "/tmp/test.json")))
        ;; Phase 1.3: providerId is stamped on cache-miss parse
        (should (equal (alist-get 'sessionId result) "new"))
        (should (eq (alist-get 'providerId result) 'test-auggie))
        (should (= parse-called 1))
        (let ((entry (gethash "/tmp/test.json" decknix--session-meta-cache)))
          (should (= (plist-get entry :mtime) 1001.0))
          (should (equal (alist-get 'sessionId (plist-get entry :data)) "new"))
          (should (eq (alist-get 'providerId (plist-get entry :data)) 'test-auggie)))))))

(ert-deftest decknix-session-meta--stamps-provider-id ()
  "Phase 1.3: providerId is stamped on data when entering the cache."
  (let ((decknix--session-meta-cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'decknix--session-file-mtime) (lambda (_p) 1234.0))
              ((symbol-function 'decknix--session-parse-file)
               (lambda (_p _path) '((sessionId . "sid-001") (firstUserMessage . "hello")))))
      (let ((result (decknix--session-meta 'claude-code "/tmp/sid-001.jsonl")))
        (should (equal (alist-get 'sessionId result) "sid-001"))
        (should (eq (alist-get 'providerId result) 'claude-code))))))

(ert-deftest decknix-session-meta--throttles-reparse-of-recently-parsed-changed-file ()
  "A changed file re-parsed within the throttle window serves stale cached data.
Guards the fix for the sidebar-refresh stall: an actively-streaming
session's JSONL changes on every token, and re-slurping it through `jq'
on each refresh saturated the main thread."
  (let ((decknix--session-meta-cache (make-hash-table :test 'equal))
        (decknix--session-meta-reparse-throttle 4.0)
        (parse-called 0))
    (puthash "/tmp/test.json"
             (list :mtime 999.0 :data '((sessionId . "old")) :parsed-at (float-time))
             decknix--session-meta-cache)
    (cl-letf (((symbol-function 'decknix--session-file-mtime) (lambda (_p) 1001.0))
              ((symbol-function 'decknix--session-parse-file)
               (lambda (_provider _p) (cl-incf parse-called) '((sessionId . "new")))))
      (let ((result (decknix--session-meta 'test-auggie "/tmp/test.json")))
        (should (equal (alist-get 'sessionId result) "old"))
        (should (= parse-called 0))))))

(ert-deftest decknix-session-meta--reparses-changed-file-past-throttle-window ()
  "A changed file whose last parse predates the throttle window re-parses."
  (let ((decknix--session-meta-cache (make-hash-table :test 'equal))
        (decknix--session-meta-reparse-throttle 4.0)
        (parse-called 0))
    (puthash "/tmp/test.json"
             (list :mtime 999.0 :data '((sessionId . "old"))
                   :parsed-at (- (float-time) 3600))
             decknix--session-meta-cache)
    (cl-letf (((symbol-function 'decknix--session-file-mtime) (lambda (_p) 1001.0))
              ((symbol-function 'decknix--session-parse-file)
               (lambda (_provider _p) (cl-incf parse-called) '((sessionId . "new")))))
      (let ((result (decknix--session-meta 'test-auggie "/tmp/test.json")))
        (should (equal (alist-get 'sessionId result) "new"))
        (should (= parse-called 1))
        ;; A fresh parse re-stamps parsed-at (and mtime) so subsequent churn
        ;; is throttled again from now.
        (let ((entry (gethash "/tmp/test.json" decknix--session-meta-cache)))
          (should (plist-get entry :parsed-at))
          (should (= (plist-get entry :mtime) 1001.0)))))))

(ert-deftest decknix-session-meta--throttle-zero-always-reparses ()
  "A throttle of 0 restores the previous always-reparse-on-change behaviour."
  (let ((decknix--session-meta-cache (make-hash-table :test 'equal))
        (decknix--session-meta-reparse-throttle 0)
        (parse-called 0))
    (puthash "/tmp/test.json"
             (list :mtime 999.0 :data '((sessionId . "old")) :parsed-at (float-time))
             decknix--session-meta-cache)
    (cl-letf (((symbol-function 'decknix--session-file-mtime) (lambda (_p) 1001.0))
              ((symbol-function 'decknix--session-parse-file)
               (lambda (_provider _p) (cl-incf parse-called) '((sessionId . "new")))))
      (should (equal (alist-get 'sessionId
                                (decknix--session-meta 'test-auggie "/tmp/test.json"))
                     "new"))
      (should (= parse-called 1)))))

(defmacro decknix-agent-session-cache-test--with-multi-provider (&rest body)
  "Register auggie + a claude-like provider so the all-providers path runs."
  `(let ((decknix-agent-provider-registry nil)
         (decknix-agent-default-provider 'test-auggie)
         (decknix--agent-session-jq-filter-map (make-hash-table :test 'eq))
         (decknix--agent-session-cache-map (make-hash-table :test 'eq))
         (decknix--agent-session-cache-time-map (make-hash-table :test 'eq)))
     (decknix-agent-register-provider 'test-auggie
       '(:sessions-dir "/tmp/test-sessions"
         :session-file-extension ".json"
         :label "Test Auggie"
         :glyph "A"
         :supports-workspace-root t))
     (decknix-agent-register-provider 'test-claude
       '(:sessions-dir "/tmp/test-claude"
         :session-file-extension ".jsonl"
         :history-file "/tmp/test-claude/history.jsonl"
         :label "Test Claude"
         :glyph "C"))
     ,@body))

(ert-deftest decknix-agent-provider-for-session--uses-cache-no-refresh ()
  "Resolving a cached session must not trigger any metadata refresh.
This pins the resume-path stall regression: the lookup used to call
`decknix--agent-session-list' (all providers), forcing a synchronous
jq re-parse of every other backend's transcripts on a cold cache."
  (decknix-agent-session-cache-test--with-multi-provider
    (let ((refresh-called 0))
      (puthash 'test-auggie '(((sessionId . "sid-A")))
               decknix--agent-session-cache-map)
      (cl-letf (((symbol-function 'decknix--agent-session-refresh-sync)
                 (lambda (&rest _) (cl-incf refresh-called) nil))
                ((symbol-function 'decknix--agent-session-refresh-async)
                 (lambda (&rest _) (cl-incf refresh-called) nil)))
        (should (eq (decknix--agent-provider-for-session-id "sid-A")
                    'test-auggie))
        (should (= refresh-called 0))))))

(ert-deftest decknix-agent-provider-for-session--falls-back-without-refresh ()
  "An unknown session falls back to the default provider, no refresh,
no transcript parsing (empty disk probe)."
  (decknix-agent-session-cache-test--with-multi-provider
    (let ((refresh-called 0))
      (cl-letf (((symbol-function 'decknix--agent-session-refresh-sync)
                 (lambda (&rest _) (cl-incf refresh-called) nil))
                ((symbol-function 'decknix--agent-session-refresh-async)
                 (lambda (&rest _) (cl-incf refresh-called) nil))
                ((symbol-function 'decknix--agent-session-file)
                 (lambda (&rest _) "")))
        (should (eq (decknix--agent-provider-for-session-id "missing")
                    'test-auggie))
        (should (= refresh-called 0))))))

(ert-deftest decknix-agent-provider-for-session--probes-disk-no-parse ()
  "Cold cache: resolve a non-default session by cheap file existence,
never by parsing transcripts or refreshing the cache."
  (decknix-agent-session-cache-test--with-multi-provider
    (let ((refresh-called 0))
      (cl-letf (((symbol-function 'decknix--agent-session-refresh-sync)
                 (lambda (&rest _) (cl-incf refresh-called) nil))
                ((symbol-function 'decknix--agent-session-refresh-async)
                 (lambda (&rest _) (cl-incf refresh-called) nil))
                ((symbol-function 'decknix--agent-session-file)
                 (lambda (_sid p-id)
                   (if (eq p-id 'test-claude) "/tmp/exists.jsonl" "")))
                ((symbol-function 'file-exists-p)
                 (lambda (f) (string= f "/tmp/exists.jsonl"))))
        (should (eq (decknix--agent-provider-for-session-id "sid-X")
                    'test-claude))
        (should (= refresh-called 0))))))

;; ---------------------------------------------------------------------------
;; Non-blocking accessor + refresh hook (the "C-c b / sidebar must never
;; block, take last-known status, and self-heal when the async scan lands").
;; ---------------------------------------------------------------------------

(ert-deftest decknix-session-warm-or-async--cold-returns-nil-defers-refresh ()
  "A cold cache never blocks: returns nil, never touches the sync OR the
inline async parse, and DEFERS a background refresh for every provider.
The deferral (idle timer) is what keeps a cold `C-c b' instant even though
`refresh-async' itself can parse a small new-file set synchronously."
  (decknix-agent-session-cache-test--with-multi-provider
    (let ((sync-called 0) (inline-async 0) (scheduled nil)
          (decknix--agent-session-refresh-pending (make-hash-table :test 'eq)))
      (cl-letf (((symbol-function 'decknix--agent-session-refresh-sync)
                 (lambda (&rest _) (cl-incf sync-called) nil))
                ((symbol-function 'decknix--agent-session-refresh-async)
                 (lambda (&rest _) (cl-incf inline-async) nil))
                ((symbol-function 'decknix--agent-session-schedule-refresh)
                 (lambda (p) (push p scheduled) nil)))
        (should (null (decknix--agent-session-list-warm-or-async)))
        (should (= sync-called 0))
        ;; Nothing parsed inline; a deferred refresh scheduled per provider.
        (should (= inline-async 0))
        (should (= (length scheduled) 2))
        (should (memq 'test-auggie scheduled))
        (should (memq 'test-claude scheduled))))))

(ert-deftest decknix-session-warm-or-async--warm-fresh-no-refresh ()
  "A warm, fresh cache returns cached data with no refresh of any kind."
  (decknix-agent-session-cache-test--with-multi-provider
    (let ((sync-called 0) (scheduled 0)
          (now (float-time)))
      (puthash 'test-auggie '(((sessionId . "sid-A") (modified . "2026-01-02")))
               decknix--agent-session-cache-map)
      (puthash 'test-claude '(((sessionId . "sid-C") (modified . "2026-01-01")))
               decknix--agent-session-cache-map)
      (puthash 'test-auggie now decknix--agent-session-cache-time-map)
      (puthash 'test-claude now decknix--agent-session-cache-time-map)
      (cl-letf (((symbol-function 'decknix--agent-session-refresh-sync)
                 (lambda (&rest _) (cl-incf sync-called) nil))
                ((symbol-function 'decknix--agent-session-schedule-refresh)
                 (lambda (&rest _) (cl-incf scheduled) nil)))
        (let ((result (decknix--agent-session-list-warm-or-async)))
          (should (= (length result) 2))
          (should (= sync-called 0))
          (should (= scheduled 0)))))))

(ert-deftest decknix-session-warm-or-async--stale-returns-cached-defers-refresh ()
  "A warm but stale cache returns the cached data immediately AND schedules
a deferred background refresh (never blocks on a sync scan)."
  (decknix-agent-session-cache-test--with-multi-provider
    (let ((sync-called 0) (scheduled 0)
          (stale (- (float-time) (* 10 decknix--agent-session-cache-ttl))))
      (puthash 'test-auggie '(((sessionId . "sid-A") (modified . "2026-01-02")))
               decknix--agent-session-cache-map)
      (puthash 'test-auggie stale decknix--agent-session-cache-time-map)
      (puthash 'test-claude stale decknix--agent-session-cache-time-map)
      (cl-letf (((symbol-function 'decknix--agent-session-refresh-sync)
                 (lambda (&rest _) (cl-incf sync-called) nil))
                ((symbol-function 'decknix--agent-session-schedule-refresh)
                 (lambda (&rest _) (cl-incf scheduled) nil)))
        (let ((result (decknix--agent-session-list-warm-or-async)))
          (should (>= (length result) 1))
          (should (= sync-called 0))
          (should (> scheduled 0)))))))

(ert-deftest decknix-session-schedule-refresh--dedups-per-provider ()
  "Repeated schedule calls for a provider arm at most one timer until it
fires (so a burst of decoration calls never stacks dozens of refreshes)."
  (let ((decknix--agent-session-refresh-pending (make-hash-table :test 'eq))
        (armed 0))
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (&rest _) (cl-incf armed) nil)))
      (decknix--agent-session-schedule-refresh 'test-auggie)
      (decknix--agent-session-schedule-refresh 'test-auggie)
      (decknix--agent-session-schedule-refresh 'test-auggie)
      ;; One timer armed; the provider is marked pending.
      (should (= armed 1))
      (should (gethash 'test-auggie decknix--agent-session-refresh-pending)))))

(ert-deftest decknix-session-refresh-hook--runs-all-swallows-errors ()
  "The refresh hook runs every listener and one failing listener never
aborts the others (so a bad UI listener can't break cache refreshes)."
  (let ((decknix-agent-session-cache-refresh-functions nil)
        (ran nil))
    (add-hook 'decknix-agent-session-cache-refresh-functions
              (lambda () (push 'a ran)))
    (add-hook 'decknix-agent-session-cache-refresh-functions
              (lambda () (error "boom")))
    (add-hook 'decknix-agent-session-cache-refresh-functions
              (lambda () (push 'c ran)))
    (decknix--agent-session-cache-run-refresh-hook)
    (should (memq 'a ran))
    (should (memq 'c ran))))

;; ---------------------------------------------------------------------------
;; Claude mtime-cache regression tests (NC-XXXX: multi-project sessions
;; were never written to the persistent mtime cache because
;; decknix--session-store-parsed skipped them when :history-file was set,
;; causing every 120s refresh to re-parse all JSONL transcripts).
;; ---------------------------------------------------------------------------

(ert-deftest decknix-session-parse-file--stamps-file-path ()
  "decknix--session-parse-file stamps (filePath . PATH) on result."
  (decknix-agent-session-cache-test--with-provider
    (cl-letf (((symbol-function 'decknix--agent-session-ensure-jq-filter)
               (lambda (_) "/tmp/dummy.jq"))
              ((symbol-function 'shell-command-to-string)
               (lambda (_) "{\"sessionId\":\"sid-42\"}"))
              ((symbol-function 'decknix--agent-session-parse-object)
               (lambda (raw) (ignore raw) '((sessionId . "sid-42")))))
      (let ((result (decknix--session-parse-file 'test-auggie "/tmp/sid-42.json")))
        (should (equal (alist-get 'sessionId result) "sid-42"))
        (should (equal (alist-get 'filePath result) "/tmp/sid-42.json"))))))

(ert-deftest decknix-session-stamp-file-paths--matches-by-sid ()
  "decknix--session-stamp-file-paths stamps filePath on each alist
by matching (file-name-base path) against sessionId."
  (let ((parsed (list '((sessionId . "abc")) '((sessionId . "def"))))
        (files  (list "/project/a/abc.jsonl" "/project/b/def.jsonl")))
    (let ((stamped (decknix--session-stamp-file-paths parsed files)))
      (should (equal (alist-get 'filePath (nth 0 stamped)) "/project/a/abc.jsonl"))
      (should (equal (alist-get 'filePath (nth 1 stamped)) "/project/b/def.jsonl")))))

(ert-deftest decknix-session-stamp-file-paths--skips-already-stamped ()
  "decknix--session-stamp-file-paths does not overwrite an existing filePath."
  (let ((parsed (list '((sessionId . "abc") (filePath . "/existing/abc.jsonl"))))
        (files  (list "/other/abc.jsonl")))
    (let ((stamped (decknix--session-stamp-file-paths parsed files)))
      (should (equal (alist-get 'filePath (car stamped)) "/existing/abc.jsonl")))))

(defmacro decknix-agent-session-cache-test--with-claude-provider (&rest body)
  "Register a claude-like provider (has :history-file) for cache tests."
  `(let ((decknix-agent-provider-registry nil)
         (decknix-agent-default-provider 'test-claude)
         (decknix--agent-session-jq-filter-map (make-hash-table :test 'eq))
         (decknix--agent-session-cache-map (make-hash-table :test 'eq))
         (decknix--agent-session-cache-time-map (make-hash-table :test 'eq))
         (decknix--session-meta-cache (make-hash-table :test 'equal)))
     (decknix-agent-register-provider 'test-claude
       '(:sessions-dir "/tmp/test-claude/projects"
         :session-file-extension ".jsonl"
         :history-file "/tmp/test-claude/history.jsonl"
         :label "Test Claude"
         :glyph "C"))
     ,@body))

(ert-deftest decknix-session-store-parsed--caches-claude-session-with-file-path ()
  "decknix--session-store-parsed writes Claude sessions to the mtime
cache when the alist carries a (filePath . PATH) entry.  Without this
fix the entry was silently dropped (hist set → path nil → skipped),
causing Claude sessions to be re-parsed on every 120s refresh."
  (decknix-agent-session-cache-test--with-claude-provider
    (cl-letf (((symbol-function 'decknix--session-file-mtime)
               (lambda (p) (when (string= p "/tmp/test-claude/projects/ph/sid-99.jsonl") 2000.0))))
      (decknix--session-store-parsed
       'test-claude
       (list '((sessionId . "sid-99")
               (filePath . "/tmp/test-claude/projects/ph/sid-99.jsonl"))))
      (let ((entry (gethash "/tmp/test-claude/projects/ph/sid-99.jsonl"
                            decknix--session-meta-cache)))
        (should entry)
        (should (= (plist-get entry :mtime) 2000.0))
        (should (equal (alist-get 'sessionId (plist-get entry :data)) "sid-99"))))))

(ert-deftest decknix-session-store-parsed--skips-claude-session-without-file-path ()
  "Without filePath on a multi-project (claude-code) session alist,
decknix--session-store-parsed skips the entry (no path can be
reconstructed from sessionId + dir alone for nested project dirs).
This is expected behaviour -- callers must stamp filePath first."
  (decknix-agent-session-cache-test--with-claude-provider
    (cl-letf (((symbol-function 'decknix--session-file-mtime) (lambda (_) 9999.0)))
      (decknix--session-store-parsed
       'test-claude
       (list '((sessionId . "sid-orphan"))))  ; no filePath
      (should (= (hash-table-count decknix--session-meta-cache) 0)))))

(ert-deftest decknix-session-store-parsed--still-caches-single-dir-provider ()
  "For single-directory providers (auggie, no :history-file), the
fallback path (sessionId + dir + ext) still writes to the mtime cache."
  (decknix-agent-session-cache-test--with-provider
    (cl-letf (((symbol-function 'decknix--session-file-mtime)
               (lambda (p)
                 (when (string= p "/tmp/test-sessions/sid-01.json") 1234.0))))
      (decknix--session-store-parsed
       'test-auggie
       (list '((sessionId . "sid-01"))))  ; no filePath -- fallback path used
      (let ((entry (gethash "/tmp/test-sessions/sid-01.json"
                            decknix--session-meta-cache)))
        (should entry)
        (should (= (plist-get entry :mtime) 1234.0))))))

(ert-deftest decknix-agent-session-cache--list-syncs-on-first-call ()
  (decknix-agent-session-cache-test--with-provider
    (let ((sync-called 0))
      (cl-letf (((symbol-function 'decknix--agent-session-refresh-sync)
                 (lambda (p-id)
                   (cl-incf sync-called)
                   (puthash p-id '((stub)) decknix--agent-session-cache-map)
                   (puthash p-id (float-time) decknix--agent-session-cache-time-map)
                   '((stub))))
                ((symbol-function 'decknix--agent-session-refresh-async) (lambda (&rest _args) nil)))
        (let ((result (decknix--agent-session-list 'test-auggie)))
          (should (= sync-called 1))
          ;; The reader stamps providerId on every returned session so
          ;; the picker/grep/sidebar can render a glyph + filter.
          (should (eq (alist-get 'providerId (car result)) 'test-auggie)))))))

;; ---------------------------------------------------------------------------
;; providerId stamping — the list-refresh parse paths stamp filePath but
;; NOT providerId (only decknix--session-meta does, and only compose-history
;; uses that).  decknix--agent-session-list must guarantee providerId so
;; glyph rendering + provider filtering work in the pickers.
;; ---------------------------------------------------------------------------

(ert-deftest decknix-session-stamp-provider-id--stamps-missing ()
  "Sessions lacking providerId get it; those with it are untouched."
  (let* ((a '((sessionId . "a")))
         (b '((sessionId . "b") (providerId . claude-code)))
         (out (decknix--session-stamp-provider-id 'auggie (list a b))))
    (should (eq (alist-get 'providerId (nth 0 out)) 'auggie))
    ;; Pre-existing providerId is preserved, not overwritten.
    (should (eq (alist-get 'providerId (nth 1 out)) 'claude-code))))

(ert-deftest decknix-agent-session-list--stamps-provider-id-and-writes-back ()
  "A warm cache of unstamped sessions is stamped on read + written back."
  (decknix-agent-session-cache-test--with-provider
    ;; Warm cache: entries lack providerId, cache-time is fresh so no
    ;; refresh runs.
    (puthash 'test-auggie
             (list '((sessionId . "s1")) '((sessionId . "s2")))
             decknix--agent-session-cache-map)
    (puthash 'test-auggie (float-time) decknix--agent-session-cache-time-map)
    (let ((result (decknix--agent-session-list 'test-auggie)))
      (should (eq (alist-get 'providerId (nth 0 result)) 'test-auggie))
      (should (eq (alist-get 'providerId (nth 1 result)) 'test-auggie))
      ;; Written back: the cache map now holds the stamped list too.
      (should (eq (alist-get 'providerId
                             (car (gethash 'test-auggie
                                           decknix--agent-session-cache-map)))
                  'test-auggie)))))

;; ---------------------------------------------------------------------------
;; decknix--session-list-files — native filesystem walk (D2)
;;
;; Pin the observable contract of the file lister so we can swap the
;; implementation from `ls -t | head' / `find | xargs' shell-outs to
;; native Emacs traversal (`directory-files' + a depth-bounded walker)
;; without behaviour drift.  Two shapes are covered:
;;
;;   1. Single-directory providers (auggie): scan `sessions-dir' for the
;;      configured extension, sort newest-first, respect MAX.
;;   2. Multi-project providers (claude, `:history-file' set): walk two
;;      levels deep so `<sessions-dir>/<project-hash>/<sid>.jsonl' files
;;      are picked up; a nested-3 file must be ignored.
;;
;; Tests use a per-test tmp dir so nothing touches ~/.augment or ~/.claude.
;; ---------------------------------------------------------------------------

(defmacro decknix-agent-session-cache-test--with-tmp-dir (var &rest body)
  "Bind VAR to a fresh temp dir, run BODY, then remove it recursively.
Shadows `decknix--session-list-files-cache' so caching tests can't leak
into each other."
  (declare (indent 1))
  `(let ((,var (make-temp-file "decknix-list-files-" t))
         (decknix--session-list-files-cache (make-hash-table :test 'eq)))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun decknix-agent-session-cache-test--touch (path mtime)
  "Create PATH (making parent dirs) and set its mtime to MTIME (float)."
  (let ((dir (file-name-directory path)))
    (unless (file-exists-p dir) (make-directory dir t)))
  (write-region "" nil path nil 'quiet)
  (set-file-times path (seconds-to-time mtime)))

(ert-deftest decknix-session-list-files--single-dir-sorted-newest-first ()
  "Single-dir provider (auggie shape): returns .json files newest-first."
  (decknix-agent-session-cache-test--with-tmp-dir tmp
    (let ((decknix-agent-provider-registry nil))
      (decknix-agent-register-provider 'test-auggie
        `(:sessions-dir ,tmp
          :session-file-extension ".json"
          :label "T" :glyph "A"))
      (decknix-agent-session-cache-test--touch
       (expand-file-name "old.json" tmp) 1000.0)
      (decknix-agent-session-cache-test--touch
       (expand-file-name "mid.json" tmp) 2000.0)
      (decknix-agent-session-cache-test--touch
       (expand-file-name "new.json" tmp) 3000.0)
      ;; A non-matching extension is filtered out.
      (decknix-agent-session-cache-test--touch
       (expand-file-name "skip.txt"  tmp) 4000.0)
      (let ((paths (decknix--session-list-files 'test-auggie)))
        (should (equal (mapcar #'file-name-nondirectory paths)
                       '("new.json" "mid.json" "old.json")))))))

(ert-deftest decknix-session-list-files--single-dir-honours-max ()
  "MAX caps the returned count (newest-first)."
  (decknix-agent-session-cache-test--with-tmp-dir tmp
    (let ((decknix-agent-provider-registry nil))
      (decknix-agent-register-provider 'test-auggie
        `(:sessions-dir ,tmp
          :session-file-extension ".json"
          :label "T" :glyph "A"))
      (dotimes (i 5)
        (decknix-agent-session-cache-test--touch
         (expand-file-name (format "s%d.json" i) tmp)
         (+ 1000.0 (* i 100))))
      (let ((paths (decknix--session-list-files 'test-auggie 2)))
        (should (= (length paths) 2))
        (should (equal (mapcar #'file-name-nondirectory paths)
                       '("s4.json" "s3.json")))))))

(ert-deftest decknix-session-list-files--missing-dir-returns-empty ()
  "A missing sessions dir returns an empty list, not an error."
  (let ((decknix-agent-provider-registry nil))
    (decknix-agent-register-provider 'test-auggie
      '(:sessions-dir "/tmp/does-not-exist-decknix-test-XYZ"
        :session-file-extension ".json"
        :label "T" :glyph "A"))
    (should (equal (decknix--session-list-files 'test-auggie) nil))))

(ert-deftest decknix-session-list-files--multi-project-depth-2 ()
  "Multi-project provider (claude shape, :history-file set): walks 2 deep.
Depth-2 .jsonl files (`<dir>/<project>/<sid>.jsonl') are returned;
depth-3 files must not appear."
  (decknix-agent-session-cache-test--with-tmp-dir tmp
    (let ((decknix-agent-provider-registry nil))
      (decknix-agent-register-provider 'test-claude
        `(:sessions-dir ,tmp
          :session-file-extension ".jsonl"
          :history-file "/tmp/history.jsonl"
          :label "T" :glyph "C"))
      ;; Two projects, one session each at depth 2.
      (decknix-agent-session-cache-test--touch
       (expand-file-name "proj-a/sid-1.jsonl" tmp) 1000.0)
      (decknix-agent-session-cache-test--touch
       (expand-file-name "proj-b/sid-2.jsonl" tmp) 2000.0)
      ;; Depth-3 nested session must be ignored.
      (decknix-agent-session-cache-test--touch
       (expand-file-name "proj-a/nested/sid-3.jsonl" tmp) 3000.0)
      ;; Extension filter still applies at depth 2.
      (decknix-agent-session-cache-test--touch
       (expand-file-name "proj-b/skip.txt" tmp) 4000.0)
      (let ((paths (decknix--session-list-files 'test-claude)))
        (should (equal (mapcar #'file-name-nondirectory paths)
                       '("sid-2.jsonl" "sid-1.jsonl")))))))

(ert-deftest decknix-session-list-files--multi-project-honours-max ()
  "MAX caps the multi-project walk (newest-first)."
  (decknix-agent-session-cache-test--with-tmp-dir tmp
    (let ((decknix-agent-provider-registry nil))
      (decknix-agent-register-provider 'test-claude
        `(:sessions-dir ,tmp
          :session-file-extension ".jsonl"
          :history-file "/tmp/history.jsonl"
          :label "T" :glyph "C"))
      (dotimes (i 4)
        (decknix-agent-session-cache-test--touch
         (expand-file-name (format "proj/%d.jsonl" i) tmp)
         (+ 1000.0 (* i 100))))
      (let ((paths (decknix--session-list-files 'test-claude 2)))
        (should (= (length paths) 2))
        (should (equal (mapcar #'file-name-nondirectory paths)
                       '("3.jsonl" "2.jsonl")))))))

;; ---------------------------------------------------------------------------
;; decknix--session-list-files — fingerprint cache (D re-eval)
;;
;; When the sessions dir hasn't changed between calls, `-list-files' must
;; skip the sort pass and return the exact same list (same cons identity)
;; from a small per-provider cache keyed on a `(count . max-mtime)'
;; fingerprint.  The fingerprint invalidates whenever ANY file is added,
;; removed, or touched — no observable staleness may slip through.
;;
;; These tests pin the behavioural contract; the actual perf win
;; (skipping O(N log N) sort + O(N) `file-attributes' round-trips) is
;; a side effect of the same code path being taken.
;; ---------------------------------------------------------------------------

(ert-deftest decknix-session-list-files--cache-eq-when-unchanged ()
  "Two back-to-back calls with no fs changes return the same cons cell."
  (decknix-agent-session-cache-test--with-tmp-dir tmp
    (let ((decknix-agent-provider-registry nil))
      (decknix-agent-register-provider 'test-auggie
        `(:sessions-dir ,tmp
          :session-file-extension ".json"
          :label "T" :glyph "A"))
      (decknix-agent-session-cache-test--touch
       (expand-file-name "a.json" tmp) 1000.0)
      (decknix-agent-session-cache-test--touch
       (expand-file-name "b.json" tmp) 2000.0)
      (let ((r1 (decknix--session-list-files 'test-auggie))
            (r2 (decknix--session-list-files 'test-auggie)))
        (should (eq r1 r2))))))

(ert-deftest decknix-session-list-files--cache-invalidates-on-new-file ()
  "Adding a new file after the first call must be reflected in the second."
  (decknix-agent-session-cache-test--with-tmp-dir tmp
    (let ((decknix-agent-provider-registry nil))
      (decknix-agent-register-provider 'test-auggie
        `(:sessions-dir ,tmp
          :session-file-extension ".json"
          :label "T" :glyph "A"))
      (decknix-agent-session-cache-test--touch
       (expand-file-name "old.json" tmp) 1000.0)
      (let ((r1 (decknix--session-list-files 'test-auggie)))
        (should (equal (mapcar #'file-name-nondirectory r1)
                       '("old.json"))))
      (decknix-agent-session-cache-test--touch
       (expand-file-name "new.json" tmp) 3000.0)
      (let ((r2 (decknix--session-list-files 'test-auggie)))
        (should (equal (mapcar #'file-name-nondirectory r2)
                       '("new.json" "old.json")))))))

(ert-deftest decknix-session-list-files--cache-invalidates-on-mtime-bump ()
  "Touching an existing file (count unchanged, max-mtime bumps) invalidates."
  (decknix-agent-session-cache-test--with-tmp-dir tmp
    (let ((decknix-agent-provider-registry nil))
      (decknix-agent-register-provider 'test-auggie
        `(:sessions-dir ,tmp
          :session-file-extension ".json"
          :label "T" :glyph "A"))
      (decknix-agent-session-cache-test--touch
       (expand-file-name "a.json" tmp) 1000.0)
      (decknix-agent-session-cache-test--touch
       (expand-file-name "b.json" tmp) 2000.0)
      (let ((r1 (decknix--session-list-files 'test-auggie)))
        (should (equal (mapcar #'file-name-nondirectory r1)
                       '("b.json" "a.json"))))
      ;; Bump a.json past b.json — order must flip.
      (decknix-agent-session-cache-test--touch
       (expand-file-name "a.json" tmp) 5000.0)
      (let ((r2 (decknix--session-list-files 'test-auggie)))
        (should (equal (mapcar #'file-name-nondirectory r2)
                       '("a.json" "b.json")))))))

(ert-deftest decknix-session-list-files--cache-invalidates-on-deletion ()
  "Deleting a file (count drops) invalidates the cache."
  (decknix-agent-session-cache-test--with-tmp-dir tmp
    (let ((decknix-agent-provider-registry nil))
      (decknix-agent-register-provider 'test-auggie
        `(:sessions-dir ,tmp
          :session-file-extension ".json"
          :label "T" :glyph "A"))
      (decknix-agent-session-cache-test--touch
       (expand-file-name "a.json" tmp) 1000.0)
      (decknix-agent-session-cache-test--touch
       (expand-file-name "b.json" tmp) 2000.0)
      (let ((r1 (decknix--session-list-files 'test-auggie)))
        (should (= (length r1) 2)))
      (delete-file (expand-file-name "a.json" tmp))
      (let ((r2 (decknix--session-list-files 'test-auggie)))
        (should (equal (mapcar #'file-name-nondirectory r2)
                       '("b.json")))))))

(ert-deftest decknix-session-list-files--cache-per-provider ()
  "Cache entries are keyed by provider-id — one provider's churn
does not invalidate the other's cached list."
  (decknix-agent-session-cache-test--with-tmp-dir tmp
    (let* ((decknix-agent-provider-registry nil)
           (dir-a (expand-file-name "a" tmp))
           (dir-b (expand-file-name "b" tmp)))
      (make-directory dir-a t)
      (make-directory dir-b t)
      (decknix-agent-register-provider 'test-a
        `(:sessions-dir ,dir-a
          :session-file-extension ".json"
          :label "A" :glyph "A"))
      (decknix-agent-register-provider 'test-b
        `(:sessions-dir ,dir-b
          :session-file-extension ".json"
          :label "B" :glyph "B"))
      (decknix-agent-session-cache-test--touch
       (expand-file-name "x.json" dir-a) 1000.0)
      (decknix-agent-session-cache-test--touch
       (expand-file-name "y.json" dir-b) 2000.0)
      (let ((a1 (decknix--session-list-files 'test-a))
            (_b1 (decknix--session-list-files 'test-b)))
        ;; Mutate provider B; provider A's cached list must still be `eq'.
        (decknix-agent-session-cache-test--touch
         (expand-file-name "z.json" dir-b) 3000.0)
        (let ((a2 (decknix--session-list-files 'test-a)))
          (should (eq a1 a2)))))))

;; ---------------------------------------------------------------------------
;; decknix--session-list-files-with-mtimes — pair-returning API (D re-eval Part B)
;;
;; Same fingerprint cache as `-list-files' but returns `((mtime . path) ...)'
;; pairs so callers (`decknix--agent-session-refresh-{sync,async}') can
;; consume mtime without a second per-file stat during the partition loop.
;; The pair list and the path list are `eq'-stable across calls with no fs
;; change; both are backed by the same `:key' fingerprint.
;; ---------------------------------------------------------------------------

(ert-deftest decknix-session-list-files-with-mtimes--sorted-newest-first ()
  "Returns pairs sorted newest-first with matching mtime."
  (decknix-agent-session-cache-test--with-tmp-dir tmp
    (let ((decknix-agent-provider-registry nil))
      (decknix-agent-register-provider 'test-auggie
        `(:sessions-dir ,tmp
          :session-file-extension ".json"
          :label "T" :glyph "A"))
      (decknix-agent-session-cache-test--touch
       (expand-file-name "old.json" tmp) 1000.0)
      (decknix-agent-session-cache-test--touch
       (expand-file-name "mid.json" tmp) 2000.0)
      (decknix-agent-session-cache-test--touch
       (expand-file-name "new.json" tmp) 3000.0)
      (let ((pairs (decknix--session-list-files-with-mtimes 'test-auggie)))
        (should (equal (mapcar (lambda (p) (file-name-nondirectory (cdr p)))
                               pairs)
                       '("new.json" "mid.json" "old.json")))
        (should (equal (mapcar #'car pairs) '(3000.0 2000.0 1000.0)))))))

(ert-deftest decknix-session-list-files-with-mtimes--honours-max ()
  "MAX truncates the returned pair list."
  (decknix-agent-session-cache-test--with-tmp-dir tmp
    (let ((decknix-agent-provider-registry nil))
      (decknix-agent-register-provider 'test-auggie
        `(:sessions-dir ,tmp
          :session-file-extension ".json"
          :label "T" :glyph "A"))
      (decknix-agent-session-cache-test--touch
       (expand-file-name "a.json" tmp) 1000.0)
      (decknix-agent-session-cache-test--touch
       (expand-file-name "b.json" tmp) 2000.0)
      (decknix-agent-session-cache-test--touch
       (expand-file-name "c.json" tmp) 3000.0)
      (let ((pairs (decknix--session-list-files-with-mtimes 'test-auggie 2)))
        (should (= (length pairs) 2))
        (should (equal (mapcar (lambda (p) (file-name-nondirectory (cdr p)))
                               pairs)
                       '("c.json" "b.json")))))))

(ert-deftest decknix-session-list-files-with-mtimes--cache-eq-when-unchanged ()
  "Two back-to-back calls return the same cons cell (skip-sort proof)."
  (decknix-agent-session-cache-test--with-tmp-dir tmp
    (let ((decknix-agent-provider-registry nil))
      (decknix-agent-register-provider 'test-auggie
        `(:sessions-dir ,tmp
          :session-file-extension ".json"
          :label "T" :glyph "A"))
      (decknix-agent-session-cache-test--touch
       (expand-file-name "a.json" tmp) 1000.0)
      (decknix-agent-session-cache-test--touch
       (expand-file-name "b.json" tmp) 2000.0)
      (let ((r1 (decknix--session-list-files-with-mtimes 'test-auggie))
            (r2 (decknix--session-list-files-with-mtimes 'test-auggie)))
        (should (eq r1 r2))))))

(ert-deftest decknix-session-list-files-with-mtimes--shares-cache-with-paths ()
  "Both APIs are backed by the same fingerprint cache: neither call
invalidates the other, and the same underlying scan powers both."
  (decknix-agent-session-cache-test--with-tmp-dir tmp
    (let ((decknix-agent-provider-registry nil))
      (decknix-agent-register-provider 'test-auggie
        `(:sessions-dir ,tmp
          :session-file-extension ".json"
          :label "T" :glyph "A"))
      (decknix-agent-session-cache-test--touch
       (expand-file-name "a.json" tmp) 1000.0)
      (decknix-agent-session-cache-test--touch
       (expand-file-name "b.json" tmp) 2000.0)
      ;; Prime with pairs API, then verify paths API returns the same
      ;; cons cell across repeated calls (i.e. shared cache).
      (decknix--session-list-files-with-mtimes 'test-auggie)
      (let ((paths1 (decknix--session-list-files 'test-auggie))
            (paths2 (decknix--session-list-files 'test-auggie)))
        (should (eq paths1 paths2))
        (should (equal (mapcar #'file-name-nondirectory paths1)
                       '("b.json" "a.json"))))
      ;; And vice versa.
      (let ((pairs1 (decknix--session-list-files-with-mtimes 'test-auggie))
            (pairs2 (decknix--session-list-files-with-mtimes 'test-auggie)))
        (should (eq pairs1 pairs2))))))

;; ---------------------------------------------------------------------------
;; refresh-{sync,async} — mtime plumbed from list-files (D re-eval Part B)
;;
;; The refresh functions previously called `-file-mtime' once per path
;; during partitioning (N extra stats per warm sidebar tick).  Now they
;; consume the `((mtime . path) ...)' pairs directly from
;; `-list-files-with-mtimes' so the partition loop is stat-free on the
;; hot warm path.
;;
;; Characterisation: refresh a fully-warm cache and count how many times
;; the partition loop invokes `-file-mtime'.  Must be 0.
;; ---------------------------------------------------------------------------

(ert-deftest decknix-refresh-sync--warm-path-does-not-restat ()
  "On a fully-warm cache, refresh-sync must not call `-file-mtime' per file."
  (decknix-agent-session-cache-test--with-tmp-dir tmp
    (let* ((decknix-agent-provider-registry nil)
           (decknix--session-meta-cache (make-hash-table :test 'equal))
           (decknix--agent-session-cache-map (make-hash-table :test 'eq))
           (decknix--agent-session-cache-time-map (make-hash-table :test 'eq))
           (path-a (expand-file-name "a.json" tmp))
           (path-b (expand-file-name "b.json" tmp))
           (stat-count 0))
      (decknix-agent-register-provider 'test-auggie
        `(:sessions-dir ,tmp
          :session-file-extension ".json"
          :label "T" :glyph "A"))
      (decknix-agent-session-cache-test--touch path-a 1000.0)
      (decknix-agent-session-cache-test--touch path-b 2000.0)
      ;; Seed meta cache with matching mtimes so both paths are warm hits.
      (puthash path-a
               (list :mtime 1000.0
                     :data '((sessionId . "a") (providerId . test-auggie))
                     :parsed-at (float-time))
               decknix--session-meta-cache)
      (puthash path-b
               (list :mtime 2000.0
                     :data '((sessionId . "b") (providerId . test-auggie))
                     :parsed-at (float-time))
               decknix--session-meta-cache)
      ;; Count `-file-mtime' calls across the entire refresh.
      (cl-letf* ((orig (symbol-function 'decknix--session-file-mtime))
                 ((symbol-function 'decknix--session-file-mtime)
                  (lambda (p) (cl-incf stat-count) (funcall orig p))))
        (let ((result (decknix--agent-session-refresh-sync 'test-auggie)))
          (should (= (length result) 2))))
      (should (= stat-count 0)))))

(ert-deftest decknix-refresh-async--warm-path-does-not-restat ()
  "On a fully-warm cache, refresh-async must not call `-file-mtime' per file."
  (decknix-agent-session-cache-test--with-tmp-dir tmp
    (let* ((decknix-agent-provider-registry nil)
           (decknix--session-meta-cache (make-hash-table :test 'equal))
           (decknix--agent-session-cache-map (make-hash-table :test 'eq))
           (decknix--agent-session-cache-time-map (make-hash-table :test 'eq))
           (decknix--agent-session-refresh-proc-map
            (make-hash-table :test 'eq))
           (path-a (expand-file-name "a.json" tmp))
           (path-b (expand-file-name "b.json" tmp))
           (stat-count 0))
      (decknix-agent-register-provider 'test-auggie
        `(:sessions-dir ,tmp
          :session-file-extension ".json"
          :label "T" :glyph "A"))
      (decknix-agent-session-cache-test--touch path-a 1000.0)
      (decknix-agent-session-cache-test--touch path-b 2000.0)
      (puthash path-a
               (list :mtime 1000.0
                     :data '((sessionId . "a") (providerId . test-auggie))
                     :parsed-at (float-time))
               decknix--session-meta-cache)
      (puthash path-b
               (list :mtime 2000.0
                     :data '((sessionId . "b") (providerId . test-auggie))
                     :parsed-at (float-time))
               decknix--session-meta-cache)
      (cl-letf* ((orig (symbol-function 'decknix--session-file-mtime))
                 ((symbol-function 'decknix--session-file-mtime)
                  (lambda (p) (cl-incf stat-count) (funcall orig p))))
        (decknix--agent-session-refresh-async 'test-auggie))
      (should (= stat-count 0)))))

;; -- sub-agent metadata fast path (#146) -----------------------------

(ert-deftest decknix-subagent-meta-with-mtime--sets-modified-from-stat ()
  "`modified' is derived from the float MTIME and round-trips; nil is a no-op."
  (let* ((base '((sessionId . "s1") (created . "C") (modified . "OLD")))
         (out (decknix--agent-subagent-meta-with-mtime base 1000000.0)))
    ;; other fields preserved
    (should (equal "s1" (alist-get 'sessionId out)))
    (should (equal "C" (alist-get 'created out)))
    ;; modified replaced, and parses back to the same instant (sub-second dropped)
    (should-not (equal "OLD" (alist-get 'modified out)))
    (should (= (floor 1000000.0)
               (floor (float-time (date-to-time (alist-get 'modified out))))))
    ;; input not mutated
    (should (equal "OLD" (alist-get 'modified base)))
    ;; nil mtime -> unchanged
    (should (eq base (decknix--agent-subagent-meta-with-mtime base nil)))))

(ert-deftest decknix-subagent-meta--parses-once-then-only-stats ()
  "A streaming sub-agent parses once (permanent cache) and refreshes
`modified' from the mtime on every call -- no repeated transcript parse."
  (let ((decknix--agent-subagent-meta-cache (make-hash-table :test 'equal))
        (meta-calls 0)
        (stat-n 0))
    (cl-letf (((symbol-function 'decknix--session-meta)
               (lambda (_p _path)
                 (cl-incf meta-calls)
                 '((sessionId . "s1") (firstUserMessage . "hi") (modified . "OLD"))))
              ((symbol-function 'decknix--session-file-mtime)
               (lambda (_p) (cl-incf stat-n) (if (= stat-n 1) 1000.0 2000.0))))
      (let ((r1 (decknix--agent-subagent-meta 'claude-code "/p/agent-1.jsonl"))
            (r2 (decknix--agent-subagent-meta 'claude-code "/p/agent-1.jsonl")))
        ;; transcript parsed exactly once despite two reads
        (should (= meta-calls 1))
        (should (equal "s1" (alist-get 'sessionId r1)))
        ;; modified comes from the stat, and refreshes between calls
        (should-not (equal "OLD" (alist-get 'modified r1)))
        (should-not (equal (alist-get 'modified r1) (alist-get 'modified r2)))))))

(ert-deftest decknix-subagent-meta--nil-when-unparseable ()
  "When the underlying parse yields nil, so does the fast path (uncached)."
  (let ((decknix--agent-subagent-meta-cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'decknix--session-meta) (lambda (_p _path) nil))
              ((symbol-function 'decknix--session-file-mtime) (lambda (_p) 1000.0)))
      (should-not (decknix--agent-subagent-meta 'claude-code "/p/x.jsonl")))))

(provide 'decknix-agent-session-cache-test)
