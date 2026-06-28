;;; decknix-agent-copy-region-test.el --- Tests for copy-as-format -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-copy-region "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning the pure markdown converters used by the
;; copy-region-as-format commands: markdown -> Slack mrkdwn, markdown ->
;; plain text, and markdown -> markdown (table-normalising pass).  The
;; Slack mapping follows docs.slack.dev (single `*' bold, single `~'
;; strike, `<url|text>' links, no headings -> bold line, `&'/`<'/`>'
;; HTML-escaped, tables -> aligned code block).  The HTML path shells out
;; to pandoc and is covered only by an argv-shape test (no subprocess).

;;; Code:

(require 'ert)
(require 'decknix-test-helpers)
(require 'decknix-agent-table)
(require 'decknix-agent-copy-region)

(defconst decknix-agent-copy-test--table
  "| Name | Age | City |\n|---|---|---|\n| Alice | 30 | NYC |\n| Bob | 5 | LA |")

(defconst decknix-agent-copy-test--aligned
  (concat "| Name  | Age | City |\n"
          "| ----- | --- | ---- |\n"
          "| Alice | 30  | NYC  |\n"
          "| Bob   | 5   | LA   |"))

;; -- Slack inline mapping -------------------------------------------

(ert-deftest decknix-agent-copy/slack-bold ()
  (should (string= "*x*" (decknix-agent-copy-md->slack "**x**")))
  (should (string= "*x*" (decknix-agent-copy-md->slack "__x__"))))

(ert-deftest decknix-agent-copy/slack-italic ()
  (should (string= "_x_" (decknix-agent-copy-md->slack "*x*")))
  (should (string= "_x_" (decknix-agent-copy-md->slack "_x_"))))

(ert-deftest decknix-agent-copy/slack-bold-not-clobbered-by-italic ()
  "Bold collapses to a single star without the italic pass re-eating it."
  (should (string= "a *b* c" (decknix-agent-copy-md->slack "a **b** c"))))

(ert-deftest decknix-agent-copy/slack-strike ()
  (should (string= "~x~" (decknix-agent-copy-md->slack "~~x~~"))))

(ert-deftest decknix-agent-copy/slack-heading-becomes-bold-line ()
  (should (string= "*Heading*" (decknix-agent-copy-md->slack "# Heading")))
  (should (string= "*Sub*" (decknix-agent-copy-md->slack "### Sub"))))

(ert-deftest decknix-agent-copy/slack-link ()
  (should (string= "<https://x.com|text>"
                   (decknix-agent-copy-md->slack "[text](https://x.com)"))))

(ert-deftest decknix-agent-copy/slack-list-bullet ()
  (should (string= "• item" (decknix-agent-copy-md->slack "- item")))
  (should (string= "• item" (decknix-agent-copy-md->slack "* item"))))

(ert-deftest decknix-agent-copy/slack-blockquote-kept ()
  (should (string= "> quote" (decknix-agent-copy-md->slack "> quote"))))

(ert-deftest decknix-agent-copy/slack-inline-code-kept ()
  (should (string= "`code`" (decknix-agent-copy-md->slack "`code`"))))

(ert-deftest decknix-agent-copy/slack-html-escapes-specials ()
  (should (string= "a &lt; b &amp; c &gt; d"
                   (decknix-agent-copy-md->slack "a < b & c > d"))))

(ert-deftest decknix-agent-copy/slack-table-becomes-code-block ()
  (should (null (decknix-test-render-snapshot
                 (decknix-agent-copy-md->slack decknix-agent-copy-test--table)
                 (concat "```\n" decknix-agent-copy-test--aligned "\n```")))))

(ert-deftest decknix-agent-copy/slack-multiline ()
  (let ((in (concat "# Title\n\nSome **bold** and a [link](https://x.com).\n\n"
                    "- one\n- two"))
        (out (concat "*Title*\n\nSome *bold* and a <https://x.com|link>.\n\n"
                     "• one\n• two")))
    (should (null (decknix-test-render-snapshot
                   (decknix-agent-copy-md->slack in) out)))))

(ert-deftest decknix-agent-copy/slack-fence-passes-through ()
  "Lines inside a code fence are not inline-transformed; lang tag stripped."
  (let ((in "```elisp\n(format \"**x**\")\n```")
        (out "```\n(format \"**x**\")\n```"))
    (should (null (decknix-test-render-snapshot
                   (decknix-agent-copy-md->slack in) out)))))

;; -- Plain text -----------------------------------------------------

(ert-deftest decknix-agent-copy/plain-strips-emphasis ()
  (should (string= "bold" (decknix-agent-copy-md->plain "**bold**")))
  (should (string= "italic" (decknix-agent-copy-md->plain "*italic*")))
  (should (string= "code" (decknix-agent-copy-md->plain "`code`"))))

(ert-deftest decknix-agent-copy/plain-heading-and-link ()
  (should (string= "Heading" (decknix-agent-copy-md->plain "## Heading")))
  (should (string= "text (https://x.com)"
                   (decknix-agent-copy-md->plain "[text](https://x.com)"))))

(ert-deftest decknix-agent-copy/plain-table-aligned ()
  (should (null (decknix-test-render-snapshot
                 (decknix-agent-copy-md->plain decknix-agent-copy-test--table)
                 decknix-agent-copy-test--aligned))))

;; -- Markdown (table-normalising) -----------------------------------

(ert-deftest decknix-agent-copy/markdown-normalises-tables ()
  (let ((in (concat "Intro\n\n" decknix-agent-copy-test--table "\n\nOutro"))
        (out (concat "Intro\n\n" decknix-agent-copy-test--aligned "\n\nOutro")))
    (should (null (decknix-test-render-snapshot
                   (decknix-agent-copy-md->markdown in) out)))))

(ert-deftest decknix-agent-copy/markdown-leaves-prose-untouched ()
  (should (string= "**bold** stays"
                   (decknix-agent-copy-md->markdown "**bold** stays"))))

;; -- HTML argv shape ------------------------------------------------

(ert-deftest decknix-agent-copy/html-command-is-pandoc-gfm ()
  (should (equal '("pandoc" "-f" "gfm" "-t" "html")
                 (decknix-agent-copy-html-command))))

;; -- PDF (pandoc + PDF engine) --------------------------------------

(ert-deftest decknix-agent-copy/pdf-command-shape ()
  "With an explicit engine the pandoc PDF argv is deterministic."
  (should (equal '("pandoc" "-f" "gfm" "-o" "/tmp/x.pdf"
                   "--pdf-engine=weasyprint")
                 (decknix-agent-copy-pdf-command "/tmp/x.pdf" "weasyprint"))))

(ert-deftest decknix-agent-copy/pdf-engine-picks-first-available ()
  "Engine detection returns the first candidate present on PATH."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (p) (and (string= p "wkhtmltopdf") "/bin/wkhtmltopdf"))))
    (let ((decknix-agent-copy-pdf-engines '("typst" "wkhtmltopdf" "pdflatex")))
      (should (string= "wkhtmltopdf" (decknix-agent-copy-pdf-engine))))))

(ert-deftest decknix-agent-copy/pdf-engine-nil-when-none ()
  (cl-letf (((symbol-function 'executable-find) (lambda (_p) nil)))
    (should (null (decknix-agent-copy-pdf-engine)))))

(ert-deftest decknix-agent-copy/pdf-default-name-is-pdf ()
  (should (string-suffix-p ".pdf" (decknix-agent-copy--pdf-default-name))))

(provide 'decknix-agent-copy-region-test)
;;; decknix-agent-copy-region-test.el ends here
