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

;; -- render-section-header -----------------------------------------
;;
;; These tests render into a `with-temp-buffer' and check both the
;; raw text (no properties) and a representative face span.

(ert-deftest decknix-sidebar-render-section-header--basic-text ()
  "Header inserts ` TITLE\\n' verbatim."
  (with-temp-buffer
    (decknix--sidebar-render-section-header "Live")
    (should (equal (buffer-substring-no-properties (point-min)
                                                   (point-max))
                   " Live\n"))))

(ert-deftest decknix-sidebar-render-section-header--bold-applied ()
  "The visible header span (excluding trailing newline) carries
the `bold' face via `add-face-text-property'."
  (with-temp-buffer
    (decknix--sidebar-render-section-header "Live")
    ;; Position 1 is the leading space; position 4 is the `e' of Live.
    (let ((face (get-text-property 1 'face)))
      ;; `add-face-text-property' may layer faces; check membership
      ;; rather than equality so future composition stays compatible.
      (should (or (eq face 'bold)
                  (and (listp face) (memq 'bold face)))))))

(ert-deftest decknix-sidebar-render-section-header--section-id-property ()
  "SECTION-ID, when supplied, is set as `decknix-sidebar-section'
text property over the visible span (not the trailing newline)."
  (with-temp-buffer
    (decknix--sidebar-render-section-header "Sessions" 'sessions)
    (should (eq (get-text-property 2 'decknix-sidebar-section)
                'sessions))
    ;; Trailing newline must not carry the property
    (should (null (get-text-property (1- (point-max))
                                     'decknix-sidebar-section)))))

(ert-deftest decknix-sidebar-render-section-header--section-id-omitted ()
  "Omitting SECTION-ID leaves the property unset (nil everywhere)."
  (with-temp-buffer
    (decknix--sidebar-render-section-header "Live")
    (should (null (get-text-property 2 'decknix-sidebar-section)))))

;; -- render-key-group ----------------------------------------------

(ert-deftest decknix-sidebar-render-key-group--vertical-format ()
  "Vertical group: header line then one ` KEY DESC\\n' per pair."
  (with-temp-buffer
    (decknix--sidebar-render-key-group
     "Navigate" '(("r" . "request") ("w" . "wip")))
    (should (equal (buffer-substring-no-properties (point-min)
                                                   (point-max))
                   " Navigate\n   r request\n   w wip\n"))))

(ert-deftest decknix-sidebar-render-key-group--empty-keys ()
  "Empty KEYS still inserts the header line and nothing else."
  (with-temp-buffer
    (decknix--sidebar-render-key-group "Empty" '())
    (should (equal (buffer-substring-no-properties (point-min)
                                                   (point-max))
                   " Empty\n"))))

;; -- render-key-group-inline ---------------------------------------

(ert-deftest decknix-sidebar-render-key-group-inline--single-line ()
  "Inline group: ` LABEL  k·desc k·desc\\n' on one line."
  (with-temp-buffer
    (decknix--sidebar-render-key-group-inline
     "Quick" '(("c" . "new") ("k" . "kill")))
    (should (equal (buffer-substring-no-properties (point-min)
                                                   (point-max))
                   " Quick c·new k·kill\n"))))

;; -- render-key-groups-side-by-side --------------------------------

(ert-deftest decknix-sidebar-render-key-groups-side-by-side--padding ()
  "Side-by-side: header row + per-pair row, right column padded
to start at COL-WIDTH so headers line up."
  (with-temp-buffer
    (decknix--sidebar-render-key-groups-side-by-side
     "L" '(("a" . "x"))
     "R" '(("b" . "y"))
     10)
    (let* ((raw (buffer-substring-no-properties (point-min)
                                                (point-max)))
           (lines (split-string raw "\n" t)))
      (should (= (length lines) 2))
      ;; Header row: " L" + 8 spaces + " R" => " L         R"
      (should (equal (nth 0 lines) " L         R"))
      ;; Body row: "   a x" (6 visible) + 4 spaces + "   b y"
      (should (equal (nth 1 lines) "   a x       b y")))))

(ert-deftest decknix-sidebar-render-key-groups-side-by-side--padding-uneven ()
  "Shorter group is padded with empty rows so both columns end at
the same height."
  (with-temp-buffer
    (decknix--sidebar-render-key-groups-side-by-side
     "L" '(("a" . "x") ("b" . "y") ("c" . "z"))
     "R" '(("p" . "1"))
     10)
    (let* ((raw (buffer-substring-no-properties (point-min)
                                                (point-max)))
           (lines (split-string raw "\n" t)))
      ;; 1 header row + 3 left-keys = 4 total rows
      (should (= (length lines) 4))
      ;; Last row: only the left col has content; right col is empty
      ;; so the right side after padding is the empty string.
      (should (string-prefix-p "   c z" (nth 3 lines))))))

(provide 'decknix-sidebar-format-test)
;;; decknix-sidebar-format-test.el ends here
