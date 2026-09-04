;;; decknix-hub-review-status.el --- Is a review session still worth running? -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, pr, review

;;; Commentary:
;;
;; A review session outlives its usefulness quietly.  The PR gets merged,
;; or somebody else reviews it, or the author pushes again -- and the
;; agent carries on analysing a diff nobody is waiting on.  Nothing in
;; the sidebar said so, so the only way to find out was to open the
;; session and read it.
;;
;; Three states, all derivable from data the hub adapter already writes
;; into `github-reviews.json' and none of them needing a fetch:
;;
;;   `gone'      the PR is no longer in your review queue.  This is an
;;               ABSENCE, not a field: GitHub drops a PR from the feed
;;               once your review stops being requested, which covers
;;               merged, closed and de-requested alike.  In every one of
;;               those the answer is the same -- the session is finished
;;               work.  (Distinguishing WHY needs a `gh pr view'; that is
;;               deliberately not done here, so this stays free.)
;;
;;   `stale'     `review_stale' -- the author has pushed since.  Whatever
;;               the session concluded was about a different diff.
;;
;;   `answered'  `others_reviewed', or a settled `review_decision'.
;;               Someone else got there first.
;;
;; Measured against one live feed while writing this: #20611 and #20728
;; merged with their review sessions still open and running, #20737
;; stale, #20733 answered-and-approved.  All three states, concurrently,
;; none of them visible.
;;
;; `gone' can only ever be shown against a SESSION, never against a
;; request row -- a PR that left the feed has no request row to badge.
;; That asymmetry is the whole reason the session surface matters.

;;; Code:

(require 'map)

(defconst decknix--hub-review-settled-decisions '("APPROVED" "CHANGES_REQUESTED")
  "GitHub `review_decision' values meaning somebody has actually decided.
`REVIEW_REQUIRED' and the empty string are the not-yet states.")

(defun decknix--hub-review-status (item found)
  "Classify a review session's usefulness.  Pure.

ITEM is its entry from the reviews feed (an alist) and FOUND whether the
PR was in the feed at all.  Returns `gone', `stale', `answered', or nil
when the session is still straightforwardly wanted.

Precedence is `gone' > `stale' > `answered', and the middle one is a
judgement call worth stating.  A session can be both stale and answered:
the author pushed AND someone else reviewed.  `stale' wins because it
says something concrete about the WORK -- the diff under review changed,
so the analysis is void -- whereas `answered' is a softer social signal
that someone may have covered it.  Telling you the work is invalid is
more actionable than telling you it might be redundant."
  (cond
   ((not found) 'gone)
   ((null item) 'gone)
   ((eq (map-elt item 'review_stale) t) 'stale)
   ((eq (map-elt item 'others_reviewed) t) 'answered)
   ((member (map-elt item 'review_decision)
            decknix--hub-review-settled-decisions)
    'answered)
   (t nil)))

(defun decknix--hub-review-status-glyph (status)
  "Return (GLYPH . FACE-SPEC) for STATUS, or nil when there is nothing to say.

Deliberately three distinguishable shapes rather than three colours: the
sidebar already carries a lot of colour, and these have to read at a
glance beside the existing state glyphs."
  (pcase status
    ('gone     (cons "⊘" '(:foreground "#6b727e")))
    ('stale    (cons "↻" '(:foreground "#e5c07b" :weight bold)))
    ('answered (cons "☑" '(:foreground "#61afef")))
    (_ nil)))

(defun decknix--hub-review-status-help (status)
  "Return help-echo text for STATUS, or nil."
  (pcase status
    ('gone     "PR left your review queue (merged, closed or de-requested) — session is finished work")
    ('stale    "Author has pushed since — this session's analysis is out of date")
    ('answered "Another reviewer has responded — your review may be redundant")
    (_ nil)))

(defun decknix--hub-review-status-badge (status)
  "Return a propertized badge string for STATUS, or \"\" when none."
  (if-let* ((g (decknix--hub-review-status-glyph status)))
      (propertize (car g)
                  'face (cdr g)
                  'help-echo (decknix--hub-review-status-help status))
    ""))

(defun decknix--hub-review-find-item (items repo number)
  "Return the feed entry in ITEMS for REPO and NUMBER, or nil.

REPO matches on the final path segment, so a feed carrying
`UpsideRealty/upside' answers a caller holding either form."
  (let ((short (and (stringp repo) (car (last (split-string repo "/")))))
        (num (cond ((numberp number) number)
                   ((and (stringp number) (not (string-empty-p number)))
                    (string-to-number number)))))
    (when (and short (not (string-empty-p short)) num)
      (seq-find
       (lambda (it)
         (let ((r (map-elt it 'repo)))
           (and (equal num (map-elt it 'number))
                (stringp r)
                (equal short (car (last (split-string r "/")))))))
       items))))

(provide 'decknix-hub-review-status)
;;; decknix-hub-review-status.el ends here
