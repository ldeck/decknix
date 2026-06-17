;;; decknix-agent-session-cache-test.el --- Tests for session cache -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)

(unless (fboundp 'decknix--agent-session-parse)
  (defun decknix--agent-session-parse (_raw) nil))

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
              ((symbol-function 'decknix--agent-session-parse)
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
          (should (equal result '((stub)))))))))

(provide 'decknix-agent-session-cache-test)
