;;; decknix-agent-url-parse.el --- Agent URL parsers + accessors -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, github, url, parsing

;;; Commentary:
;;
;; Pure URL-parsing primitives extracted from the agent-shell heredoc.
;; Three coherent helpers form a minimal toolkit consumed by the
;; conversation-link / hub-repo / WIP / quick-action machinery:
;;
;;   `decknix--agent-pr-parse-url'      (PR URL  -> (owner repo n)  | nil)
;;   `decknix--agent-repo-parse-url'    (repo URL -> (owner repo)    | nil)
;;   `decknix--agent-pr-url-accessor'   (alist | hash-table -> field)
;;
;; Plus one composition helper that depends on `repo-parse-url' and
;; lives here for proximity:
;;
;;   `decknix--hub-repo-cache-key'      (URL + branch -> cache key)
;;
;; All four are leaf primitives — they take strings/lists/hash-tables
;; and return strings/lists.  No I/O, no global state, no side
;; effects.

;;; Code:

(defun decknix--agent-pr-parse-url (url)
  "Parse a GitHub PR URL into (owner repo number) or nil."
  (when (and url (string-match
                  "github\\.com/\\([^/]+\\)/\\([^/]+\\)/pull/\\([0-9]+\\)"
                  url))
    (list (match-string 1 url)
          (match-string 2 url)
          (string-to-number (match-string 3 url)))))

(defun decknix--agent-repo-parse-url (url)
  "Parse github.com/OWNER/REPO from URL and return (OWNER REPO).
Rejects pull-request URLs (those route through `decknix--agent-pr-parse-url').
Strips any trailing slash, query, fragment, or .git suffix."
  (when (and url
             (stringp url)
             (not (string-match-p "/pull/[0-9]+" url))
             (string-match
              "github\\.com/\\([^/]+\\)/\\([^/?#]+\\)"
              url))
    (let ((owner (match-string 1 url))
          (repo (match-string 2 url)))
      (when (string-suffix-p ".git" repo)
        (setq repo (substring repo 0 -4)))
      (list owner repo))))

(defun decknix--agent-pr-url-accessor (pr field)
  "Get FIELD from PR link (supports both hash-table and alist)."
  (if (hash-table-p pr) (gethash field pr) (alist-get (intern field) pr)))

(defun decknix--hub-repo-cache-key (url branch)
  "Return the canonical cache key for URL + BRANCH, or nil."
  (let ((parsed (decknix--agent-repo-parse-url url)))
    (when (and parsed branch)
      (format "%s/%s#%s" (nth 0 parsed) (nth 1 parsed) branch))))

(provide 'decknix-agent-url-parse)
;;; decknix-agent-url-parse.el ends here
