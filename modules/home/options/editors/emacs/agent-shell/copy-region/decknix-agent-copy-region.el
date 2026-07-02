;;; decknix-agent-copy-region.el --- Copy a region in a chosen format -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-table "0.1"))
;; Keywords: agent, agent-shell, decknix, markdown, slack

;;; Commentary:
;;
;; The agent-shell buffer holds raw markdown, so a plain `M-w' yields
;; `**bold**' / `### head' / `[t](u)' which Slack and other tools render
;; wrong.  This package converts a region from markdown into a target
;; syntax before putting it on the kill-ring.
;;
;; The converters are pure string transforms (ERT-tested): Slack mrkdwn
;; (per docs.slack.dev), plain text, and a markdown table-normalising
;; pass.  HTML delegates to pandoc.  The interactive commands + transient
;; live here too; only their key binding is wired in the heredoc
;; (AGENTS.md Rule 2).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'decknix-agent-table)

(declare-function browse-url-of-file "browse-url")

;; -- Shared line walker (fence + table aware) -----------------------

(defun decknix-agent-copy--fence-p (line)
  "Return non-nil when LINE opens or closes a ``` code fence."
  (string-prefix-p "```" (string-trim-left line)))

(defun decknix-agent-copy--walk (md inline-fn table-fn)
  "Walk MD applying TABLE-FN to table blocks and INLINE-FN to other lines.
Lines inside ``` fences pass through verbatim; a fence-open language tag
is stripped so Slack does not render it as literal text."
  (let* ((lines (split-string md "\n"))
         (n (length lines)) (i 0) (in-fence nil) (out '()))
    (while (< i n)
      (let ((line (nth i lines))
            (next (and (< (1+ i) n) (nth (1+ i) lines))))
        (cond
         ((decknix-agent-copy--fence-p line)
          (push "```" out) (setq in-fence (not in-fence) i (1+ i)))
         (in-fence (push line out) (setq i (1+ i)))
         ((and (decknix-agent-table-row-p line)
               (not (decknix-agent-table-separator-p line))
               next (decknix-agent-table-separator-p next))
          (let ((j (+ i 2)))
            (while (and (< j n)
                        (decknix-agent-table-row-p (nth j lines))
                        (not (decknix-agent-table-separator-p (nth j lines))))
              (setq j (1+ j)))
            (push (funcall table-fn (mapconcat #'identity (cl-subseq lines i j) "\n"))
                  out)
            (setq i j)))
         (t (push (funcall inline-fn line) out) (setq i (1+ i))))))
    (mapconcat #'identity (nreverse out) "\n")))

;; -- Slack mrkdwn ---------------------------------------------------

(defun decknix-agent-copy--html-escape (s)
  "HTML-escape &, < and > in S for Slack control-character safety."
  (let ((s (replace-regexp-in-string "&" "&amp;" s t t)))
    (setq s (replace-regexp-in-string "<" "&lt;" s t t))
    (replace-regexp-in-string ">" "&gt;" s t t)))

(defun decknix-agent-copy--slack-spans (line)
  "Convert inline markdown emphasis/links in LINE to Slack mrkdwn.
Bold is collapsed to sentinel control chars before italics so the
single-star italic pass cannot re-eat it; &/</> are HTML-escaped before
links are formed so the link's own angle brackets survive."
  (let ((s line))
    ;; Bold (** or __) -> sentinels (restored to single * at the end).
    (setq s (replace-regexp-in-string "\\*\\*\\([^*]+\\)\\*\\*" "\x01\\1\x02" s))
    (setq s (replace-regexp-in-string "__\\([^_]+\\)__" "\x01\\1\x02" s))
    ;; Strike (~~) -> single ~.
    (setq s (replace-regexp-in-string "~~\\([^~]+\\)~~" "~\\1~" s))
    ;; Italic (*) -> _ ; underscore italic is already valid Slack.
    (setq s (replace-regexp-in-string "\\*\\([^*]+\\)\\*" "_\\1_" s))
    ;; Escape control chars in the remaining plain text, then form links
    ;; (which introduce their own, intentionally unescaped, < >).
    (setq s (decknix-agent-copy--html-escape s))
    (setq s (replace-regexp-in-string "\\[\\([^]]+\\)\\](\\([^)]+\\))" "<\\2|\\1>" s))
    ;; Restore the bold sentinels.
    (setq s (replace-regexp-in-string "\x01" "*" s t t))
    (replace-regexp-in-string "\x02" "*" s t t)))

(defun decknix-agent-copy--slack-line (line)
  "Convert one markdown LINE (outside fences/tables) to Slack mrkdwn."
  (cond
   ((string-match "\\`[ \t]*#+[ \t]+\\(.*\\)\\'" line)
    (concat "*" (decknix-agent-copy--slack-spans (match-string 1 line)) "*"))
   ((string-match "\\`\\([ \t]*\\)[-*+][ \t]+\\(.*\\)\\'" line)
    (concat (match-string 1 line) "• "
            (decknix-agent-copy--slack-spans (match-string 2 line))))
   ((string-match "\\`\\([ \t]*\\)>[ \t]?\\(.*\\)\\'" line)
    (concat (match-string 1 line) "> "
            (decknix-agent-copy--slack-spans (match-string 2 line))))
   (t (decknix-agent-copy--slack-spans line))))

(defun decknix-agent-copy-md->slack (md)
  "Convert MD (GitHub-flavoured markdown) into Slack mrkdwn."
  (decknix-agent-copy--walk
   md #'decknix-agent-copy--slack-line
   (lambda (block) (concat "```\n" (decknix-agent-table-format block) "\n```"))))

;; -- Plain text -----------------------------------------------------

(defun decknix-agent-copy--plain-spans (s)
  "Strip inline markdown emphasis/links from S, leaving readable text."
  (setq s (replace-regexp-in-string "`\\([^`]+\\)`" "\\1" s))
  (setq s (replace-regexp-in-string "\\*\\*\\([^*]+\\)\\*\\*" "\\1" s))
  (setq s (replace-regexp-in-string "__\\([^_]+\\)__" "\\1" s))
  (setq s (replace-regexp-in-string "~~\\([^~]+\\)~~" "\\1" s))
  (setq s (replace-regexp-in-string "\\*\\([^*]+\\)\\*" "\\1" s))
  (replace-regexp-in-string "\\[\\([^]]+\\)\\](\\([^)]+\\))" "\\1 (\\2)" s))

(defun decknix-agent-copy--plain-line (line)
  "Convert one markdown LINE to plain text."
  (cond
   ((string-match "\\`[ \t]*#+[ \t]+\\(.*\\)\\'" line)
    (decknix-agent-copy--plain-spans (match-string 1 line)))
   ((string-match "\\`\\([ \t]*\\)[-*+][ \t]+\\(.*\\)\\'" line)
    (concat (match-string 1 line) "• "
            (decknix-agent-copy--plain-spans (match-string 2 line))))
   (t (decknix-agent-copy--plain-spans line))))

(defun decknix-agent-copy-md->plain (md)
  "Convert MD into plain text (emphasis stripped, tables aligned)."
  (decknix-agent-copy--walk
   md #'decknix-agent-copy--plain-line
   (lambda (block) (decknix-agent-table-format block))))

;; -- Markdown (table-normalising) -----------------------------------

(defun decknix-agent-copy-md->markdown (md)
  "Return MD unchanged except that GFM tables are re-aligned."
  (decknix-agent-copy--walk
   md #'identity
   (lambda (block) (decknix-agent-table-format block))))

;; -- Atlassian wiki markup (Jira / Confluence) ----------------------
;;
;; Atlassian's wiki markup (used by Jira issue fields and Confluence
;; "insert markup") is single-`*' bold, `_' italic, `-' strike,
;; `{{monospace}}', `hN.' headings, `[text|url]' links, `*'/`#' lists,
;; `bq.' quotes, `{code}' fences and `||h||' / `|c|' tables.  Pure
;; string transform, same shape as the Slack converter.

(defun decknix-agent-copy--atlassian-spans (line)
  "Convert inline markdown emphasis/links/code in LINE to Atlassian markup.
Bold is parked on sentinel control chars before the italic pass so the
single-star italic rule cannot re-eat it (mirrors the Slack converter)."
  (let ((s line))
    ;; Inline code -> {{monospace}}.
    (setq s (replace-regexp-in-string "`\\([^`]+\\)`" "{{\\1}}" s))
    ;; Bold (** or __) -> sentinels (restored to single * at the end).
    (setq s (replace-regexp-in-string "\\*\\*\\([^*]+\\)\\*\\*" "\x01\\1\x02" s))
    (setq s (replace-regexp-in-string "__\\([^_]+\\)__" "\x01\\1\x02" s))
    ;; Strike (~~) -> -...-.
    (setq s (replace-regexp-in-string "~~\\([^~]+\\)~~" "-\\1-" s))
    ;; Italic (*) -> _ ; underscore italic is already valid Atlassian.
    (setq s (replace-regexp-in-string "\\*\\([^*]+\\)\\*" "_\\1_" s))
    ;; Links [text](url) -> [text|url].
    (setq s (replace-regexp-in-string "\\[\\([^]]+\\)\\](\\([^)]+\\))" "[\\1|\\2]" s))
    ;; Restore the bold sentinels.
    (setq s (replace-regexp-in-string "\x01" "*" s t t))
    (replace-regexp-in-string "\x02" "*" s t t)))

(defun decknix-agent-copy--atlassian-line (line)
  "Convert one markdown LINE (outside fences/tables) to Atlassian markup."
  (cond
   ((string-match "\\`[ \t]*\\(#+\\)[ \t]+\\(.*\\)\\'" line)
    (format "h%d. %s" (min 6 (length (match-string 1 line)))
            (decknix-agent-copy--atlassian-spans (match-string 2 line))))
   ((string-match "\\`\\([ \t]*\\)[-*+][ \t]+\\(.*\\)\\'" line)
    (concat (make-string (1+ (/ (length (match-string 1 line)) 2)) ?*) " "
            (decknix-agent-copy--atlassian-spans (match-string 2 line))))
   ((string-match "\\`\\([ \t]*\\)[0-9]+\\.[ \t]+\\(.*\\)\\'" line)
    (concat (make-string (1+ (/ (length (match-string 1 line)) 2)) ?#) " "
            (decknix-agent-copy--atlassian-spans (match-string 2 line))))
   ((string-match "\\`[ \t]*>[ \t]?\\(.*\\)\\'" line)
    (concat "bq. " (decknix-agent-copy--atlassian-spans (match-string 1 line))))
   (t (decknix-agent-copy--atlassian-spans line))))

(defun decknix-agent-copy--atlassian-table (block)
  "Convert a GFM table BLOCK (header, separator, rows) to Atlassian markup.
The header row uses `||' delimiters; body rows use `|'.  Empty cells are
padded with a space so Atlassian does not collapse adjacent pipes."
  (let ((rows (seq-remove #'decknix-agent-table-separator-p
                          (split-string block "\n")))
        (first t) (out '()))
    (dolist (row rows)
      (let* ((cells (mapcar (lambda (c)
                              (let ((v (decknix-agent-copy--atlassian-spans c)))
                                (if (string-empty-p v) " " v)))
                            (decknix-agent-table-split-row row)))
             (sep (if first "||" "|")))
        (push (concat sep (string-join cells sep) sep) out)
        (setq first nil)))
    (string-join (nreverse out) "\n")))

(defun decknix-agent-copy-md->atlassian (md)
  "Convert MD (GitHub-flavoured markdown) into Atlassian/Confluence markup."
  (let ((walked (decknix-agent-copy--walk
                 md #'decknix-agent-copy--atlassian-line
                 #'decknix-agent-copy--atlassian-table)))
    ;; The shared walker emits bare ``` fence delimiters (valid for Slack);
    ;; Atlassian opens and closes code blocks with the same {code} token.
    (replace-regexp-in-string "^```$" "{code}" walked)))

;; -- HTML (pandoc) --------------------------------------------------

(defun decknix-agent-copy-html-command ()
  "Return the pandoc argv used to convert GFM markdown to HTML."
  (list "pandoc" "-f" "gfm" "-t" "html"))

(defun decknix-agent-copy-md->html (md)
  "Convert MD to HTML via pandoc; signal a `user-error' if it is missing."
  (let ((cmd (decknix-agent-copy-html-command)))
    (unless (executable-find (car cmd))
      (user-error "pandoc not found on PATH; cannot convert to HTML"))
    (with-temp-buffer
      (insert md)
      (let ((status (apply #'call-process-region (point-min) (point-max)
                           (car cmd) t t nil (cdr cmd))))
        (unless (eq status 0)
          (user-error "pandoc failed (exit %s)" status))
        (string-trim-right (buffer-string))))))

;; -- PDF (pandoc + PDF engine) --------------------------------------
;;
;; Unlike the kill-ring converters above, PDF is a binary artefact, so
;; it is written to a file via pandoc + a PDF engine.  The engine is
;; auto-detected from a preference list (lightweight HTML/typst engines
;; before the heavier LaTeX ones); the argv builder + detection stay
;; pure so they are ERT-tested without a subprocess.

(defvar decknix-agent-copy-pdf-engines
  '("typst" "tectonic" "weasyprint" "wkhtmltopdf" "xelatex" "pdflatex")
  "Preference-ordered pandoc `--pdf-engine' candidates.
The first one found on PATH is used.")

(defun decknix-agent-copy-pdf-engine ()
  "Return the first `decknix-agent-copy-pdf-engines' entry on PATH, or nil."
  (seq-find #'executable-find decknix-agent-copy-pdf-engines))

(defun decknix-agent-copy-pdf-command (outfile &optional engine)
  "Return the pandoc argv that renders GFM markdown to OUTFILE as PDF.
ENGINE defaults to `decknix-agent-copy-pdf-engine'; when non-nil it is
passed as `--pdf-engine=ENGINE'."
  (let ((eng (or engine (decknix-agent-copy-pdf-engine))))
    (append (list "pandoc" "-f" "gfm" "-o" outfile)
            (and eng (list (concat "--pdf-engine=" eng))))))

(defun decknix-agent-copy--pdf-default-name ()
  "Default output filename for a PDF region export."
  (format "agent-export-%s.pdf" (format-time-string "%Y%m%d-%H%M%S")))

(defun decknix-agent-copy-md->pdf (md outfile)
  "Render MD (GFM markdown) to OUTFILE as PDF via pandoc.
Signals a `user-error' when pandoc or a PDF engine is missing, or when
pandoc exits non-zero.  Returns OUTFILE on success."
  (unless (executable-find "pandoc")
    (user-error "pandoc not found on PATH; cannot export PDF"))
  (unless (decknix-agent-copy-pdf-engine)
    (user-error "No PDF engine found (install one of: %s)"
                (string-join decknix-agent-copy-pdf-engines ", ")))
  (let ((cmd (decknix-agent-copy-pdf-command outfile)))
    (with-temp-buffer
      (insert md)
      (let ((status (apply #'call-process-region (point-min) (point-max)
                           (car cmd) nil nil nil (cdr cmd))))
        (unless (eq status 0)
          (user-error "pandoc failed (exit %s)" status))
        outfile))))

;; -- Interactive commands + transient ------------------------------
;;
;; These have side effects only when invoked (region read + `kill-new'),
;; not at load time, so they live here; only the prefix key binding is
;; wired in the heredoc.

(require 'transient)

(defun decknix-agent-copy--do (beg end fn label)
  "Convert region BEG..END with FN and put it on the kill-ring.
LABEL names the format for the echo-area confirmation."
  (let ((out (funcall fn (buffer-substring-no-properties beg end))))
    (kill-new out)
    (message "Copied region as %s (%d chars)" label (length out))))

(defun decknix-agent-copy-region-as-markdown (beg end)
  "Copy region BEG..END as markdown with tables re-aligned."
  (interactive "r")
  (decknix-agent-copy--do beg end #'decknix-agent-copy-md->markdown "Markdown"))

(defun decknix-agent-copy-region-as-slack (beg end)
  "Copy region BEG..END converted to Slack mrkdwn."
  (interactive "r")
  (decknix-agent-copy--do beg end #'decknix-agent-copy-md->slack "Slack mrkdwn"))

(defun decknix-agent-copy-region-as-html (beg end)
  "Copy region BEG..END converted to HTML via pandoc."
  (interactive "r")
  (decknix-agent-copy--do beg end #'decknix-agent-copy-md->html "HTML"))

(defun decknix-agent-copy-region-as-plain (beg end)
  "Copy region BEG..END converted to plain text."
  (interactive "r")
  (decknix-agent-copy--do beg end #'decknix-agent-copy-md->plain "plain text"))

(defun decknix-agent-copy-region-as-atlassian (beg end)
  "Copy region BEG..END converted to Atlassian (Jira/Confluence) markup."
  (interactive "r")
  (decknix-agent-copy--do beg end #'decknix-agent-copy-md->atlassian "Atlassian markup"))

(defun decknix-agent-copy-region-as-pdf (beg end outfile)
  "Export region BEG..END (markdown) to OUTFILE as PDF via pandoc.
Prompts for OUTFILE and offers to open the result once written."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end)
             (expand-file-name
              (read-file-name "Export PDF to: " nil nil nil
                              (decknix-agent-copy--pdf-default-name))))
     (user-error "Select a region to export as PDF")))
  (decknix-agent-copy-md->pdf (buffer-substring-no-properties beg end) outfile)
  (message "Exported region to %s" outfile)
  (when (y-or-n-p (format "Open %s? " (file-name-nondirectory outfile)))
    (browse-url-of-file outfile)))

;; -- On-demand table reformat (in place) ---------------------------

(defun decknix-agent-copy--reformat-region (beg end)
  "Replace the table text in BEG..END with its formatted form.
Width-aware: aligns, or reflows to a bullet list when the aligned table
would exceed the window width.  Honours read-only via `inhibit-read-only'
since the user invokes this explicitly."
  (let* ((text (buffer-substring-no-properties beg end))
         (new (decknix-agent-table-format text (window-body-width))))
    (if (string= new text)
        (message "Table already formatted")
      (let ((inhibit-read-only t))
        (save-excursion (goto-char beg) (delete-region beg end) (insert new)))
      (message "Reformatted table"))))

(defun decknix-agent-table-reformat ()
  "Reformat the GFM table in the region, or the table at point.
Columns are aligned so the pipes line up; when the aligned table would
be wider than the window it is reflowed into a per-row bullet list."
  (interactive)
  (if (use-region-p)
      (decknix-agent-copy--reformat-region (region-beginning) (region-end))
    (let* ((lines (split-string
                   (buffer-substring-no-properties (point-min) (point-max)) "\n"))
           (idx (1- (line-number-at-pos (point))))
           (b (decknix-agent-table-block-bounds lines idx)))
      (unless b (user-error "No table at point"))
      (let ((beg (save-excursion (goto-char (point-min))
                                 (forward-line (car b)) (line-beginning-position)))
            (end (save-excursion (goto-char (point-min))
                                 (forward-line (1- (cdr b))) (line-end-position))))
        (decknix-agent-copy--reformat-region beg end)))))

(transient-define-prefix decknix-agent-copy-transient ()
  "Copy the active region in a chosen format, or reformat a table."
  ["Copy region as…"
   ("m" "Markdown (tables aligned)" decknix-agent-copy-region-as-markdown)
   ("s" "Slack mrkdwn" decknix-agent-copy-region-as-slack)
   ("h" "HTML (pandoc)" decknix-agent-copy-region-as-html)
   ("a" "Atlassian (Jira/Confluence)" decknix-agent-copy-region-as-atlassian)
   ("p" "Plain text" decknix-agent-copy-region-as-plain)]
  ["Export region to file"
   ("P" "PDF (pandoc)" decknix-agent-copy-region-as-pdf)]
  ["Reformat in place"
   ("t" "Table at point / in region" decknix-agent-table-reformat)])

(provide 'decknix-agent-copy-region)
;;; decknix-agent-copy-region.el ends here
