;;; decknix-agent-prompt-search.el --- jq command builder for cross-session prompt search -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, prompt, search

;;; Commentary:
;;
;; Pure shell-string builder for the cross-session prompt-search
;; pipeline.  The complement to `decknix--agent-session-jq-cmd' (in
;; `decknix-agent-session-cache') -- both shell out to `find | xargs
;; -P8' over `~/.augment/sessions/*.json' but with different jq
;; filters: session-cache extracts session metadata, this one extracts
;; the user prompt arrays for the consult-based history search.
;;
;; Two consumers in main-bulk drive this:
;;
;;   * `decknix--prompt-search-refresh-sync' -- synchronous fetch on
;;     first M-r press; blocks for ~5s while jq fans out across all
;;     session files.
;;
;;   * `decknix--prompt-search-refresh-async' -- background refresh
;;     after the cache TTL (5 min) elapses; serves the previous list
;;     to the picker while jq runs.
;;
;; The result of the shell command is one JSON array per line, one
;; per session file; `decknix--prompt-search-parse' (in
;; `decknix-agent-parse') flattens it into the consult candidate list.
;;
;; Public surface:
;;
;;   `decknix--prompt-search-jq-cmd' -- returns the shell command
;;       string.  Pure relative to the cached jq filter file (owned
;;       by `decknix-agent-prompt-extract') and `decknix--agent-
;;       sessions-dir' (owned by `decknix-agent-session-cache').
;;       Tests stub both via `cl-letf' so the suite never reaches
;;       the real `~/.augment/sessions/' tree or jq.

;;; Code:

(require 'cl-lib)

;; Forward declaration: the cached jq filter path lives in the
;; sibling `decknix-agent-prompt-extract' package, loaded by the
;; heredoc immediately before this module.
(declare-function decknix--prompt-extract-ensure-jq-filter
                  "decknix-agent-prompt-extract")
;; The sessions-dir defvar lives in `decknix-agent-session-cache';
;; declared here so the byte-compiler knows it is a special variable.
(defvar decknix--agent-sessions-dir)

(defun decknix--prompt-search-jq-cmd ()
  "Shell command to extract all user prompts from all sessions.
Outputs one JSON array per line (one per session file)."
  (let ((jqf (decknix--prompt-extract-ensure-jq-filter)))
    (concat
     "find " (shell-quote-argument decknix--agent-sessions-dir)
     " -maxdepth 1 -name '*.json' -print0 2>/dev/null"
     " | xargs -0 -P8 -I{}"
     " sh -c 'jq -c -f \"$1\" \"$2\" 2>/dev/null || true' _ "
     (shell-quote-argument jqf) " {}")))

(provide 'decknix-agent-prompt-search)
;;; decknix-agent-prompt-search.el ends here
