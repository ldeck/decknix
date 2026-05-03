;;; decknix-sidebar-format-test.el --- Tests for sidebar display helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-sidebar-format "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning current behaviour of the sidebar display
;; primitives extracted from the agent-shell heredoc.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-test-helpers)
(require 'decknix-sidebar-format)

;; -- abbreviate-workspace ------------------------------------------

(ert-deftest decknix-sidebar-abbreviate-workspace--nil ()
  "nil path renders as a literal `?'."
  (should (equal (decknix--sidebar-abbreviate-workspace nil) "?")))

(ert-deftest decknix-sidebar-abbreviate-workspace--basic ()
  "Plain path returns the last component."
  (should (equal (decknix--sidebar-abbreviate-workspace "/foo/bar/baz")
                 "baz")))

(ert-deftest decknix-sidebar-abbreviate-workspace--trailing-slash ()
  "Trailing slash is tolerated by the regex (uses `/?$')."
  (should (equal (decknix--sidebar-abbreviate-workspace "/foo/bar/baz/")
                 "baz")))

(ert-deftest decknix-sidebar-abbreviate-workspace--single-segment ()
  "Single-segment paths still reduce to the segment after slash."
  (should (equal (decknix--sidebar-abbreviate-workspace "/foo")
                 "foo")))

(ert-deftest decknix-sidebar-abbreviate-workspace--no-slash-falls-back ()
  "Path without any `/' falls through to the abbreviated form
unchanged (regex doesn't match)."
  (should (equal (decknix--sidebar-abbreviate-workspace "scratch")
                 "scratch")))

;; -- session-age-visible-p -----------------------------------------

(ert-deftest decknix-sidebar-session-age-visible-p--filter-off ()
  "Filter nil → always visible regardless of MODIFIED."
  (let ((decknix--sidebar-sessions-age-filter nil))
    (should (decknix--sidebar-session-age-visible-p nil))
    (should (decknix--sidebar-session-age-visible-p
             "2025-01-01T00:00:00Z"))
    (should (decknix--sidebar-session-age-visible-p "garbage"))))

(ert-deftest decknix-sidebar-session-age-visible-p--filter-on-nil-modified ()
  "Filter set + MODIFIED nil → not visible (current behaviour)."
  (let ((decknix--sidebar-sessions-age-filter (* 24 60 60)))
    (should-not (decknix--sidebar-session-age-visible-p nil))))

(ert-deftest decknix-sidebar-session-age-visible-p--within-window ()
  "Recent timestamp passes when filter is set."
  (let* ((decknix--sidebar-sessions-age-filter (* 7 24 60 60))  ; 7d
         (recent (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                                     (time-subtract (current-time) 60))))
    (should (decknix--sidebar-session-age-visible-p recent))))

(ert-deftest decknix-sidebar-session-age-visible-p--outside-window ()
  "Timestamp older than the cutoff is hidden."
  (let* ((decknix--sidebar-sessions-age-filter (* 60))  ; 60s
         (old (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                                  (time-subtract (current-time)
                                                 (* 24 60 60)))))
    (should-not (decknix--sidebar-session-age-visible-p old))))

(ert-deftest decknix-sidebar-session-age-visible-p--malformed-defaults-visible ()
  "Garbage timestamps that fail iso8601-parse render visible (the
`condition-case' catches the parse error and falls back to t).
This is intentional leniency — a parsing glitch shouldn't hide
a session."
  (let ((decknix--sidebar-sessions-age-filter (* 60 60)))
    (should (decknix--sidebar-session-age-visible-p "not-an-iso-date"))))

(provide 'decknix-sidebar-format-test)
;;; decknix-sidebar-format-test.el ends here
