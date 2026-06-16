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
