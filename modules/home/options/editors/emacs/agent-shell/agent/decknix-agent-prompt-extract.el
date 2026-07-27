;;; decknix-agent-prompt-extract.el --- Per-file prompt extraction via jq -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, prompt, history

;;; Commentary:
;;
;; On-demand extraction of user prompts from a single auggie session
;; JSON file using jq.  The filter is the moral inverse of the
;; session-cache jq script -- it walks `chatHistory[].exchange
;; .request_message', drops empty strings, and reverses so the newest
;; prompt is first in the returned list.
;;
;; Two consumers in main-bulk drive this:
;;
;;   * `decknix--agent-session-restore-input-ring' -- seeds
;;     `comint-input-ring' on session resume so M-p / M-n cycle past
;;     prompts (oldest pushed first so newest sits at index 0).
;;
;;   * `decknix--compose-history-load-next-batch' -- streams older
;;     sessions' prompts on demand for the M-P / M-N (cross-session)
;;     compose history walk.
;;
;; Plus the workspace-side `decknix--prompt-search-jq-cmd' reuses
;; the cached filter file via `decknix--prompt-extract-ensure-jq-filter'
;; for the parallel xargs prompt-search build.
;;
;; Public surface:
;;
;;   `decknix--prompt-extract-ensure-jq-filter' -- write the jq
;;       script to a temp file once and return its path.  Idempotent
;;       and safe to call from any consumer; the resulting path is
;;       cached in `decknix--prompt-extract-jq-filter-file' for the
;;       lifetime of the Emacs session.
;;
;;   `decknix--prompt-extract-from-file' (file) -- run jq against
;;       FILE and return the list of non-empty user prompts as
;;       strings, newest first.  nil on parse failure / missing
;;       file / empty array (consumers treat nil as "no prompts").

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defvar decknix--prompt-extract-jq-filter-file nil
  "Path to temp file containing the jq filter for single-file extraction.")

(defun decknix--prompt-extract-ensure-jq-filter ()
  "Create the jq filter file for per-file prompt extraction.
Returns its path.  Idempotent: writes the file on the first call
(or after a tmp cleanup deleted it) and returns the cached path
on subsequent calls."
  (unless (and decknix--prompt-extract-jq-filter-file
              (file-exists-p decknix--prompt-extract-jq-filter-file))
    (setq decknix--prompt-extract-jq-filter-file
          (make-temp-file "auggie-extract-" nil ".jq"))
    (with-temp-file decknix--prompt-extract-jq-filter-file
      (insert "[.chatHistory[].exchange.request_message"
              " // \"\" | select(length > 0)] | reverse\n")))
  decknix--prompt-extract-jq-filter-file)

;; ── Hexagonal extraction: one PORT, per-provider ADAPTERS ──────────────
;;
;; A session file's on-disk shape differs per agent backend (auggie: a single
;; JSON with `chatHistory[].exchange'; claude-code: line-delimited `.jsonl'
;; with `{"type":"user","message":{"content":...}}'; pi/gemini: TBD).  So
;; prompt extraction is a PORT — `decknix--prompt-extract-from-file' — that
;; dispatches to a per-provider ADAPTER keyed by provider-id.  The core knows
;; no format; a new backend plugs in by registering an adapter fn (FILE -> list
;; of prompt strings, NEWEST FIRST) in `decknix-prompt-extract-adapters'.

(defvar decknix-prompt-extract-adapters
  '((auggie      . decknix--prompt-extract-auggie)
    (claude-code . decknix--prompt-extract-claude))
  "Alist of provider-id -> prompt-extraction adapter fn.
Each adapter takes a session FILE and returns the user's prompt strings, NEWEST
FIRST.  Providers with no entry fall back to the auggie adapter (safe: it
yields nil for a non-auggie file).  Register an adapter to add a backend (pi,
gemini, ...).")

(defun decknix--prompt-extract-adapter (provider-id)
  "Return the prompt-extraction adapter fn for PROVIDER-ID (auggie default)."
  (or (cdr (assq provider-id decknix-prompt-extract-adapters))
      #'decknix--prompt-extract-auggie))

(defun decknix--prompt-extract-parse-ndjson-strings (raw)
  "Parse RAW (newline-delimited JSON) into its non-blank string values.
Returns them in INPUT order; non-string, blank, or unparseable lines drop."
  (let ((json-array-type 'list) (json-key-type 'symbol) (out nil))
    (dolist (line (split-string (or raw "") "\n" t) (nreverse out))
      (let ((s (ignore-errors (json-read-from-string line))))
        (when (and (stringp s) (not (string-empty-p (string-trim s))))
          (push s out))))))

(defun decknix--prompt-extract-claude (file)
  "Adapter: user prompts from a Claude `.jsonl' session FILE, newest first.
jq STREAMS the file line by line (no slurp — low memory), taking the text of
each `type==user' message; tool-result-only messages collapse to \"\" and are
dropped in elisp.  Unbounded but cheap (~1 s on a 17 MB / 6 k-line transcript)
and run once on resume; a line/byte cap was rejected because it under-samples
tool-heavy sessions (recent turns are mostly tool-result `user' messages)."
  (let* ((jq (concat "select(.type==\"user\") | "
                     "(.message.content | if type==\"array\" then "
                     "(map(select(.type==\"text\")|.text)|join(\"\\n\")) "
                     "else . end) | select(type==\"string\")"))
         (cmd (format "jq -c %s %s 2>/dev/null"
                      (shell-quote-argument jq)
                      (shell-quote-argument file)))
         (raw (shell-command-to-string cmd)))
    ;; jq emits oldest-first; reverse to newest-first.
    (nreverse (decknix--prompt-extract-parse-ndjson-strings raw))))

(defun decknix--prompt-extract-auggie (file)
  "Adapter: user prompts from an auggie session FILE (single JSON), newest first."
  (let* ((jqf (decknix--prompt-extract-ensure-jq-filter))
         (raw (shell-command-to-string
               (concat "jq -c -f " (shell-quote-argument jqf) " "
                       (shell-quote-argument file) " 2>/dev/null")))
         (trimmed (string-trim raw)))
    (when (and (not (string-empty-p trimmed))
               (string-prefix-p "[" trimmed))
      (let ((json-array-type 'list) (json-key-type 'symbol))
        (seq-filter (lambda (m)
                      (and (stringp m) (not (string-empty-p (string-trim m)))))
                    (json-read-from-string trimmed))))))

(defun decknix--prompt-extract-from-file (file &optional provider-id)
  "Extract the user's prompts from session FILE (newest first).
PORT of the hexagonal extraction: dispatches to the per-provider adapter in
`decknix-prompt-extract-adapters' (PROVIDER-ID nil -> auggie default).  Returns
nil on a missing file or any adapter/parse failure -- consumers treat nil as
`no prompts'."
  (when (and file (stringp file) (file-exists-p file))
    (condition-case nil
        (funcall (decknix--prompt-extract-adapter provider-id) file)
      (error nil))))

(provide 'decknix-agent-prompt-extract)
;;; decknix-agent-prompt-extract.el ends here
