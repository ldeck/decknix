;;; decknix-agent-grep-format-test.el --- Tests for grep-format -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-grep-format "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix--agent-session-grep-
;; candidate' and `decknix--agent-session-grep-build-entries' (carved
;; from `decknix-agent-shell-main' / main-bulk into
;; `decknix-agent-grep-format').
;;
;; Both functions depend on four sibling helpers (tags-for-session,
;; tags-for-conv-key, session-time-ago, group-by-conversation); tests
;; stub all four via `cl-letf' / `defun' so the suite never reaches
;; the real tag-store JSON or the wall clock.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'decknix-agent-grep-format)

;; Stubs for forward-declared helpers.
(unless (fboundp 'decknix--agent-tags-for-session)
  (defun decknix--agent-tags-for-session (_id) nil))
(unless (fboundp 'decknix--agent-tags-for-conv-key)
  (defun decknix--agent-tags-for-conv-key (_key) nil))
(unless (fboundp 'decknix--agent-session-time-ago)
  (defun decknix--agent-session-time-ago (_iso) "5m ago"))
(unless (fboundp 'decknix--agent-session-group-by-conversation)
  ;; Default: each session in its own one-element group, conv-key is
  ;; the first word of the firstUserMessage.
  (defun decknix--agent-session-group-by-conversation (sessions &optional _hidden)
    (mapcar (lambda (s)
              (let* ((msg (alist-get 'firstUserMessage s ""))
                     (key (car (split-string msg "[ \n]" t))))
                (list key s (list s))))
            sessions)))

(defun decknix-agent-grep-format-test--session
    (&optional sid first-msg exchanges modified)
  "Build a synthetic session alist."
  `((sessionId . ,(or sid "abcd1234-deadbeef"))
    (modified . ,(or modified "2026-05-08T00:00:00Z"))
    (exchangeCount . ,(or exchanges 7))
    (firstUserMessage . ,(or first-msg "Refactor the login flow"))))

;; -- grep-candidate -----------------------------------------------

(ert-deftest decknix-agent-grep-format/candidate-shape ()
  "Candidate is `<sid8>  <ago>  <Nx>  <msg>' with no tags."
  (let* ((s (decknix-agent-grep-format-test--session))
         (line (decknix--agent-session-grep-candidate s)))
    (should (string-prefix-p "abcd1234" line))
    (should (string-match-p "5m ago" line))
    (should (string-match-p "  7x" line))
    (should (string-match-p "Refactor the login flow" line))
    (should-not (string-match-p "\\[" line))))

(ert-deftest decknix-agent-grep-format/candidate-appends-tags ()
  "Tags render as ` [tag1, tag2]' before the message."
  (let* ((s (decknix-agent-grep-format-test--session)))
    (cl-letf (((symbol-function 'decknix--agent-tags-for-session)
               (lambda (_) '("review" "urgent"))))
      (let ((line (decknix--agent-session-grep-candidate s)))
        (should (string-match-p "\\[review, urgent\\]" line))))))

(ert-deftest decknix-agent-grep-format/candidate-truncates-at-80 ()
  "Long first messages are truncated to 80 chars with `...' tail."
  (let* ((long (make-string 200 ?x))
         (s (decknix-agent-grep-format-test--session nil long))
         (line (decknix--agent-session-grep-candidate s)))
    (should (string-match-p "\\.\\.\\." line))))

(ert-deftest decknix-agent-grep-format/candidate-handles-missing-modified ()
  "Absent `modified' renders as `?' in the time column."
  (let* ((s `((sessionId . "abcd1234-x")
              (exchangeCount . 1)
              (firstUserMessage . "x")))
         (line (decknix--agent-session-grep-candidate s)))
    (should (string-match-p " \\?  " line))))

(ert-deftest decknix-agent-grep-format/candidate-uses-first-line-only ()
  "Multi-line first message collapses to the first non-empty line."
  (let* ((s (decknix-agent-grep-format-test--session
             nil "first line\nsecond line"))
         (line (decknix--agent-session-grep-candidate s)))
    (should (string-match-p "first line" line))
    (should-not (string-match-p "second line" line))))

(ert-deftest decknix-agent-grep-format/candidate-short-sid ()
  "Session id shorter than 8 chars uses only the available chars."
  (let* ((s (decknix-agent-grep-format-test--session "abc"))
         (line (decknix--agent-session-grep-candidate s)))
    (should (string-prefix-p "abc " line))))

;; -- grep-build-entries -------------------------------------------

(ert-deftest decknix-agent-grep-format/entries-expanded-fans-out ()
  "EXPAND non-nil produces one entry per session via grep-candidate."
  (let* ((s1 (decknix-agent-grep-format-test--session "s1aaaaaa" "alpha hi"))
         (s2 (decknix-agent-grep-format-test--session "s2bbbbbb" "beta hi"))
         (entries (decknix--agent-session-grep-build-entries (list s1 s2) t)))
    (should (= 2 (length entries)))
    ;; Each entry is (CAND . (session . SESSION-ALIST)).
    (dolist (e entries)
      (should (stringp (car e)))
      (should (eq 'session (cadr e))))))

(ert-deftest decknix-agent-grep-format/entries-collapsed-uses-group ()
  "EXPAND nil routes through `group-by-conversation'."
  (let* ((s1 (decknix-agent-grep-format-test--session "aaaaaaaa" "alpha hi"))
         (s2 (decknix-agent-grep-format-test--session "bbbbbbbb" "beta hi"))
         (entries (decknix--agent-session-grep-build-entries (list s1 s2) nil)))
    (should (= 2 (length entries)))
    (dolist (e entries)
      (should (eq 'session (cadr e))))))

(ert-deftest decknix-agent-grep-format/entries-collapsed-shows-session-count ()
  "Collapsed entries with N>1 sessions render `(N sessions)' suffix."
  (let* ((latest (decknix-agent-grep-format-test--session "newer" "alpha hi" 3 "2026-05-08T05:00:00Z"))
         (older (decknix-agent-grep-format-test--session "older" "alpha hi" 1 "2026-05-08T01:00:00Z")))
    (cl-letf (((symbol-function 'decknix--agent-session-group-by-conversation)
               (lambda (_sessions &optional _h)
                 (list (list "alpha" latest (list latest older))))))
      (let* ((entries (decknix--agent-session-grep-build-entries
                       (list latest older) nil))
             (cand (caar entries)))
        (should (string-match-p "(2 sessions)" cand))
        (should (string-prefix-p "newer" cand))))))

(ert-deftest decknix-agent-grep-format/entries-collapsed-uses-conv-tags ()
  "Collapsed entries use `tags-for-conv-key', not `tags-for-session'."
  (let* ((s (decknix-agent-grep-format-test--session "ssssssss" "alpha hi"))
         (called nil))
    (cl-letf (((symbol-function 'decknix--agent-tags-for-conv-key)
               (lambda (_key) (setq called t) '("conv-tag")))
              ((symbol-function 'decknix--agent-tags-for-session)
               (lambda (_id) '("session-tag"))))
      (let* ((entries (decknix--agent-session-grep-build-entries (list s) nil))
             (cand (caar entries)))
        (should called)
        (should (string-match-p "conv-tag" cand))
        (should-not (string-match-p "session-tag" cand))))))

(provide 'decknix-agent-grep-format-test)
;;; decknix-agent-grep-format-test.el ends here
