;;; decknix-agent-batch-parse.el --- Batch editor parser -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, batch

;;; Commentary:
;;
;; Pure parser for the batch editor buffer (PR B.71), carved out of
;; main-bulk so the divider/group/auto-detect logic can be exercised
;; on plain string input rather than against a full launch
;; environment.
;;
;; Public surface:
;;
;;   `decknix--batch-parse-buffer'  scan current buffer -> spec list
;;
;; Each spec is an alist with keys: name, workspace, items, grouped.
;; Divider lines look like `--- <name> [: <workspace>]'; bare
;; content lines outside any group become single-item ungrouped
;; specs whose name + workspace are auto-derived from the parsed PR
;; URL (or a SHA-based fallback when the URL is unparseable).
;;
;; The interactive launcher (`decknix--batch-launch'), the summary
;; buffer rendering and the user-facing entry points stay in main-
;; bulk per AGENTS.md Rule 2.  The user-tunable
;; `decknix--batch-default-workspace' defvar also stays in main-
;; bulk (it is set interactively and used elsewhere); the parser
;; reads it via dynamic-variable lookup.

;;; Code:

;; Forward declarations -- carved URL parser + workspace heuristic
;; live in `agent-shell/agent/'.
(declare-function decknix--agent-parse-pr-url
                  "decknix-agent-url-parse" (url))
(declare-function decknix--agent-pr-detect-workspace
                  "decknix-agent-workspace-detect" (owner repo))

(defvar decknix--batch-default-workspace)

(defun decknix--batch-parse-buffer ()
  "Parse the batch editor buffer into a list of session specs.
Each spec is an alist with keys: name, workspace, items, grouped."
  (let ((specs nil)
        (current-items nil)
        (current-ws decknix--batch-default-workspace)
        (current-name nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (string-trim
                     (buffer-substring-no-properties
                      (line-beginning-position)
                      (line-end-position)))))
          (cond
           ;; Divider: --- <name> [: <workspace>]
           ((string-match "^---\\s-+\\(.+\\)" line)
            ;; Flush previous group if any
            (when (and current-name current-items)
              (push (list (cons 'name current-name)
                          (cons 'workspace current-ws)
                          (cons 'items (nreverse current-items))
                          (cons 'grouped t))
                    specs))
            ;; Parse new group header
            (let ((header (match-string 1 line)))
              (if (string-match "^\\(.+?\\)\\s-*:\\s-*\\(\\S-+.*\\)" header)
                  (progn
                    (setq current-name (string-trim (match-string 1 header)))
                    (setq current-ws (expand-file-name
                                      (string-trim (match-string 2 header)))))
                (setq current-name (string-trim header))
                (setq current-ws decknix--batch-default-workspace)))
            (setq current-items nil))
           ;; Empty line or comment -- skip
           ((or (string-empty-p line)
                (string-prefix-p "#" line))
            nil)
           ;; Content line
           (t
            (if current-name
                ;; Inside a group
                (push line current-items)
              ;; Ungrouped -- each line is its own session
              (let* ((parsed (decknix--agent-parse-pr-url line))
                     (auto-name (if parsed
                                    (format "pr-%s-%s"
                                            (alist-get 'repo parsed)
                                            (alist-get 'number parsed))
                                  (format "review-%s"
                                          (substring
                                           (secure-hash 'sha256 line)
                                           0 8))))
                     ;; Auto-detect workspace from PR URL
                     (ws (if parsed
                             (or (decknix--agent-pr-detect-workspace
                                  (alist-get 'owner parsed)
                                  (alist-get 'repo parsed))
                                 decknix--batch-default-workspace)
                           decknix--batch-default-workspace)))
                (push (list (cons 'name auto-name)
                            (cons 'workspace ws)
                            (cons 'items (list line))
                            (cons 'grouped nil))
                      specs))))))
        (forward-line 1)))
    ;; Flush final group
    (when (and current-name current-items)
      (push (list (cons 'name current-name)
                  (cons 'workspace current-ws)
                  (cons 'items (nreverse current-items))
                  (cons 'grouped t))
            specs))
    (nreverse specs)))

(provide 'decknix-agent-batch-parse)

;;; decknix-agent-batch-parse.el ends here
