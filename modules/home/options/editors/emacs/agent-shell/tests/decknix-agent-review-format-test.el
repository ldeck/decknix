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

;; -- review-render-preamble (PR B.59) ------------------------------

(ert-deftest decknix-agent-review-render-preamble--shape ()
  "Preamble carries `🧭 review meta' header, all four meta lines, the
`📋 instructions' block, and a trailing blank line."
  (let ((p (decknix--agent-review-render-preamble
            "*Auggie: foo*"
            "/Users/me/work/proj"
            '("alice" "bob"))))
    (should (string-match-p "^> 🧭 \\*\\*review meta\\*\\*\n" p))
    (should (string-match-p "^> session: \\*Auggie: foo\\*\n" p))
    (should (string-match-p "^> workspace: " p))
    (should (string-match-p "^> collaborators: alice, bob\n" p))
    (should (string-match-p "^> route: agent" p))
    (should (string-match-p "📋 \\*\\*instructions for the agent\\*\\*"
                            p))
    ;; Option-1 contract phrase appears verbatim.
    (should (string-match-p "Respond inline using" p))
    ;; Trailing blank line so the next markdown section starts cleanly.
    (should (string-suffix-p "\n\n" p))))

(ert-deftest decknix-agent-review-render-preamble--abbreviates-workspace ()
  "Workspace path is passed through `abbreviate-file-name'."
  (let* ((home (or (getenv "HOME") "/root"))
         (ws (concat home "/work/proj"))
         (p (decknix--agent-review-render-preamble "s" ws '("a"))))
    (should (string-match-p "^> workspace: ~/work/proj\n" p))))

(ert-deftest decknix-agent-review-render-preamble--nil-workspace ()
  "nil workspace renders the empty path (not `nil') after abbreviation."
  (let ((p (decknix--agent-review-render-preamble "s" nil '("a"))))
    (should (string-match-p "^> workspace: \n" p))
    (should-not (string-match-p "nil" p))))

(ert-deftest decknix-agent-review-render-preamble--empty-workspace ()
  "Empty-string workspace renders the empty path (no abbreviate crash)."
  (let ((p (decknix--agent-review-render-preamble "s" "" '("a"))))
    (should (string-match-p "^> workspace: \n" p))))

(ert-deftest decknix-agent-review-render-preamble--collaborators-comma-joined ()
  "Collaborator list renders comma-separated; caller is responsible
for placing the author first (the formatter does no reordering)."
  (let ((p (decknix--agent-review-render-preamble
            "s" "/x" '("zoe" "anna" "mike"))))
    (should (string-match-p "^> collaborators: zoe, anna, mike\n" p))))

(ert-deftest decknix-agent-review-render-preamble--single-collaborator ()
  "Single collaborator renders without a trailing separator."
  (let ((p (decknix--agent-review-render-preamble
            "s" "/x" '("solo"))))
    (should (string-match-p "^> collaborators: solo\n" p))
    (should-not (string-match-p "solo," p))))

(ert-deftest decknix-agent-review-render-preamble--strip-meta-roundtrip ()
  "`strip-meta' deletes the `🧭 review meta' marker line of the
preamble, leaving the meta-detail lines and the `📋 instructions'
block in place (current strip-meta behaviour, see existing test
`strip-meta--strips-marker-line-only')."
  (let* ((p (decknix--agent-review-render-preamble
             "*Auggie: foo*" "/x" '("a")))
         (stripped (decknix--agent-review-strip-meta p)))
    (should-not (string-match-p "🧭 \\*\\*review meta\\*\\*" stripped))
    ;; Meta details survive (current behaviour).
    (should (string-match-p "session: \\*Auggie: foo\\*" stripped))
    (should (string-match-p "collaborators: a" stripped))
    ;; Instructions block survives intact.
    (should (string-match-p "📋 \\*\\*instructions" stripped))
    (should (string-match-p "Respond inline using" stripped))))

(provide 'decknix-agent-review-format-test)
;;; decknix-agent-review-format-test.el ends here
