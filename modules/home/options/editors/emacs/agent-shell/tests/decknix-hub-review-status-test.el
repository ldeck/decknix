;;; decknix-hub-review-status-test.el --- Tests for review session staleness -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification tests for `decknix--hub-review-status'.  The fixtures are
;; taken from a real `github-reviews.json', including the four PRs that
;; were live when this was written -- two merged with their sessions
;; still running, one stale, one answered.

;;; Code:

(require 'ert)
(require 'decknix-hub-review-status)

(defun decknix-review-status-test--item (&rest kv)
  "Build a feed item from KV, defaulting the fields the classifier reads."
  (let ((base '((review_stale . :json-false)
                (others_reviewed . :json-false)
                (review_decision . "REVIEW_REQUIRED"))))
    (append (map-pairs (map-into kv 'alist)) base)))

;; --- gone: an ABSENCE, which is the whole point ---

(ert-deftest decknix-review-status--absent-is-gone ()
  "A PR no longer in the feed means the session is finished work.
GitHub drops a PR once your review stops being requested, so this one
condition covers merged, closed and de-requested alike."
  (should (eq 'gone (decknix--hub-review-status nil nil))))

(ert-deftest decknix-review-status--found-but-nil-item-is-gone ()
  "Defensive: FOUND with no item cannot be classified as still-wanted."
  (should (eq 'gone (decknix--hub-review-status nil t))))

;; --- stale: the author pushed since ---

(ert-deftest decknix-review-status--review-stale-flag ()
  "`review_stale' means the diff changed under the session."
  (should (eq 'stale
              (decknix--hub-review-status
               '((review_stale . t) (others_reviewed . nil)
                 (review_decision . "REVIEW_REQUIRED"))
               t))))

;; --- answered: somebody else got there ---

(ert-deftest decknix-review-status--others-reviewed-flag ()
  "`others_reviewed' means another human has responded."
  (should (eq 'answered
              (decknix--hub-review-status
               '((review_stale . nil) (others_reviewed . t)
                 (review_decision . "REVIEW_REQUIRED"))
               t))))

(ert-deftest decknix-review-status--settled-decision-counts ()
  "A settled `review_decision' counts even without `others_reviewed'."
  (dolist (d '("APPROVED" "CHANGES_REQUESTED"))
    (should (eq 'answered
                (decknix--hub-review-status
                 `((review_stale . nil) (others_reviewed . nil)
                   (review_decision . ,d))
                 t)))))

(ert-deftest decknix-review-status--unsettled-decisions-are-not-answers ()
  "`REVIEW_REQUIRED' and the empty string are the not-yet states.
17 of 23 items in the sampled feed were REVIEW_REQUIRED and 5 were empty;
treating either as answered would badge nearly the whole queue."
  (dolist (d '("REVIEW_REQUIRED" ""))
    (should-not (decknix--hub-review-status
                 `((review_stale . nil) (others_reviewed . nil)
                   (review_decision . ,d))
                 t))))

;; --- precedence ---

(ert-deftest decknix-review-status--stale-outranks-answered ()
  "Both at once -> `stale'.
It says something concrete about the WORK (the diff changed, so the
analysis is void) rather than that it might be redundant."
  (should (eq 'stale
              (decknix--hub-review-status
               '((review_stale . t) (others_reviewed . t)
                 (review_decision . "APPROVED"))
               t))))

(ert-deftest decknix-review-status--gone-outranks-everything ()
  "Absence wins: there is nothing left to review."
  (should (eq 'gone
              (decknix--hub-review-status
               '((review_stale . t) (others_reviewed . t)) nil))))

;; --- a healthy session gets no badge ---

(ert-deftest decknix-review-status--nothing-to-say ()
  "A PR still awaiting your review is not badged."
  (should-not (decknix--hub-review-status
               '((review_stale . nil) (others_reviewed . nil)
                 (review_decision . "REVIEW_REQUIRED"))
               t)))

;; --- json-false must not read as true ---

(ert-deftest decknix-review-status--json-false-is-not-truthy ()
  "Guards the classic JSON-parsing trap.
`json-parse-string' is called with `:false-object nil' here, but a caller
that ever passed `:json-false' would make every symbol truthy and badge
the entire queue `stale'.  Requiring `eq t' keeps that impossible."
  (should-not (decknix--hub-review-status
               '((review_stale . :json-false)
                 (others_reviewed . :json-false)
                 (review_decision . "REVIEW_REQUIRED"))
               t)))

;; --- badges ---

(ert-deftest decknix-review-status--badges-are-distinct ()
  "Three distinguishable shapes, not three colours of the same mark."
  (let ((g (mapcar (lambda (s) (car (decknix--hub-review-status-glyph s)))
                   '(gone stale answered))))
    (should (= 3 (length (delete-dups (copy-sequence g)))))))

(ert-deftest decknix-review-status--no-badge-when-healthy ()
  "A nil status renders nothing at all, not a placeholder."
  (should (equal "" (decknix--hub-review-status-badge nil))))

(ert-deftest decknix-review-status--badges-carry-help ()
  "Each badge explains itself on hover; the glyphs are not self-evident."
  (dolist (s '(gone stale answered))
    (should (stringp (decknix--hub-review-status-help s)))
    (should (get-text-property 0 'help-echo
                               (decknix--hub-review-status-badge s)))))

;; --- feed lookup ---

(ert-deftest decknix-review-status--find-matches-short-or-full-repo ()
  "The feed carries `owner/repo'; callers may hold either form."
  (let ((items '(((repo . "UpsideRealty/upside") (number . 20737))
                 ((repo . "UpsideRealty/reconz-integration") (number . 291)))))
    (should (decknix--hub-review-find-item items "upside" 20737))
    (should (decknix--hub-review-find-item items "UpsideRealty/upside" 20737))
    (should (decknix--hub-review-find-item items "reconz-integration" "291"))
    (should-not (decknix--hub-review-find-item items "upside" 20611))
    (should-not (decknix--hub-review-find-item items "other-repo" 20737))))

(ert-deftest decknix-review-status--find-does-not-cross-repos ()
  "Same number in two repos must not match the wrong one."
  (let ((items '(((repo . "org/a") (number . 5))
                 ((repo . "org/b") (number . 5)))))
    (should (equal "org/a" (map-elt (decknix--hub-review-find-item items "a" 5) 'repo)))
    (should (equal "org/b" (map-elt (decknix--hub-review-find-item items "b" 5) 'repo)))))


;; --- aggregating a grouped session's PRs into one badge ---

(ert-deftest decknix-review-status--aggregate-gone-needs-unanimity ()
  "One live PR keeps the group alive.
Four merged bumps and one still open is not finished work; badging it
`gone' would invite quitting a session that still has a PR under it."
  (should (eq 'gone (decknix--hub-review-status-aggregate '(gone gone gone))))
  (should-not (eq 'gone (decknix--hub-review-status-aggregate '(gone gone nil)))))

(ert-deftest decknix-review-status--aggregate-stale-wins ()
  "A push to any member invalidates the group's analysis."
  (should (eq 'stale (decknix--hub-review-status-aggregate '(gone answered stale))))
  (should (eq 'stale (decknix--hub-review-status-aggregate '(nil stale)))))

(ert-deftest decknix-review-status--aggregate-answered-needs-all ()
  "`answered' only when every live member is answered.
One member still plainly wanted means there is work here, and saying
`someone else has this' would be false."
  (should (eq 'answered (decknix--hub-review-status-aggregate '(answered answered gone))))
  (should-not (decknix--hub-review-status-aggregate '(answered nil))))

(ert-deftest decknix-review-status--aggregate-plain-group-is-unbadged ()
  "A group with ordinary work pending says nothing."
  (should-not (decknix--hub-review-status-aggregate '(nil nil)))
  (should-not (decknix--hub-review-status-aggregate nil)))

(ert-deftest decknix-review-status--aggregate-matches-single-pr-case ()
  "A one-member group behaves exactly as an ungrouped session."
  (dolist (s '(gone stale answered nil))
    (should (eq s (decknix--hub-review-status-aggregate (list s))))))

(provide 'decknix-hub-review-status-test)
;;; decknix-hub-review-status-test.el ends here
