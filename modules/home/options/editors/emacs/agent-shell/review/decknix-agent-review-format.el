;;; decknix-agent-review-format.el --- Review buffer pure formatters -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, review, markdown, format

;;; Commentary:
;;
;; Pure string-formatting primitives extracted from the agent-shell
;; heredoc's review-mode subsystem.  Three helpers operate on string
;; inputs and return strings; none read or write buffers, files, or
;; globals.
;;
;;   `decknix--agent-review-quote'             (string -> blockquoted
;;                                              string with `> ' on
;;                                              every line; nil/empty
;;                                              becomes "> _(empty)_")
;;   `decknix--agent-review-format-exchanges'  ((USER . RESP) list ->
;;                                              markdown sections
;;                                              joined by `\n---\n\n')
;;   `decknix--agent-review-strip-meta'        (content with leading
;;                                              `🧭 **review meta**'
;;                                              blockquote -> content
;;                                              with that block
;;                                              elided up to but not
;;                                              including the `📋
;;                                              **instructions**'
;;                                              block)
;;
;; `format-exchanges' calls `quote' so both belong in the same
;; module.  `strip-meta' is independent but co-located because all
;; three are part of the same render/route pipeline.

;;; Code:

(defun decknix--agent-review-quote (text)
  "Prefix each line of TEXT with `> ' for a markdown blockquote."
  (if (or (null text) (string-empty-p text))
      "> _(empty)_"
    (mapconcat (lambda (line) (concat "> " line))
               (split-string text "\n")
               "\n")))

(defun decknix--agent-review-format-exchanges (exchanges)
  "Render EXCHANGES as markdown blockquote sections.
EXCHANGES is a list of (USER-MSG . ASSISTANT-RESP) cons cells."
  (mapconcat
   (lambda (ex)
     (let ((user (car ex))
           (resp (cdr ex)))
       (concat
        "## prompt\n\n"
        (decknix--agent-review-quote (or user "")) "\n\n"
        "## agent response\n\n"
        (decknix--agent-review-quote (or resp "")) "\n\n"
        "## annotations\n\n"
        "<!-- ,c ,a ,r ,o ,m ,f ,A — annotate here -->\n\n")))
   exchanges
   "\n---\n\n"))

(defun decknix--agent-review-strip-meta (content)
  "Return CONTENT with the leading `🧭 **review meta**' block removed.
Keeps the `📋 **instructions for the agent**' block intact so the
agent sees the Option-1 reply contract."
  (with-temp-buffer
    (insert content)
    (goto-char (point-min))
    (when (re-search-forward "^> 🧭 \\*\\*review meta\\*\\*" nil t)
      (let ((start (line-beginning-position)))
        ;; Skip consecutive blockquote lines until the separator `>` line.
        (while (and (not (eobp))
                    (looking-at "^> ")
                    (not (looking-at "^> 📋")))
          (forward-line 1))
        ;; Also drop the single `>\n' spacer between meta and instructions.
        (when (looking-at "^>\n")
          (forward-line 1))
        (delete-region start (point))))
    (buffer-string)))

(provide 'decknix-agent-review-format)
;;; decknix-agent-review-format.el ends here
