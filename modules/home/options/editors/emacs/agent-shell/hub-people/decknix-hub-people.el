;;; decknix-hub-people.el --- People (authors/reviewers) for a hub PR row -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, hub, review

;;; Commentary:
;;
;; Pure helpers behind the sidebar "People" row action (`p' in the
;; Requests / WIP / linked-PR menus): given a PR at point (repo + number),
;; find its raw hub item and format who is involved — authors (a PR can
;; have several), requested reviewers, approvers, and blockers.
;;
;; The hub (`decknix-hub') emits per PR: `authors' (human logins, PR author
;; first, then distinct commit authors), `requested_reviewers' (pending;
;; users as login, teams as "team:<name>"), `approvers' (latest review
;; APPROVED), and `blockers' (latest review CHANGES_REQUESTED).  Older data
;; may lack these; the formatter falls back to the singular `author'.
;;
;; This file is side-effect free (lookup + formatting only); the transient
;; suffix and the display buffer live in workspace-bulk / the heredoc per
;; AGENTS.md Rule 2.

;;; Code:

(require 'seq)
(require 'subr-x)

(defun decknix--hub-people-find-item (repo number review-items wip-repos)
  "Return the raw hub PR item for REPO (full \"owner/repo\") and NUMBER.
Searches REVIEW-ITEMS (the Reviews `items' list) first, then WIP-REPOS
\(the WIP `repos' list, each an alist with `repo' + `prs').  Returns the
item alist, or nil when not found."
  (or (seq-find (lambda (it)
                  (and (equal (alist-get 'repo it) repo)
                       (equal (alist-get 'number it) number)))
                review-items)
      (let (found)
        (dolist (rg wip-repos)
          (when (and (not found) (equal (alist-get 'repo rg) repo))
            (setq found
                  (seq-find (lambda (pr)
                              (equal (alist-get 'number pr) number))
                            (alist-get 'prs rg)))))
        found)))

(defun decknix--hub-people--as-list (v)
  "Normalise V (a JSON array as vector/list, a lone string, or nil) to a list."
  (cond ((null v) nil)
        ((stringp v) (list v))
        ((vectorp v) (append v nil))
        ((listp v) v)
        (t nil)))

(defun decknix--hub-people--render (people)
  "Render PEOPLE (a list of logins / \"team:<name>\") as a display string.
Logins get an `@' prefix; team entries render as `@<name> (team)'.
Returns \"—\" for an empty list."
  (if (null people) "—"
    (mapconcat
     (lambda (p)
       (if (string-prefix-p "team:" p)
           (format "@%s (team)" (substring p 5))
         (concat "@" p)))
     people "  ")))

(defun decknix--hub-people-lines (item)
  "Return a list of display lines for hub ITEM's people, or nil when ITEM is nil.
Uses `authors' (falling back to the singular `author'),
`requested_reviewers', `approvers', and `blockers'."
  (when item
    (let* ((repo (alist-get 'repo item))
           (number (alist-get 'number item))
           (title (or (alist-get 'title item) ""))
           (authors (or (decknix--hub-people--as-list (alist-get 'authors item))
                        (decknix--hub-people--as-list (alist-get 'author item))))
           (requested (decknix--hub-people--as-list
                       (alist-get 'requested_reviewers item)))
           (approvers (decknix--hub-people--as-list (alist-get 'approvers item)))
           (blockers  (decknix--hub-people--as-list (alist-get 'blockers item))))
      (list
       (format "%s#%s  %s" (or repo "?") (or number "?") title)
       (format "  authors:    %s" (decknix--hub-people--render authors))
       (format "  requested:  %s" (decknix--hub-people--render requested))
       (format "  approved:   %s" (decknix--hub-people--render approvers))
       (format "  blocking:   %s" (decknix--hub-people--render blockers))))))

(provide 'decknix-hub-people)
;;; decknix-hub-people.el ends here
