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
  "Bind VAR to a fresh temp dir, run BODY, then remove it recursively."
  (declare (indent 1))
  `(let ((,var (make-temp-file "decknix-list-files-" t)))
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

(provide 'decknix-agent-session-cache-test)
