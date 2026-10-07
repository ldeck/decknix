;;; decknix-hub-lifecycle-test.el --- PR lifecycle glyphs -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The glyph answers WHERE IN ITS LIFE a PR is; the colour answers WHOSE
;; MOVE.  Both came from one real case: followupboss-integration#252 was
;; approved by a colleague, had one unresolved human conversation blocking
;; a rebase-merge, and rendered as a grey half-circle -- the "nothing is
;; known" fallback -- with no indication of either fact.
;;
;; Measured on the same repo at the same moment: eleven of twelve PRs
;; rendered green, and NONE of them were approved.  Green meant
;; `REVIEW_REQUIRED', which is nobody-has-looked-yet.

;;; Code:

(require 'ert)
(require 'decknix-hub-icons)

(defun dk-lc--face (icon) (get-text-property 0 'face icon))
(defun dk-lc--glyph (icon) (substring-no-properties icon 0 1))

;; --- approval is not only `review_decision' ---------------------------

(ert-deftest dk-lc--approvers-counts-as-approved ()
  "GitHub leaves `review_decision' EMPTY while any requested reviewer is
outstanding, so #252 reported no decision despite being approved."
  (should (decknix--hub-pr-approved-p
           '((approvers . ("jonathan-lo")) (review_decision . "")))))

(ert-deftest dk-lc--an-empty-approvers-list-is-not-approved ()
  (should-not (decknix--hub-pr-approved-p
               '((approvers . ()) (review_decision . "REVIEW_REQUIRED")))))

(ert-deftest dk-lc--review-decision-still-counts ()
  (should (decknix--hub-pr-approved-p '((review_decision . "APPROVED")))))

(ert-deftest dk-lc--my-own-review-counts ()
  (should (decknix--hub-pr-approved-p '((my_review . "APPROVED")))))

;; --- unresolved conversations -----------------------------------------

(ert-deftest dk-lc--human-threads-are-what-block-a-merge ()
  "A bot thread is not the one standing in the way."
  (should (= 1 (decknix--hub-pr-unresolved
                '((human_unresolved . 1) (bot_unresolved . 5))))))

(ert-deftest dk-lc--falls-back-to-the-total-when-unsplit ()
  (should (= 3 (decknix--hub-pr-unresolved '((unresolved_threads . 3))))))

(ert-deftest dk-lc--no-thread-data-is-zero-not-an-error ()
  (should (= 0 (decknix--hub-pr-unresolved '((number . 1))))))

(ert-deftest dk-lc--approved-with-a-thread-is-blocked-by-it ()
  (should (decknix--hub-pr-blocked-by-threads-p
           '((approvers . ("x")) (human_unresolved . 1)))))

(ert-deftest dk-lc--approved-and-clean-is-not-blocked ()
  (should-not (decknix--hub-pr-blocked-by-threads-p
               '((approvers . ("x")) (human_unresolved . 0)))))

(ert-deftest dk-lc--unapproved-with-threads-is-not-the-blocked-state ()
  "It is waiting on a review, not on the conversation."
  (should-not (decknix--hub-pr-blocked-by-threads-p
               '((human_unresolved . 2)))))

;; --- the glyph says where in its life ---------------------------------

(ert-deftest dk-lc--the-252-case-is-its-own-state ()
  "Approved, CI green, one conversation blocking the merge.  It had no
representation at all and fell through to the unknown fallback."
  (let ((icon (decknix--hub-primary-status-icon
               '((approvers . ("jonathan-lo")) (review_decision . "")
                 (human_unresolved . 1) (ci . ((status . "pass"))))
               'wip)))
    (should (equal "◑" (dk-lc--glyph icon)))
    (should (eq 'warning (dk-lc--face icon)))))

(ert-deftest dk-lc--approved-and-clean-is-green-and-full ()
  (let ((icon (decknix--hub-primary-status-icon
               '((approvers . ("x")) (human_unresolved . 0)
                 (ci . ((status . "pass"))))
               'wip)))
    (should (equal "●" (dk-lc--glyph icon)))
    (should (eq 'success (dk-lc--face icon)))))

(ert-deftest dk-lc--my-unreviewed-pr-is-not-green ()
  "Eleven of twelve rendered green while none were approved, so green
stopped meaning ready."
  (let ((icon (decknix--hub-primary-status-icon
               '((review_decision . "REVIEW_REQUIRED") (ci . ((status . "pass"))))
               'wip)))
    (should-not (eq 'success (dk-lc--face icon)))))

(ert-deftest dk-lc--whose-move-flips-with-the-side-of-the-review ()
  "An unreviewed PR of MINE waits on a reviewer; one sent TO me waits on
me.  Same facts, opposite urgency."
  (let ((item '((review_decision . "REVIEW_REQUIRED") (ci . ((status . "pass"))))))
    (should (eq 'shadow (dk-lc--face (decknix--hub-primary-status-icon item 'wip))))
    (should (eq 'warning (dk-lc--face (decknix--hub-primary-status-icon item 'review))))))

(ert-deftest dk-lc--changes-requested-is-an-error ()
  (let ((icon (decknix--hub-primary-status-icon
               '((review_decision . "CHANGES_REQUESTED")) 'wip)))
    (should (equal "⊖" (dk-lc--glyph icon)))
    (should (eq 'error (dk-lc--face icon)))))

(ert-deftest dk-lc--failing-ci-outranks-approval ()
  "An approved PR that does not build is not ready for anything."
  (let ((icon (decknix--hub-primary-status-icon
               '((approvers . ("x")) (ci . ((status . "fail")))) 'wip)))
    (should (eq 'error (dk-lc--face icon)))))

(ert-deftest dk-lc--a-draft-is-still-a-draft ()
  (should (equal "★" (dk-lc--glyph
                      (decknix--hub-primary-status-icon
                       '((draft . t) (approvers . ("x"))) 'wip)))))

(ert-deftest dk-lc--a-conflict-still-outranks-everything ()
  (should (equal "▣" (dk-lc--glyph
                      (decknix--hub-primary-status-icon
                       '((mergeable . "CONFLICTING") (approvers . ("x"))) 'wip)))))

;; --- the blocker is shown, not just implied ---------------------------

(ert-deftest dk-lc--unresolved-count-is-rendered ()
  "The thing GitHub blocks the merge on was invisible."
  (should (string-match-p "◆1" (decknix--hub-unresolved-icon
                                '((human_unresolved . 1))))))

(ert-deftest dk-lc--no-unresolved-renders-nothing ()
  (should (equal "" (decknix--hub-unresolved-icon '((human_unresolved . 0))))))

(ert-deftest dk-lc--the-count-is-capped-to-one-column ()
  "It sits in a 48-column sidebar beside several other glyphs."
  (should (= 2 (string-width (decknix--hub-unresolved-icon
                              '((human_unresolved . 47)))))))


;; --- a draft asks nothing of anybody ----------------------------------

(ert-deftest dk-lc--a-healthy-draft-is-grey-not-green ()
  "Green means nothing-is-needed-and-this-is-ready.  Seven drafts
rendering green beside an approved PR is what made it meaningless."
  (let ((icon (decknix--hub-primary-status-icon
               '((draft . t) (ci . ((status . "pass")))) 'wip)))
    (should (equal "★" (dk-lc--glyph icon)))
    (should (eq 'shadow (dk-lc--face icon)))))

(ert-deftest dk-lc--a-broken-draft-still-says-so ()
  "Not-ready does not excuse not-building."
  (should (eq 'error (dk-lc--face (decknix--hub-primary-status-icon
                                   '((draft . t) (ci . ((status . "fail"))))
                                   'wip)))))

(provide 'decknix-hub-lifecycle-test)
;;; decknix-hub-lifecycle-test.el ends here
