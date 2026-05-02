;;; decknix-hub-org-filter.el --- Hub org visibility filter helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, filter

;;; Commentary:
;;
;; Pure org-filter helpers extracted from the agent-shell heredoc:
;;
;;   * `decknix--hub-org-visibility' — hash-table of org-name -> bool;
;;     nil means "show all" (no filter active).
;;   * `decknix--hub-discover-orgs' — sorted unique GitHub owners
;;     across the parsed `decknix--hub-reviews' and `decknix--hub-wip'
;;     hub data.
;;   * `decknix--hub-org-visible-p' — predicate read at every render
;;     site to decide whether to keep an item.
;;   * `decknix--hub-org-filter-summary' — short label
;;     ("all" / "none" / "N/M") for the toggles transient and
;;     sidebar footer.
;;
;; The mutating commands (`decknix--hub-toggle-org', show-all /
;; show-none, the per-org toggle factory and the transient suffixes)
;; stay in the heredoc — they refresh the sidebar, which is a
;; heredoc-side concern.  The free defvars consumed here
;; (`decknix--hub-reviews', `decknix--hub-wip') are populated by the
;; heredoc's hub refresh code and are forward-declared below so the
;; byte-compiler stays clean while runtime load order — heredoc
;; defvars first, this module via `(require ...)' second — provides
;; the actual bindings.

;;; Code:

(require 'cl-lib)

;; -- Forward declarations: defined elsewhere in agent-shell config --
(defvar decknix--hub-reviews)
(defvar decknix--hub-wip)

(defvar decknix--hub-org-visibility nil
  "Hash-table tracking org visibility (org-name → boolean).
nil means show all orgs (no filter active).")

(defun decknix--hub-discover-orgs ()
  "Return a sorted list of unique GitHub owners across reviews and WIP."
  (let ((orgs (make-hash-table :test 'equal)))
    ;; Reviews
    (when decknix--hub-reviews
      (dolist (item (alist-get 'items decknix--hub-reviews))
        (let* ((repo (or (alist-get 'repo item) ""))
               (owner (car (split-string repo "/"))))
          (when (and owner (not (string-empty-p owner)))
            (puthash owner t orgs)))))
    ;; WIP
    (when decknix--hub-wip
      (dolist (repo-entry (alist-get 'repos decknix--hub-wip))
        (let* ((repo (or (alist-get 'repo repo-entry) ""))
               (owner (car (split-string repo "/"))))
          (when (and owner (not (string-empty-p owner)))
            (puthash owner t orgs)))))
    (sort (hash-table-keys orgs) #'string<)))

(defun decknix--hub-org-visible-p (org)
  "Return non-nil if ORG should be shown.
When no filter is active (table is nil), all orgs are visible."
  (or (null decknix--hub-org-visibility)
      (gethash org decknix--hub-org-visibility)))

(defun decknix--hub-org-filter-summary ()
  "Return a short string describing the current org filter state."
  (if (null decknix--hub-org-visibility)
      "all"
    (let* ((orgs (decknix--hub-discover-orgs))
           (total (length orgs))
           (visible (cl-count-if
                     (lambda (o) (gethash o decknix--hub-org-visibility))
                     orgs)))
      (cond
       ((= visible total) "all")
       ((= visible 0) "none")
       (t (format "%d/%d" visible total))))))

(provide 'decknix-hub-org-filter)
;;; decknix-hub-org-filter.el ends here
