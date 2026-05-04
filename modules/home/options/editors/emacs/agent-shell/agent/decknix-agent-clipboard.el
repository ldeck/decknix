;;; decknix-agent-clipboard.el --- Clipboard URL DWIM helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, clipboard

;;; Commentary:
;;
;; Tiny clipboard input helpers carved out of `decknix-agent-
;; shell-main' (main-bulk) into the `agent-shell/agent/' cluster.
;; Used by interactive `read-string' defaults so the PR-quick-
;; action and review flows can offer a sensible auto-fill when
;; the user has just copied a GitHub URL.
;;
;;   `decknix--agent-clipboard-url'
;;       Returns the contents of the kill ring head (or, when
;;       that is empty, the macOS system clipboard via
;;       `pbpaste') if and only if the text contains a GitHub
;;       PR URL substring.  Returns nil otherwise.  Used as the
;;       default value for `read-string' in the
;;       `decknix-agent-pr-review' / `-investigate-issue'
;;       quick-action prompts.

;;; Code:

(defun decknix--agent-clipboard-url ()
  "Return a GitHub PR URL from the kill ring or system clipboard, or nil."
  (let ((text (or (ignore-errors (current-kill 0 t))
                  (ignore-errors
                    (string-trim
                     (shell-command-to-string "pbpaste"))))))
    (when (and text (string-match-p "github\\.com/.*/pull/" text))
      (string-trim text))))

(provide 'decknix-agent-clipboard)
;;; decknix-agent-clipboard.el ends here
