;;; decknix-hub-ready-filter.el --- Hub Requests "ready for review" reader -*- lexical-binding: t -*-

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
;;   `decknix--hub-request-ready-p'        -- predicate over a single
;;                                             review-request alist;
;;                                             non-nil when the item
;;                                             is ready for review.
;;   `decknix--hub-review-ready-requests'  -- reader returning the
;;                                             subset of
;;                                             `decknix--hub-reviews'
;;                                             that passes the org /
;;                                             age / CI / bot /
;;                                             attention / ready
;;                                             visibility filters.
;;   `decknix--hub-review-entries'         -- builds (LABEL . ITEM)
;;                                             entries for the `r'
;;                                             picker over the ready
;;                                             subset; honours the
;;                                             persisted sort flag and
;;                                             the optional
;;                                             MENTION-ONLY filter.
;;
;; The visibility predicates and the sort routine live in their own
;; carved packages (`decknix-hub-attention-filter', `-ci-filter',
;; `-mention-bot', `-age-presets', plus `-org-filter' via
;; `decknix--hub-item-visible-p' in hub-bulk).  The two icon helpers
;; (`format-age', `ci-icon', `review-icon') live in
;; `decknix-hub-icons' / `decknix-hub-ci'.  The two live-session
;; helpers (`request-has-live-session-p', `request-tint-active') are
;; still in hub-bulk and reached via `declare-function' below.
;;
;; The call sites in workspace-bulk (sidebar Requests filter and the
;; `r' picker's ready-only toggle) reach all three symbols through
;; the heredoc's `(require 'decknix-hub-ready-filter)' line, declared
;; at the same point as the other hub/ helper packages.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'decknix-hub-ci)

;; -- defvar: hub data source (owned by hub-bulk) ------------------

(defvar decknix--hub-reviews)

;; -- declare-function: visibility predicates (carved out) ---------

(declare-function decknix--hub-item-visible-p
                  "decknix-agent-shell-hub" (repo-full))
(declare-function decknix--hub-age-visible-p
                  "decknix-hub-age-presets" (iso-time))
(declare-function decknix--hub-ci-visible-p
                  "decknix-hub-ci-filter" (item))
(declare-function decknix--hub-bot-visible-p
                  "decknix-hub-mention-bot" (item))
(declare-function decknix--hub-requests-attention-visible-p
                  "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-sort-requests
                  "decknix-hub-attention-filter" (items))

;; -- declare-function: icon + tint helpers ------------------------

(declare-function decknix--hub-format-age
                  "decknix-hub-icons" (iso-time))
(declare-function decknix--hub-ci-icon
                  "decknix-hub-ci" (ci &optional mergeable))
(declare-function decknix--hub-review-icon
                  "decknix-hub-icons" (item))
(declare-function decknix--hub-request-has-live-session-p
                  "decknix-agent-shell-hub" (item))
(declare-function decknix--hub-request-tint-active
                  "decknix-agent-shell-hub" (str item))

;; -- predicate ----------------------------------------------------

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

;; -- reader: ready subset of decknix--hub-reviews -----------------

(defun decknix--hub-review-ready-requests ()
  "Return the list of review requests that are ready for review.
Applies org, age, and CI visibility filters, then the ready predicate."
  (let* ((data decknix--hub-reviews)
         (all-items (when data (alist-get 'items data))))
    (seq-filter
     (lambda (item)
       (and (decknix--hub-item-visible-p (alist-get 'repo item))
            (decknix--hub-age-visible-p (alist-get 'created item))
            (decknix--hub-ci-visible-p item)
            (decknix--hub-bot-visible-p item)
            (decknix--hub-requests-attention-visible-p item)
            (decknix--hub-request-ready-p item)))
     (or all-items '()))))

;; -- entry builder: (LABEL . ITEM) cons cells for picker ----------

(defun decknix--hub-review-entries (&optional mention-only)
  "Build labelled (LABEL . ITEM) entries from ready review requests.
Ordering follows `decknix--hub-requests-sort-reverse' via
`decknix--hub-sort-requests' so the picker matches the sidebar
Requests section exactly.  When MENTION-ONLY is non-nil, include
only @-mentioned items."
  (let* ((ready (decknix--hub-review-ready-requests))
         (filtered (if mention-only
                       (seq-filter
                        (lambda (item)
                          (eq (alist-get 'mentioned item) t))
                        ready)
                     ready))
         (sorted (decknix--hub-sort-requests filtered)))
    (mapcar
     (lambda (item)
       (let* ((age (decknix--hub-format-age
                    (alist-get 'created item)))
              (repo-full (or (alist-get 'repo item) ""))
              (repo (car (last (split-string repo-full "/"))))
              (number (alist-get 'number item))
              (title (or (alist-get 'title item) ""))
              (ci-str (decknix--hub-ci-icon
                       (alist-get 'ci item)
                       (alist-get 'mergeable item)))
              (rev-str (decknix--hub-review-icon item))
              (status-str (if (string-empty-p rev-str)
                              ci-str
                            (concat ci-str rev-str)))
              ;; @-mention indicator
              (mention-str (if (eq (alist-get 'mentioned item) t)
                               (propertize "@"
                                 'face '(:foreground "#d7af5f" :weight bold))
                             ""))
              (status-str (if (string-empty-p mention-str)
                              status-str
                            (concat status-str mention-str)))
              ;; Active session indicator
              (active-str (if (decknix--hub-request-has-live-session-p item)
                              (propertize "◉"
                                'face '(:foreground "#87d7ff"))
                            ""))
              (status-str (if (string-empty-p active-str)
                              status-str
                            (concat status-str active-str)))
              ;; Age colouring matching sidebar
              (age-face (cond
                         ((string-match-p "d$" age)
                          (if (>= (string-to-number age) 3)
                              'error 'warning))
                         (t 'font-lock-comment-face)))
              (label (format " %3s %s#%d %s %s"
                             (propertize age 'face age-face)
                             (propertize (or repo "") 'face 'font-lock-type-face)
                             number
                             status-str
                             title)))
         ;; Tint the picker label yellow when a live session is
         ;; already reviewing this PR (mirrors the sidebar cue).
         (decknix--hub-request-tint-active label item)
         (cons label item)))
     sorted)))

(provide 'decknix-hub-ready-filter)
;;; decknix-hub-ready-filter.el ends here
