;;; decknix-agent-rg-search-command-test.el --- Tests for rg search command builders -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-rg-search-command' (PR B.84).
;; Pin the exact shell-command shape (quoting, pipeline structure,
;; stderr redirection) so future refactors can't silently change the
;; rg/jq invocation.

;;; Code:

(require 'ert)
(require 'decknix-agent-rg-search-command)

;; --- fast-command ---

(ert-deftest decknix-rg-search--fast-command-shape ()
  "Fast pipeline is single-stage rg with stderr suppressed."
  (let ((cmd (decknix--rg-fast-command "rg" "needle" "/tmp/sessions")))
    (should (string-prefix-p "rg -l0 " cmd))
    (should (string-suffix-p " 2>/dev/null" cmd))
    ;; No pipe -- fast variant intentionally avoids jq.
    (should-not (string-match-p " | " cmd))))

(ert-deftest decknix-rg-search--fast-command-quotes-term ()
  "TERM is shell-quoted so spaces survive (backslash-escaped on POSIX)."
  (let ((cmd (decknix--rg-fast-command "rg" "foo bar" "/tmp/s")))
    ;; `shell-quote-argument' uses backslash-escaping on POSIX
    ;; rather than wrapping in single quotes.  Asserting via a
    ;; round-trip through the function keeps the test portable
    ;; across platforms whose escaping conventions differ.
    (should (string-match-p
             (regexp-quote (shell-quote-argument "foo bar"))
             cmd))))

(ert-deftest decknix-rg-search--fast-command-quotes-rg-and-dir ()
  "RG path and SESSIONS-DIR are quoted (handles spaces in either)."
  (let ((cmd (decknix--rg-fast-command "/usr/local/bin/rg" "x"
                                       "/tmp/my sessions")))
    (should (string-match-p "/usr/local/bin/rg" cmd))
    (should (string-match-p
             (regexp-quote (shell-quote-argument "/tmp/my sessions"))
             cmd))))

(ert-deftest decknix-rg-search--fast-command-quotes-special-chars ()
  "Single-quotes / shell metachars inside TERM are escaped."
  (let ((cmd (decknix--rg-fast-command "rg" "it's" "/tmp/s")))
    (should (string-match-p
             (regexp-quote (shell-quote-argument "it's"))
             cmd))))

;; --- thorough-command ---

(ert-deftest decknix-rg-search--thorough-command-pipeline ()
  "Thorough pipeline is rg | xargs jq | jq sort."
  (let ((cmd (decknix--rg-thorough-command
              "rg" "needle" "'/tmp/sessions'" "/tmp/filter.jq")))
    (should (string-prefix-p "rg -l0 " cmd))
    (should (string-match-p " | xargs -0 -P8 -I{} jq -Mc -f " cmd))
    (should (string-match-p " | jq -Msc 'sort_by(.modified) | reverse'$"
                            cmd))))

(ert-deftest decknix-rg-search--thorough-command-suppresses-rg-stderr ()
  "rg's stderr is redirected to /dev/null before the first pipe."
  (let ((cmd (decknix--rg-thorough-command
              "rg" "needle" "'/tmp/s'" "/tmp/f.jq")))
    (should (string-match-p "/dev/null | xargs" cmd))))

(ert-deftest decknix-rg-search--thorough-command-suppresses-jq-stderr ()
  "Per-file jq's stderr is also suppressed (one bad file != fail)."
  (let ((cmd (decknix--rg-thorough-command
              "rg" "needle" "'/tmp/s'" "/tmp/f.jq")))
    (should (string-match-p "{} 2>/dev/null | jq -Msc" cmd))))

(ert-deftest decknix-rg-search--thorough-command-quotes-term-and-jq ()
  "TERM and JQ-FILTER are both shell-quoted (SESSIONS-DIR is caller-quoted)."
  (let ((cmd (decknix--rg-thorough-command
              "rg" "find me" "'/tmp/s'" "/tmp/my filter.jq")))
    (should (string-match-p
             (regexp-quote (shell-quote-argument "find me"))
             cmd))
    (should (string-match-p
             (regexp-quote (shell-quote-argument "/tmp/my filter.jq"))
             cmd))))

;; --- paths-to-id-set ---

(ert-deftest decknix-rg-search--paths-to-id-set-empty ()
  "Empty PATHS yields an empty hash-table."
  (let ((h (decknix--rg-paths-to-id-set '())))
    (should (hash-table-p h))
    (should (zerop (hash-table-count h)))))

(ert-deftest decknix-rg-search--paths-to-id-set-strips-extension ()
  "Each path's basename (without .json) becomes a key with value t."
  (let ((h (decknix--rg-paths-to-id-set
            '("/a/b/abc-123.json"
              "/a/b/xyz-456.json"))))
    (should (eq t (gethash "abc-123" h)))
    (should (eq t (gethash "xyz-456" h)))
    (should-not (gethash "abc-123.json" h))
    (should (= 2 (hash-table-count h)))))

(ert-deftest decknix-rg-search--paths-to-id-set-collapses-duplicates ()
  "Duplicate basenames collapse to a single entry."
  (let ((h (decknix--rg-paths-to-id-set
            '("/a/abc.json" "/b/abc.json"))))
    (should (= 1 (hash-table-count h)))
    (should (eq t (gethash "abc" h)))))

(provide 'decknix-agent-rg-search-command-test)
;;; decknix-agent-rg-search-command-test.el ends here
