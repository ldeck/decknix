;;; decknix-agent-session-cache-test.el --- Tests for session cache -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-session-cache "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the session list cache extracted
;; from the agent-shell heredoc.  Covers the pure pieces (jq filter
;; contents, jq command shape) and the cache-state lifecycle (TTL
;; staleness, sync fetch wiring) without touching real auggie data.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Stub the parser before the cache module loads so `declare-function'
;; resolution at byte-compile time finds a real definition.  Tests
;; rebind it where they need a specific return value.
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
            ;; Tolerant `try//' fallback so mid-write parses still emit.
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

;; -- jq command shape ---------------------------------------------

(ert-deftest decknix-agent-session-cache--jq-cmd-shape ()
  "The shell command lists JSON files newest-first, fans out to jq, then sorts.
Default path uses `ls -t' + `head' to limit to max-files newest files."
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
  "When `decknix--agent-session-cache-max-files' is nil, fall back to find."
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
            ;; The naked unquoted path with a real space must not appear.
            (should-not (string-match-p
                         "ls -t1 /tmp/has space/sessions" cmd)))
        (when (and decknix--agent-session-jq-filter-file
                   (file-exists-p decknix--agent-session-jq-filter-file))
          (delete-file decknix--agent-session-jq-filter-file))))))

;; -- cache lifecycle ----------------------------------------------

(ert-deftest decknix-agent-session-cache--list-syncs-on-first-call ()
  "Cache is empty + time=0 => `session-list' triggers sync refresh."
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
  "Cache present but older than TTL => async refresh, list still served."
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
        ;; Returns the still-cached value while async refresh runs.
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
