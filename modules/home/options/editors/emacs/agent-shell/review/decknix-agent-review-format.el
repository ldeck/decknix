;;; decknix-agent-review-format.el --- Review buffer pure formatters -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, review, markdown, format

;;; Commentary:
;;
;; Pure string-formatting primitives extracted from the agent-shell
;; heredoc's review-mode subsystem.  Four helpers operate on string
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
;;   `decknix--agent-review-render-preamble'   (session-name workspace
;;                                              collaborators -> the
;;                                              `🧭 review meta' +
;;                                              `📋 instructions'
;;                                              header that opens
;;                                              every review buffer;
;;                                              consumed by `strip-
;;                                              meta' on the agent
;;                                              route)
;;
;; `format-exchanges' calls `quote' so both belong in the same
;; module.  `strip-meta' is independent but co-located because all
;; four are part of the same render/route pipeline -- preamble in,
;; strip-meta out.

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

(defun decknix--agent-review-render-preamble (session-name workspace collaborators)
  "Return the review-buffer preamble for SESSION-NAME, WORKSPACE, COLLABORATORS.
SESSION-NAME is a display string (typically the source agent-shell
buffer name).  WORKSPACE is a path that gets passed through
`abbreviate-file-name'; nil/empty renders as the empty path.
COLLABORATORS is a list of names rendered comma-separated; the
caller is responsible for placing the review author first.

The output is the `🧭 **review meta**' blockquote followed by the
`📋 **instructions for the agent**' Option-1 contract.  Pure --
no buffer reads, no defvar lookups; the carved counterpart of
`decknix--agent-review-strip-meta', which deletes exactly this
header on the agent route."
  (concat
   "> 🧭 **review meta**\n"
   (format "> session: %s\n" session-name)
   (format "> workspace: %s\n"
           (abbreviate-file-name (or workspace "")))
   (format "> collaborators: %s\n"
           (mapconcat #'identity collaborators ", "))
   "> route: agent  (C-c C-c submits to source session)\n"
   ">\n"
   "> 📋 **instructions for the agent** (Option 1):\n"
   "> Respond inline using `> 💬 **agent:** …` immediately after\n"
   "> each of my annotations. Keep order. Don't collapse multiple\n"
   "> annotations into one reply. For ❌ rejections, propose a\n"
   "> concrete change. For 🔀 option picks, acknowledge the chosen\n"
   "> option and update prior assumptions.\n"
   "\n"))

(provide 'decknix-agent-review-format)
;;; decknix-agent-review-format.el ends here
