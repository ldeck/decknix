;;; decknix-agent-session-cache-test.el --- Tests for session cache -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-session-cache "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests for the mtime-keyed session metadata cache.  Covers:
;;
;; - jq filter contents and caching (still used for per-file parsing)
;; - Bulk jq command shape (kept for grep thorough path compatibility)
;; - Mtime-keyed metadata cache: hit, miss, missing file, round-trip
;; - Cache lifecycle: TTL-based sync/async refresh dispatch

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Stub the parser before loading so byte-compile resolves declare-function.
(unless (fboundp 'decknix--agent-session-parse)
  (defun decknix--agent-session-parse (_raw) nil))

(require 'decknix-agent-session-cache)

;; -- jq filter contents -------------------------------------------

(ert-deftest decknix-agent-session-cache--jq-filter-fields ()
  "The jq filter extracts the five fields the picker needs."
  (let ((decknix--agent-session-jq-filter-file nil))
    (let ((path (decknix--agent-session-ensure-jq-filter)))
      (unwind-protect
          (let ((body (with-temp-buffer
                        (insert-file-contents path)
                        (buffer-string))))
            (should (string-match-p "sessionId" body))
            (should (string-match-p "created" body))
            (should (string-match-p "modified" body))
            (should (string-match-p "exchangeCount" body))
            (should (string-match-p "firstUserMessage" body))
            ;; Tolerant try// fallback so mid-write parses still emit.
            (should (string-match-p "try" body))
            (should (string-match-p "// 0" body))
            ;; Trims firstUserMessage to 200 chars.
            (should (string-match-p "\\[:200\\]" body)))
        (when (file-exists-p path) (delete-file path))))))

(ert-deftest decknix-agent-session-cache--jq-filter-cached ()
  "Repeated calls return the same path while the file exists."
  (let ((decknix--agent-session-jq-filter-file nil))
    (let ((p1 (decknix--agent-session-ensure-jq-filter)))
      (unwind-protect
          (let ((p2 (decknix--agent-session-ensure-jq-filter)))
            (should (equal p1 p2)))
        (when (file-exists-p p1) (delete-file p1))))))

(ert-deftest decknix-agent-session-cache--jq-filter-recreated-if-deleted ()
  "If the cached jq file vanishes, the next call writes a fresh one."
  (let ((decknix--agent-session-jq-filter-file nil))
    (let ((p1 (decknix--agent-session-ensure-jq-filter)))
      (delete-file p1)
      (let ((p2 (decknix--agent-session-ensure-jq-filter)))
        (unwind-protect
            (progn
              (should (file-exists-p p2))
              (should-not (equal p1 p2)))
          (when (file-exists-p p2) (delete-file p2)))))))

;; -- bulk jq command shape (kept for grep thorough path) ----------

(ert-deftest decknix-agent-session-cache--jq-cmd-shape ()
  "Bulk jq command lists JSON files newest-first and fans out to jq.
Default path uses ls -t + head to limit to max-files newest files."
  (let ((decknix--agent-session-jq-filter-file nil)
        (decknix--agent-sessions-dir "/tmp/test-sessions-dir")
        (decknix--agent-session-cache-max-files 200))
    (let ((cmd (decknix--agent-session-jq-cmd)))
      (unwind-protect
          (progn
            (should (string-match-p "ls -t1" cmd))
            (should (string-match-p "test-sessions-dir" cmd))
            (should (string-match-p "\\.json" cmd))
            (should (string-match-p "head -200" cmd))
            (should (string-match-p "xargs -0 -P8" cmd))
            (should (string-match-p "jq -Mc -f " cmd))
            (should (string-match-p "sort_by(\\.modified) | reverse" cmd)))
        (when (and decknix--agent-session-jq-filter-file
                   (file-exists-p decknix--agent-session-jq-filter-file))
          (delete-file decknix--agent-session-jq-filter-file))))))

(ert-deftest decknix-agent-session-cache--jq-cmd-nil-max-uses-find ()
  "When cache-max-files is nil, the bulk command falls back to find."
  (let ((decknix--agent-session-jq-filter-file nil)
        (decknix--agent-sessions-dir "/tmp/test-sessions-dir")
        (decknix--agent-session-cache-max-files nil))
    (let ((cmd (decknix--agent-session-jq-cmd)))
      (unwind-protect
          (progn
            (should (string-match-p "find " cmd))
            (should (string-match-p "-name '\\*\\.json'" cmd))
            (should-not (string-match-p "ls -t" cmd))
            (should-not (string-match-p "head -" cmd)))
        (when (and decknix--agent-session-jq-filter-file
                   (file-exists-p decknix--agent-session-jq-filter-file))
          (delete-file decknix--agent-session-jq-filter-file))))))

(ert-deftest decknix-agent-session-cache--jq-cmd-quotes-sessions-dir ()
  "Sessions dir is shell-quoted so a space in the path is safe."
  (let ((decknix--agent-session-jq-filter-file nil)
        (decknix--agent-sessions-dir "/tmp/has space/sessions")
        (decknix--agent-session-cache-max-files 200))
    (let ((cmd (decknix--agent-session-jq-cmd))
          (quoted (shell-quote-argument "/tmp/has space/sessions")))
      (unwind-protect
          (progn
            (should (string-match-p (regexp-quote quoted) cmd))
            (should-not (string-match-p "ls -t1 /tmp/has space/sessions" cmd)))
        (when (and decknix--agent-session-jq-filter-file
                   (file-exists-p decknix--agent-session-jq-filter-file))
          (delete-file decknix--agent-session-jq-filter-file))))))

;; -- mtime-keyed metadata cache -----------------------------------

(ert-deftest decknix-session-meta--cache-hit ()
  "When file mtime matches cached mtime, returns cached data without parsing."
  (let ((decknix--session-meta-cache (make-hash-table :test 'equal))
        (parse-called 0))
    (puthash "/tmp/test.json"
             (list :mtime 1000.0 :data '((sessionId . "abc")))
             decknix--session-meta-cache)
    (cl-letf (((symbol-function 'decknix--session-file-mtime)
               (lambda (_p) 1000.0))
              ((symbol-function 'decknix--session-parse-file)
               (lambda (_p) (cl-incf parse-called) nil)))
      (let ((result (decknix--session-meta "/tmp/test.json")))
        (should (equal result '((sessionId . "abc"))))
        (should (= parse-called 0))))))

(ert-deftest decknix-session-meta--cache-miss-reparses ()
  "When mtime differs from cached, re-parses and updates cache."
  (let ((decknix--session-meta-cache (make-hash-table :test 'equal))
        (parse-called 0))
    (puthash "/tmp/test.json"
             (list :mtime 999.0 :data '((sessionId . "old")))
             decknix--session-meta-cache)
    (cl-letf (((symbol-function 'decknix--session-file-mtime)
               (lambda (_p) 1001.0))
              ((symbol-function 'decknix--session-parse-file)
               (lambda (_p)
                 (cl-incf parse-called)
                 '((sessionId . "new")))))
      (let ((result (decknix--session-meta "/tmp/test.json")))
        (should (equal result '((sessionId . "new"))))
        (should (= parse-called 1))
        ;; Cache entry must be updated with new mtime.
        (let ((entry (gethash "/tmp/test.json" decknix--session-meta-cache)))
          (should (= (plist-get entry :mtime) 1001.0))
          (should (equal (plist-get entry :data) '((sessionId . "new")))))))))

(ert-deftest decknix-session-meta--new-file-cached-on-parse ()
  "File absent from cache is parsed and inserted."
  (let ((decknix--session-meta-cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'decknix--session-file-mtime)
               (lambda (_p) 2000.0))
              ((symbol-function 'decknix--session-parse-file)
               (lambda (_p) '((sessionId . "xyz")))))
      (let ((result (decknix--session-meta "/tmp/new.json")))
        (should (equal result '((sessionId . "xyz"))))
        (should (gethash "/tmp/new.json" decknix--session-meta-cache))))))

(ert-deftest decknix-session-meta--missing-file-returns-nil ()
  "When file does not exist (mtime returns nil), returns nil without parsing."
  (let ((decknix--session-meta-cache (make-hash-table :test 'equal))
        (parse-called 0))
    (cl-letf (((symbol-function 'decknix--session-file-mtime)
               (lambda (_p) nil))
              ((symbol-function 'decknix--session-parse-file)
               (lambda (_p) (cl-incf parse-called) nil)))
      (should (null (decknix--session-meta "/tmp/gone.json")))
      (should (= parse-called 0)))))

(ert-deftest decknix-session-meta-cache--round-trip ()
  "Save and load round-trips the mtime cache through disk."
  (let ((decknix--session-meta-cache (make-hash-table :test 'equal))
        (tmp (make-temp-file "session-meta-test-" nil ".eld")))
    (unwind-protect
        (progn
          (puthash "/tmp/a.json"
                   (list :mtime 1000.0 :data '((sessionId . "aaa")))
                   decknix--session-meta-cache)
          (puthash "/tmp/b.json"
                   (list :mtime 2000.0 :data '((sessionId . "bbb")))
                   decknix--session-meta-cache)
          ;; Save to temp file.
          (let ((decknix--session-meta-cache-file tmp))
            (decknix--session-meta-cache-save))
          ;; Clear in-memory cache and reload.
          (clrhash decknix--session-meta-cache)
          (let ((decknix--session-meta-cache-file tmp))
            (decknix--session-meta-cache-load))
          ;; Both entries must survive the round-trip.
          (let ((ea (gethash "/tmp/a.json" decknix--session-meta-cache))
                (eb (gethash "/tmp/b.json" decknix--session-meta-cache)))
            (should ea)
            (should (= (plist-get ea :mtime) 1000.0))
            (should (equal (plist-get ea :data) '((sessionId . "aaa"))))
            (should eb)
            (should (= (plist-get eb :mtime) 2000.0))
            (should (equal (plist-get eb :data) '((sessionId . "bbb"))))))
      (when (file-exists-p tmp) (delete-file tmp)))))

;; -- cache lifecycle (TTL-based dispatch) -------------------------

(ert-deftest decknix-agent-session-cache--list-syncs-on-first-call ()
  "Cache is empty + time=0 => session-list triggers sync refresh."
  (let ((decknix--agent-session-cache nil)
        (decknix--agent-session-cache-time 0)
        (decknix--agent-session-cache-ttl 120)
        (decknix--agent-session-refresh-proc nil)
        (sync-called 0)
        (async-called 0))
    (cl-letf (((symbol-function 'decknix--agent-session-refresh-sync)
               (lambda ()
                 (cl-incf sync-called)
                 (setq decknix--agent-session-cache '((stub))
                       decknix--agent-session-cache-time (float-time))))
              ((symbol-function 'decknix--agent-session-refresh-async)
               (lambda () (cl-incf async-called))))
      (let ((result (decknix--agent-session-list)))
        (should (= sync-called 1))
        (should (= async-called 0))
        (should (equal result '((stub))))))))

(ert-deftest decknix-agent-session-cache--list-async-when-stale ()
  "Cache present but older than TTL => async refresh, stale list still served."
  (let ((decknix--agent-session-cache '((cached)))
        (decknix--agent-session-cache-time 1.0)
        (decknix--agent-session-cache-ttl 60)
        (decknix--agent-session-refresh-proc nil)
        (sync-called 0)
        (async-called 0))
    (cl-letf (((symbol-function 'decknix--agent-session-refresh-sync)
               (lambda () (cl-incf sync-called)))
              ((symbol-function 'decknix--agent-session-refresh-async)
               (lambda () (cl-incf async-called))))
      (let ((result (decknix--agent-session-list)))
        (should (= sync-called 0))
        (should (= async-called 1))
        (should (equal result '((cached))))))))

(ert-deftest decknix-agent-session-cache--list-fresh-no-refresh ()
  "Cache present and within TTL => no refresh of either kind."
  (let ((decknix--agent-session-cache '((cached)))
        (decknix--agent-session-cache-time (float-time))
        (decknix--agent-session-cache-ttl 600)
        (decknix--agent-session-refresh-proc nil)
        (sync-called 0)
        (async-called 0))
    (cl-letf (((symbol-function 'decknix--agent-session-refresh-sync)
               (lambda () (cl-incf sync-called)))
              ((symbol-function 'decknix--agent-session-refresh-async)
               (lambda () (cl-incf async-called))))
      (decknix--agent-session-list)
      (should (= sync-called 0))
      (should (= async-called 0)))))

(provide 'decknix-agent-session-cache-test)
;;; decknix-agent-session-cache-test.el ends here
