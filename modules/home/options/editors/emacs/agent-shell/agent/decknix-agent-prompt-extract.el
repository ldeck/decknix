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

(defun decknix--prompt-extract-from-file (file)
  "Extract user prompts from a single session FILE using jq.
Returns a list of non-empty strings, newest first.  Returns nil
on shell / parse failure, missing file, or empty / non-array
output -- consumers treat nil as `no prompts'."
  (condition-case nil
      (let* ((jqf (decknix--prompt-extract-ensure-jq-filter))
             (raw (shell-command-to-string
                   (concat "jq -c -f "
                           (shell-quote-argument jqf) " "
                           (shell-quote-argument file)
                           " 2>/dev/null")))
             (trimmed (string-trim raw)))
        (when (and (not (string-empty-p trimmed))
                   (string-prefix-p "[" trimmed))
          (let* ((json-array-type 'list)
                 (json-key-type 'symbol)
                 (msgs (json-read-from-string trimmed)))
            (seq-filter (lambda (m)
                          (and (stringp m)
                               (not (string-empty-p (string-trim m)))))
                        msgs))))
    (error nil)))

(provide 'decknix-agent-prompt-extract)
;;; decknix-agent-prompt-extract.el ends here
