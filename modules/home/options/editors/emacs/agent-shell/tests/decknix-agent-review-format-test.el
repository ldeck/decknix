;;; decknix-agent-review-format-test.el --- Tests for review formatters -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-review-format "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning current behaviour of the review-buffer pure
;; formatters extracted from the agent-shell heredoc.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-review-format)

;; -- review-quote --------------------------------------------------

(ert-deftest decknix-agent-review-quote--nil ()
  "nil input renders the empty placeholder."
  (should (equal (decknix--agent-review-quote nil) "> _(empty)_")))

(ert-deftest decknix-agent-review-quote--empty-string ()
  "Empty string renders the empty placeholder."
  (should (equal (decknix--agent-review-quote "") "> _(empty)_")))

(ert-deftest decknix-agent-review-quote--single-line ()
  "Single line gets one `> ' prefix."
  (should (equal (decknix--agent-review-quote "hello")
                 "> hello")))

(ert-deftest decknix-agent-review-quote--multi-line ()
  "Each line gets its own `> ' prefix; lines stay newline-separated."
  (should (equal (decknix--agent-review-quote "a\nb\nc")
                 "> a\n> b\n> c")))

(ert-deftest decknix-agent-review-quote--preserves-blank-lines ()
  "Blank lines between content render as bare `> ' (no trim)."
  (should (equal (decknix--agent-review-quote "x\n\ny")
                 "> x\n> \n> y")))

;; -- review-format-exchanges ---------------------------------------

(ert-deftest decknix-agent-review-format-exchanges--empty-list ()
  "An empty exchange list renders the empty string (mapconcat default)."
  (should (equal (decknix--agent-review-format-exchanges nil) "")))

(ert-deftest decknix-agent-review-format-exchanges--single-pair ()
  "A single exchange renders prompt + response sections with annotation
  placeholder; no separator on the trailing edge."
  (let ((result (decknix--agent-review-format-exchanges
                 '(("hello" . "world")))))
    (should (string-match-p "^## prompt\n\n> hello" result))
    (should (string-match-p "## agent response\n\n> world" result))
    (should (string-match-p "## annotations\n\n<!-- " result))
    ;; Single exchange has no `---' separator.
    (should-not (string-match-p "\n---\n" result))))

(ert-deftest decknix-agent-review-format-exchanges--nil-fields-ok ()
  "nil USER or RESP is coerced to empty via `or' so quote sees \"\"."
  (let ((result (decknix--agent-review-format-exchanges
                 '((nil . nil)))))
    ;; Both halves produce the empty placeholder.
    (should (string-match-p "## prompt\n\n> _(empty)_" result))
    (should (string-match-p "## agent response\n\n> _(empty)_" result))))

(ert-deftest decknix-agent-review-format-exchanges--separator-between ()
  "Two exchanges are joined by `\\n---\\n\\n' (mapconcat join arg)."
  (let ((result (decknix--agent-review-format-exchanges
                 '(("a" . "b") ("c" . "d")))))
    (should (string-match-p "\n---\n\n## prompt\n\n> c" result))))

;; -- review-strip-meta ---------------------------------------------

(ert-deftest decknix-agent-review-strip-meta--no-meta-block-untouched ()
  "Content without a meta block returns verbatim."
  (let ((input "## annotations\n\n<!-- empty -->\n"))
    (should (equal (decknix--agent-review-strip-meta input) input))))

(ert-deftest decknix-agent-review-strip-meta--strips-marker-line-only ()
  "Only the single `🧭 **review meta**' header line is deleted; the
function preserves subsequent meta lines and the instructions
block.  After re-search-forward point is at end-of-line (not at
column 0), so the `(while (looking-at \"^> \"))' inner loop does
not advance — `delete-region' covers exactly one line."
  (let* ((input (concat
                 "> 🧭 **review meta**\n"
                 "> session: foo\n"
                 "> ws: ~/work\n"
                 ">\n"
                 "> 📋 **instructions for the agent**\n"
                 "> reply with option 1\n\n"
                 "## prompt\n\n"
                 "> hello\n"))
         (result (decknix--agent-review-strip-meta input)))
    ;; Marker line gone.
    (should-not (string-match-p "🧭 \\*\\*review meta\\*\\*" result))
    ;; Subsequent meta lines preserved (current behaviour).
    (should (string-match-p "session: foo" result))
    (should (string-match-p "ws: ~/work" result))
    ;; Instructions preserved.
    (should (string-match-p "📋 \\*\\*instructions for the agent\\*\\*"
                            result))
    (should (string-match-p "reply with option 1" result))
    ;; Body untouched.
    (should (string-match-p "## prompt\n\n> hello" result))))

(ert-deftest decknix-agent-review-strip-meta--leaves-blank-line-where-marker-was ()
  "After deletion the line where the marker lived collapses to an
empty line (only the line content is deleted, the trailing newline
is kept by `delete-region' of the line-beginning..end-of-line range)."
  (let* ((input "> 🧭 **review meta**\nbody\n")
         (result (decknix--agent-review-strip-meta input)))
    ;; A leading newline indicates the marker line was emptied
    ;; rather than deleted whole.
    (should (string-prefix-p "\nbody" result))))

(provide 'decknix-agent-review-format-test)
;;; decknix-agent-review-format-test.el ends here
