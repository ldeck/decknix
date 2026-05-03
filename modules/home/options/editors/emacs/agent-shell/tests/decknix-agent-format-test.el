;;; decknix-agent-format-test.el --- Tests for agent time formatters -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-format "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning current behaviour of the display formatters
;; extracted from the agent-shell heredoc:
;;
;; - Time formatters: each bucket boundary (1m / 1h / 1d / 30d) is
;;   exercised on both sides via `cl-letf' mocking of `current-time'
;;   so the suite is deterministic.
;; - String formatters: prompt-truncate exercises overflow,
;;   newline collapse, trim, and exact-boundary behaviour.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-format)

;; -- Fixtures ------------------------------------------------------

(defvar decknix-test--ref-time
  ;; Fixed reference: 2025-06-15T12:00:00Z
  (encode-time 0 0 12 15 6 2025 t))

(defun decknix-test--iso-offset (seconds-ago)
  "Return ISO-8601 string for SECONDS-AGO before the reference time."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                      (time-subtract decknix-test--ref-time
                                     (seconds-to-time seconds-ago))
                      t))

(defmacro decknix-test--with-fixed-time (&rest body)
  "Run BODY with `current-time' returning the reference time."
  `(cl-letf (((symbol-function 'current-time)
              (lambda () decknix-test--ref-time)))
     ,@body))

;; -- time-ago: bucket boundaries -----------------------------------

(ert-deftest decknix-agent-session-time-ago--just-now ()
  "Less than 60 seconds reads as \"just now\"."
  (decknix-test--with-fixed-time
   (should (equal (decknix--agent-session-time-ago
                   (decknix-test--iso-offset 0))
                  "just now"))
   (should (equal (decknix--agent-session-time-ago
                   (decknix-test--iso-offset 30))
                  "just now"))
   (should (equal (decknix--agent-session-time-ago
                   (decknix-test--iso-offset 59))
                  "just now"))))

(ert-deftest decknix-agent-session-time-ago--minutes ()
  "1 minute through 59 minutes reads as \"Nm ago\"."
  (decknix-test--with-fixed-time
   (should (equal (decknix--agent-session-time-ago
                   (decknix-test--iso-offset 60))
                  "1m ago"))
   (should (equal (decknix--agent-session-time-ago
                   (decknix-test--iso-offset (* 30 60)))
                  "30m ago"))
   (should (equal (decknix--agent-session-time-ago
                   (decknix-test--iso-offset (- (* 60 60) 1)))
                  "59m ago"))))

(ert-deftest decknix-agent-session-time-ago--hours ()
  "1 hour through 23 hours reads as \"Nh ago\"."
  (decknix-test--with-fixed-time
   (should (equal (decknix--agent-session-time-ago
                   (decknix-test--iso-offset (* 60 60)))
                  "1h ago"))
   (should (equal (decknix--agent-session-time-ago
                   (decknix-test--iso-offset (* 12 60 60)))
                  "12h ago"))))

(ert-deftest decknix-agent-session-time-ago--days ()
  "1 day through 29 days reads as \"Nd ago\"."
  (decknix-test--with-fixed-time
   (should (equal (decknix--agent-session-time-ago
                   (decknix-test--iso-offset (* 24 60 60)))
                  "1d ago"))
   (should (equal (decknix--agent-session-time-ago
                   (decknix-test--iso-offset (* 7 24 60 60)))
                  "7d ago"))
   (should (equal (decknix--agent-session-time-ago
                   (decknix-test--iso-offset (* 29 24 60 60)))
                  "29d ago"))))

(ert-deftest decknix-agent-session-time-ago--absolute ()
  "30+ days falls back to YYYY-MM-DD."
  (decknix-test--with-fixed-time
   (let ((result (decknix--agent-session-time-ago
                  (decknix-test--iso-offset (* 30 24 60 60)))))
     (should (string-match-p "^[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}$"
                             result)))))

;; -- time-compact: bucket boundaries -------------------------------

(ert-deftest decknix-agent-session-time-compact--now ()
  "Less than 60 seconds reads as \"now\"."
  (decknix-test--with-fixed-time
   (should (equal (decknix--agent-session-time-compact
                   (decknix-test--iso-offset 0))
                  "now"))
   (should (equal (decknix--agent-session-time-compact
                   (decknix-test--iso-offset 59))
                  "now"))))

(ert-deftest decknix-agent-session-time-compact--minutes ()
  "Minutes bucket: \"Nm\" without space or suffix."
  (decknix-test--with-fixed-time
   (should (equal (decknix--agent-session-time-compact
                   (decknix-test--iso-offset 60))
                  "1m"))
   (should (equal (decknix--agent-session-time-compact
                   (decknix-test--iso-offset (* 45 60)))
                  "45m"))))

(ert-deftest decknix-agent-session-time-compact--hours ()
  "Hours bucket: \"Nh\"."
  (decknix-test--with-fixed-time
   (should (equal (decknix--agent-session-time-compact
                   (decknix-test--iso-offset (* 60 60)))
                  "1h"))
   (should (equal (decknix--agent-session-time-compact
                   (decknix-test--iso-offset (* 23 60 60)))
                  "23h"))))

(ert-deftest decknix-agent-session-time-compact--days ()
  "Days bucket: \"Nd\"."
  (decknix-test--with-fixed-time
   (should (equal (decknix--agent-session-time-compact
                   (decknix-test--iso-offset (* 24 60 60)))
                  "1d"))
   (should (equal (decknix--agent-session-time-compact
                   (decknix-test--iso-offset (* 14 24 60 60)))
                  "14d"))))

(ert-deftest decknix-agent-session-time-compact--absolute ()
  "30+ days falls back to MM/DD."
  (decknix-test--with-fixed-time
   (let ((result (decknix--agent-session-time-compact
                  (decknix-test--iso-offset (* 60 24 60 60)))))
     (should (string-match-p "^[0-9]\\{2\\}/[0-9]\\{2\\}$" result)))))

;; -- prompt-truncate-for-display -----------------------------------

(ert-deftest decknix-prompt-truncate-for-display--short-passes-through ()
  "Strings shorter than MAX-LEN return as-is (after trim)."
  (should (equal (decknix--prompt-truncate-for-display "hello" 100)
                 "hello")))

(ert-deftest decknix-prompt-truncate-for-display--exact-length ()
  "String exactly at MAX-LEN returns verbatim (boundary is `<=' not `<')."
  (should (equal (decknix--prompt-truncate-for-display "abcde" 5)
                 "abcde")))

(ert-deftest decknix-prompt-truncate-for-display--overflow-truncates ()
  "Strings longer than MAX-LEN are truncated; ellipsis takes the
last char slot, so the visible content is MAX-LEN-1 characters."
  (let ((result (decknix--prompt-truncate-for-display
                 "abcdefghij" 5)))
    (should (equal result "abcd…"))
    (should (eq (length result) 5))))

(ert-deftest decknix-prompt-truncate-for-display--collapses-newlines ()
  "Newlines (LF and CR) collapse into the ↵ glyph with surrounding spaces."
  (should (equal (decknix--prompt-truncate-for-display
                  "line one\nline two" 100)
                 "line one ↵ line two")))

(ert-deftest decknix-prompt-truncate-for-display--multiple-newlines-collapse ()
  "Consecutive newlines collapse into a single ↵ (regexp uses [\\n\\r]+)."
  (should (equal (decknix--prompt-truncate-for-display
                  "a\n\n\n\nb" 100)
                 "a ↵ b")))

(ert-deftest decknix-prompt-truncate-for-display--trims-leading-trailing ()
  "Leading and trailing whitespace (after newline collapse) is trimmed."
  (should (equal (decknix--prompt-truncate-for-display
                  "  hello world  " 100)
                 "hello world")))

(provide 'decknix-agent-format-test)
;;; decknix-agent-format-test.el ends here
