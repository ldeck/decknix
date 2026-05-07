;;; decknix-hub-ready-filter.el --- Hub Requests "ready for review" predicate -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-ci "0.1"))
;; Keywords: agent, hub, filter, review

;;; Commentary:
;;
;; The Requests sidebar section and the `r' picker both surface a
;; "ready for review" view of the hub's review-request feed.  An item
;; is ready when:
;;
;;   * CI has finished and is either passing (`pass') or only carries
;;     soft / lint failures (`soft_fail') that don't gate a merge;
;;   * GitHub does not report the branch as `CONFLICTING';
;;   * the PR is not in draft state; and
;;   * I have not already reviewed it (no APPROVED or CHANGES_REQUESTED
;;     review of mine on file).
;;
;; The classification of CI status into `pass' / `soft_fail' / etc.
;; lives in `decknix-hub-ci' and is called via
;; `decknix--hub-ci-classify'; this module is a thin pure predicate on
;; top of that classifier plus three alist lookups.  Carving it out of
;; `decknix-agent-shell-workspace' (workspace-bulk) lets the predicate
;; be characterised in isolation and reused by future hub adapters
;; without pulling in the whole sidebar surface.
;;
;; Public surface:
;;
;;   `decknix--hub-request-ready-p'  -- predicate over a review-request
;;                                       alist; returns non-nil when
;;                                       the item is ready for review.
;;
;; The two call sites in workspace-bulk (sidebar Requests filter and
;; the `r' picker's ready-only toggle) reach this symbol through the
;; heredoc's `(require 'decknix-hub-ready-filter)' line, declared at
;; the same point as the other hub/ helper packages.

;;; Code:

(require 'decknix-hub-ci)

(defun decknix--hub-request-ready-p (item)
  "Return non-nil if review request ITEM is ready for review.
Ready means: CI passing (or soft-fail), not conflicting, not draft,
and not already reviewed by me (APPROVED or CHANGES_REQUESTED)."
  (let ((ci-status (decknix--hub-ci-classify (alist-get 'ci item)))
        (mergeable (alist-get 'mergeable item))
        (draft (alist-get 'draft item))
        (my-review (alist-get 'my_review item)))
    (and (member ci-status '("pass" "soft_fail"))
         (not (equal mergeable "CONFLICTING"))
         (not (eq draft t))
         (not (member my-review '("APPROVED" "CHANGES_REQUESTED"))))))

(provide 'decknix-hub-ready-filter)
;;; decknix-hub-ready-filter.el ends here
