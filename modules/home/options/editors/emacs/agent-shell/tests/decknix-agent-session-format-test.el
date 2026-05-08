;;; decknix-agent-session-format-test.el --- Tests for session formatters -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-session-format "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix--agent-session-preview' and
;; `decknix--agent-session-display-name' (carved from
;; `decknix-agent-shell-main' / main-bulk into
;; `decknix-agent-session-format').
;;
;; Both formatters depend on three sibling agent/ helpers
;; (tags-for-session, tags-for-conv-key, conversation-key) plus the
;; time-ago formatter.  Tests stub all four via `cl-letf' so the suite
;; never reaches the real tag-store JSON file or the wall clock.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'decknix-agent-session-format)

;; Stubs for forward-declared helpers.  The real implementations live
;; in sibling agent/ packages; tests `cl-letf' over these defaults to
;; pin per-case behaviour.
(unless (fboundp 'decknix--agent-tags-for-session)
  (defun decknix--agent-tags-for-session (_id) nil))
(unless (fboundp 'decknix--agent-tags-for-conv-key)
  (defun decknix--agent-tags-for-conv-key (_key) nil))
(unless (fboundp 'decknix--agent-conversation-key)
  (defun decknix--agent-conversation-key (_first-message) "ck-fixture"))
(unless (fboundp 'decknix--agent-session-time-ago)
  (defun decknix--agent-session-time-ago (_iso) "5m ago"))

(defun decknix-agent-session-format-test--session
    (&optional sid first-msg exchanges modified)
  "Build a synthetic session alist for the formatters."
  `((sessionId . ,(or sid "abcd1234-deadbeef"))
    (modified . ,(or modified "2026-05-08T00:00:00Z"))
    (exchangeCount . ,(or exchanges 7))
    (firstUserMessage . ,(or first-msg "Refactor the login flow"))))

;; -- preview ------------------------------------------------------

(ert-deftest decknix-agent-session-format/preview-shape ()
  "Preview line is `<sid8>  <ago>  <Nx>  <msg>' with no tags."
  (let ((s (decknix-agent-session-format-test--session)))
    (cl-letf (((symbol-function 'decknix--agent-tags-for-session)
               (lambda (_) nil)))
      (let ((line (decknix--agent-session-preview s)))
        (should (string-prefix-p "abcd1234" line))
        (should (string-match-p "5m ago" line))
        (should (string-match-p "  7x  " line))
        (should (string-match-p "Refactor the login flow" line))
        (should-not (string-match-p "\\[" line))))))

(ert-deftest decknix-agent-session-format/preview-appends-tags ()
  "Tags surface as `[tag1, tag2]' suffix when present."
  (let ((s (decknix-agent-session-format-test--session)))
    (cl-letf (((symbol-function 'decknix--agent-tags-for-session)
               (lambda (_) '("review" "decknix"))))
      (let ((line (decknix--agent-session-preview s)))
        (should (string-suffix-p " [review, decknix]" line))))))

(ert-deftest decknix-agent-session-format/preview-truncates-long-msg ()
  "Messages longer than 50 chars get the `...' tail."
  (let* ((long (make-string 80 ?x))
         (s (decknix-agent-session-format-test--session nil long)))
    (let ((line (decknix--agent-session-preview s)))
      (should (string-match-p "\\.\\.\\." line))
      (should-not (string-match-p (make-string 51 ?x) line)))))

(ert-deftest decknix-agent-session-format/preview-uses-first-line-only ()
  "Multi-line first messages collapse to the first non-empty line."
  (let ((s (decknix-agent-session-format-test--session
            nil "first line\nsecond line\nthird line")))
    (let ((line (decknix--agent-session-preview s)))
      (should (string-match-p "first line" line))
      (should-not (string-match-p "second line" line)))))

(ert-deftest decknix-agent-session-format/preview-handles-missing-modified ()
  "Missing modified timestamp renders as `?'."
  (let ((s `((sessionId . "abcd1234-x")
             (exchangeCount . 0)
             (firstUserMessage . "hi"))))
    (let ((line (decknix--agent-session-preview s)))
      (should (string-match-p "  \\?  " line)))))

(ert-deftest decknix-agent-session-format/preview-short-sid ()
  "Short session IDs use only the available chars (no out-of-range)."
  (let ((s (decknix-agent-session-format-test--session "abc")))
    (let ((line (decknix--agent-session-preview s)))
      (should (string-prefix-p "abc " line)))))

;; -- display-name -------------------------------------------------

(ert-deftest decknix-agent-session-format/display-name-prefers-tags ()
  "Tags win over message preview, joined with `/'."
  (let ((s (decknix-agent-session-format-test--session)))
    (cl-letf (((symbol-function 'decknix--agent-tags-for-conv-key)
               (lambda (_) '("review" "ldeck"))))
      (should (equal (decknix--agent-session-display-name s)
                     "review/ldeck")))))

(ert-deftest decknix-agent-session-format/display-name-falls-back-to-message ()
  "No tags: truncated first-message preview, capped at 40 chars."
  (let* ((long (concat "Refactor the login flow "
                       (make-string 60 ?x)))
         (s (decknix-agent-session-format-test--session nil long)))
    (cl-letf (((symbol-function 'decknix--agent-tags-for-conv-key)
               (lambda (_) nil)))
      (let ((name (decknix--agent-session-display-name s)))
        (should (string-match-p "\\.\\.\\." name))
        (should (<= (length name) 40))))))

(ert-deftest decknix-agent-session-format/display-name-falls-back-to-sid ()
  "Empty first-message + no tags drops to 8-char session id prefix."
  (let ((s `((sessionId . "deadbeef-1234")
             (firstUserMessage . ""))))
    (cl-letf (((symbol-function 'decknix--agent-tags-for-conv-key)
               (lambda (_) nil)))
      (should (equal (decknix--agent-session-display-name s)
                     "deadbeef")))))

(ert-deftest decknix-agent-session-format/display-name-uses-first-line ()
  "Multi-line first message: only the first non-empty line counts."
  (let ((s (decknix-agent-session-format-test--session
            nil "headline\nbody body body")))
    (cl-letf (((symbol-function 'decknix--agent-tags-for-conv-key)
               (lambda (_) nil)))
      (should (equal (decknix--agent-session-display-name s)
                     "headline")))))

(provide 'decknix-agent-session-format-test)
;;; decknix-agent-session-format-test.el ends here
