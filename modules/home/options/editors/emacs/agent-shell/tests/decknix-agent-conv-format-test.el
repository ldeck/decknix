;;; decknix-agent-conv-format-test.el --- Tests for conv-format -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-conv-format "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix--agent-conversation-preview'
;; (carved from `decknix-agent-shell-main' / main-bulk into
;; `decknix-agent-conv-format').
;;
;; Three sibling helpers are forward-declared (tags-for-conv-key,
;; workspace-for-conv-key, session-time-ago); tests stub all three via
;; `cl-letf' / `defun' so the suite never reaches the real tag-store
;; JSON, the workspace-cache file, or the wall clock.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'decknix-agent-conv-format)

;; Stubs for forward-declared helpers.
(unless (fboundp 'decknix--agent-tags-for-conv-key)
  (defun decknix--agent-tags-for-conv-key (_key) nil))
(unless (fboundp 'decknix--agent-workspace-for-conv-key)
  (defun decknix--agent-workspace-for-conv-key (_key) nil))
(unless (fboundp 'decknix--agent-session-time-ago)
  (defun decknix--agent-session-time-ago (_iso) "5m ago"))

(defun decknix-agent-conv-format-test--session
    (&optional sid first-msg exchanges modified)
  "Build a synthetic session alist."
  `((sessionId . ,(or sid "abcd1234-deadbeef"))
    (modified . ,(or modified "2026-05-08T00:00:00Z"))
    (exchangeCount . ,(or exchanges 7))
    (firstUserMessage . ,(or first-msg "Refactor the login flow"))))

(defun decknix-agent-conv-format-test--group (latest &optional all conv-key)
  "Build a synthetic conversation group triple."
  (list (or conv-key "abc123") latest (or all (list latest))))

;; -- conversation-preview -----------------------------------------

(ert-deftest decknix-agent-conv-format/preview-shape ()
  "Single-session group renders `<sid8>  <ago>  <Nx>  <msg>' with no
suffixes when tags / workspace are absent."
  (let* ((g (decknix-agent-conv-format-test--group
             (decknix-agent-conv-format-test--session)))
         (line (decknix--agent-conversation-preview g)))
    (should (string-prefix-p "abcd1234" line))
    (should (string-match-p "5m ago" line))
    (should (string-match-p "  7x" line))
    (should (string-match-p "Refactor the login flow" line))
    (should-not (string-match-p "\\[" line))
    (should-not (string-match-p "(.* sessions)" line))
    (should-not (string-match-p " @" line))))

(ert-deftest decknix-agent-conv-format/preview-appends-conv-tags ()
  "Tags surface as ` [t1, t2]' after the message; sourced via
`tags-for-conv-key' (NOT `tags-for-session') so renaming the
conversation re-tags every snapshot in the row."
  (let* ((g (decknix-agent-conv-format-test--group
             (decknix-agent-conv-format-test--session))))
    (cl-letf (((symbol-function 'decknix--agent-tags-for-conv-key)
               (lambda (_key) '("review" "urgent"))))
      (let ((line (decknix--agent-conversation-preview g)))
        (should (string-match-p "\\[review, urgent\\]" line))))))

(ert-deftest decknix-agent-conv-format/preview-truncates-at-50 ()
  "Long first messages truncate to 50 chars with `...' tail (matches
`session-preview' B.54, narrower than `grep-candidate' B.57's 80)."
  (let* ((long (make-string 200 ?x))
         (g (decknix-agent-conv-format-test--group
             (decknix-agent-conv-format-test--session nil long)))
         (line (decknix--agent-conversation-preview g)))
    (should (string-match-p "\\.\\.\\." line))))

(ert-deftest decknix-agent-conv-format/preview-handles-missing-modified ()
  "Absent `modified' renders as `?' in the time column."
  (let* ((s `((sessionId . "abcd1234-x")
              (exchangeCount . 1)
              (firstUserMessage . "x")))
         (g (decknix-agent-conv-format-test--group s))
         (line (decknix--agent-conversation-preview g)))
    (should (string-match-p " \\?  " line))))

(ert-deftest decknix-agent-conv-format/preview-uses-first-line-only ()
  "Multi-line first message collapses to the first non-empty line."
  (let* ((s (decknix-agent-conv-format-test--session
             nil "first line\nsecond line"))
         (g (decknix-agent-conv-format-test--group s))
         (line (decknix--agent-conversation-preview g)))
    (should (string-match-p "first line" line))
    (should-not (string-match-p "second line" line))))

(ert-deftest decknix-agent-conv-format/preview-short-sid ()
  "Session id shorter than 8 chars uses only the available chars."
  (let* ((g (decknix-agent-conv-format-test--group
             (decknix-agent-conv-format-test--session "abc")))
         (line (decknix--agent-conversation-preview g)))
    (should (string-prefix-p "abc " line))))

(ert-deftest decknix-agent-conv-format/preview-counts-multi-session ()
  "Group with N>1 sessions renders ` (N sessions)' suffix."
  (let* ((s1 (decknix-agent-conv-format-test--session "aaaaaaaa"))
         (s2 (decknix-agent-conv-format-test--session "bbbbbbbb"))
         (s3 (decknix-agent-conv-format-test--session "cccccccc"))
         (g (decknix-agent-conv-format-test--group s1 (list s1 s2 s3)))
         (line (decknix--agent-conversation-preview g)))
    (should (string-match-p "(3 sessions)" line))))

(ert-deftest decknix-agent-conv-format/preview-omits-singleton-count ()
  "Singleton conversation group omits the `(N sessions)' suffix."
  (let* ((g (decknix-agent-conv-format-test--group
             (decknix-agent-conv-format-test--session)))
         (line (decknix--agent-conversation-preview g)))
    (should-not (string-match-p "session" line))))

(ert-deftest decknix-agent-conv-format/preview-appends-workspace-shortname ()
  "Workspace renders as ` @<basename>' using the last path segment of
the abbreviated path (so `~/Code/decknix' becomes ` @decknix')."
  (let* ((g (decknix-agent-conv-format-test--group
             (decknix-agent-conv-format-test--session))))
    (cl-letf (((symbol-function 'decknix--agent-workspace-for-conv-key)
               (lambda (_key) "/Users/ldeck/Code/decknix")))
      (let ((line (decknix--agent-conversation-preview g)))
        (should (string-match-p " @decknix" line))
        (should-not (string-match-p " @/Users" line))))))

(ert-deftest decknix-agent-conv-format/preview-workspace-falls-back-to-abbrev ()
  "Workspace path that doesn't match the trailing-segment regex
(e.g. just `/') falls back to the abbreviated path itself."
  (let* ((g (decknix-agent-conv-format-test--group
             (decknix-agent-conv-format-test--session))))
    (cl-letf (((symbol-function 'decknix--agent-workspace-for-conv-key)
               (lambda (_key) "/")))
      (let ((line (decknix--agent-conversation-preview g)))
        (should (string-match-p " @/" line))))))

(provide 'decknix-agent-conv-format-test)
;;; decknix-agent-conv-format-test.el ends here
