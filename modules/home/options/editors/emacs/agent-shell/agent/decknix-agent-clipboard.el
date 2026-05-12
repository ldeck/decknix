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
;;
;;   `decknix--clipboard-github-pr-url'
;;       Stricter sibling: returns the kill ring head only when
;;       it parses as a fully-qualified GitHub PR URL
;;       (`https://github.com/OWNER/REPO/pull/N').  No `pbpaste'
;;       fallback because the link / unlink interactive flows
;;       call `current-kill' explicitly.
;;
;;   `decknix--clipboard-github-repo-url'
;;       Returns the kill ring head when it looks like a GitHub
;;       repo URL (`https://github.com/OWNER/REPO[...]') and
;;       does NOT contain a `/pull/N' segment -- those belong
;;       to `decknix--clipboard-github-pr-url'.  Used by the
;;       `decknix-agent-link-repo' default-URL prompt.

;;; Code:

(defun decknix--agent-clipboard-url ()
  "Return a GitHub PR URL from the kill ring or system clipboard, or nil."
  (let ((text (or (ignore-errors (current-kill 0 t))
                  (ignore-errors
                    (string-trim
                     (shell-command-to-string "pbpaste"))))))
    (when (and text (string-match-p "github\\.com/.*/pull/" text))
      (string-trim text))))

(defun decknix--clipboard-github-pr-url ()
  "Return clipboard content if it looks like a GitHub PR URL, else nil."
  (let ((clip (ignore-errors
                (current-kill 0 t))))
    (when (and clip (string-match-p
                     "https://github\\.com/[^/]+/[^/]+/pull/[0-9]+"
                     clip))
      (string-trim clip))))

(defun decknix--clipboard-github-repo-url ()
  "Return clipboard content if it looks like a GitHub repo URL.
Rejects pull-request URLs -- those belong to `decknix--clipboard-github-pr-url'."
  (let ((clip (ignore-errors (current-kill 0 t))))
    (when (and clip
               (stringp clip)
               (string-match-p "https://github\\.com/[^/]+/[^/?#]+"
                               clip)
               (not (string-match-p "/pull/[0-9]+" clip)))
      (string-trim clip))))

(provide 'decknix-agent-clipboard)
;;; decknix-agent-clipboard.el ends here
