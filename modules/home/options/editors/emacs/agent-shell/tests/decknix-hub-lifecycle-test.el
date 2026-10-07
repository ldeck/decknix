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

;; --- shape = review progress, colour = build health ------------------

(ert-deftest dk-lc--a-happy-build-awaiting-review-is-a-green-half-circle ()
  "The expectation the previous scheme broke: colour meant WHOSE MOVE, so
a passing build on an unreviewed PR of mine rendered grey."
  (let ((icon (decknix--hub-primary-status-icon
               '((review_decision . "REVIEW_REQUIRED") (ci . ((status . "pass"))))
               'wip)))
    (should (equal "◐" (dk-lc--glyph icon)))
    (should (eq 'success (dk-lc--face icon)))))

(ert-deftest dk-lc--a-building-pr-is-a-yellow-half-circle ()
  (let ((icon (decknix--hub-primary-status-icon
               '((review_decision . "REVIEW_REQUIRED") (ci . ((status . "running"))))
               'wip)))
    (should (equal "◐" (dk-lc--glyph icon)))
    (should (eq 'warning (dk-lc--face icon)))))

(ert-deftest dk-lc--approved-and-happy-is-a-green-full-circle ()
  (let ((icon (decknix--hub-primary-status-icon
               '((approvers . ("x")) (ci . ((status . "pass")))) 'wip)))
    (should (equal "●" (dk-lc--glyph icon)))
    (should (eq 'success (dk-lc--face icon)))))

(ert-deftest dk-lc--approved-and-still-building-is-unambiguous ()
  "The case that has no answer when one channel carries both facts: the
SHAPE says approved, the COLOUR says building."
  (let ((icon (decknix--hub-primary-status-icon
               '((approvers . ("x")) (ci . ((status . "running")))) 'wip)))
    (should (equal "●" (dk-lc--glyph icon)))
    (should (eq 'warning (dk-lc--face icon)))))

(ert-deftest dk-lc--approved-with-a-failing-build-is-red-and-still-approved ()
  "Both facts survive: it IS approved, and it does NOT build."
  (let ((icon (decknix--hub-primary-status-icon
               '((approvers . ("x")) (ci . ((status . "fail")))) 'wip)))
    (should (equal "●" (dk-lc--glyph icon)))
    (should (eq 'error (dk-lc--face icon)))))

(ert-deftest dk-lc--changes-requested-has-its-own-shape ()
  "A review outcome, so it belongs to the shape channel, not the colour."
  (let ((icon (decknix--hub-primary-status-icon
               '((review_decision . "CHANGES_REQUESTED") (ci . ((status . "pass"))))
               'wip)))
    (should (equal "⊖" (dk-lc--glyph icon)))
    (should (eq 'success (dk-lc--face icon)))))

(ert-deftest dk-lc--no-ci-at-all-is-grey ()
  "Rare -- 2 PRs of 42 measured -- and genuinely unknown rather than fine."
  (should (eq 'shadow (dk-lc--face (decknix--hub-primary-status-icon
                                    '((review_decision . "REVIEW_REQUIRED"))
                                    'wip)))))

(ert-deftest dk-lc--colour-no-longer-depends-on-whose-pr-it-is ()
  "Which court it is in is carried by the SECTION -- Reviews holds what
was sent to me, WIP what is mine -- so the glyph repeating it bought
nothing and cost the build status."
  (let ((item '((review_decision . "REVIEW_REQUIRED") (ci . ((status . "pass"))))))
    (should (eq (dk-lc--face (decknix--hub-primary-status-icon item 'wip))
                (dk-lc--face (decknix--hub-primary-status-icon item 'review))))))

(ert-deftest dk-lc--a-conflict-still-outranks-everything ()
  (should (equal "▣" (dk-lc--glyph
                      (decknix--hub-primary-status-icon
                       '((mergeable . "CONFLICTING") (approvers . ("x"))) 'wip)))))

(ert-deftest dk-lc--a-draft-is-still-a-draft ()
  (should (equal "★" (dk-lc--glyph
                      (decknix--hub-primary-status-icon
                       '((draft . t) (approvers . ("x"))) 'wip)))))

;; --- a draft asks nothing of anybody ----------------------------------

(ert-deftest dk-lc--a-draft-is-coloured-by-its-build-like-everything-else ()
  "Not-ready is the SHAPE.  Once shape carries that, the colour is free to
mean what it means everywhere else, and a draft whose build is fine says
so instead of being dimmed for a reason the colour channel no longer
expresses."
  (let ((icon (decknix--hub-primary-status-icon
               '((draft . t) (ci . ((status . "pass")))) 'wip)))
    (should (equal "★" (dk-lc--glyph icon)))
    (should (eq 'success (dk-lc--face icon)))))

(ert-deftest dk-lc--a-broken-draft-still-says-so ()
  "Not-ready does not excuse not-building."
  (should (eq 'error (dk-lc--face (decknix--hub-primary-status-icon
                                   '((draft . t) (ci . ((status . "fail"))))
                                   'wip)))))


;; --- what distinguishes otherwise identical rows ----------------------

(ert-deftest dk-lc--settled-discussion-is-shown ()
  "Eleven followupboss PRs rendered identically: same glyph, same colour,
same everything.  One had no conversation at all and another had ten
resolved threads, and nothing said so."
  (should (string-match-p "‥9" (decknix--hub-discussion-icon
                                '((total_threads . 10) (human_unresolved . 1))))))

(ert-deftest dk-lc--no-discussion-shows-nothing ()
  (should (equal "" (decknix--hub-discussion-icon '((total_threads . 0))))))

(ert-deftest dk-lc--unresolved-threads-are-not-counted-twice ()
  "They have their own marker and are a different fact: one is a blocker,
the other is settled context."
  (should (equal "" (decknix--hub-discussion-icon
                     '((total_threads . 2) (human_unresolved . 2))))))

(ert-deftest dk-lc--settled-discussion-is-dim ()
  "Context, not a call to act."
  (should (eq 'shadow (get-text-property
                       0 'face (decknix--hub-discussion-icon
                                '((total_threads . 3)))))))

(ert-deftest dk-lc--awaiting-my-reply-is-shown ()
  "`needs_reply\=' means the last word was somebody else\='s.  Ten of eleven
PRs carried it and not one showed anything."
  (should (decknix--hub-awaiting-my-reply-p '((needs_reply . t))))
  (should (string-match-p "↩" (decknix--hub-reply-icon '((needs_reply . t))))))

(ert-deftest dk-lc--not-awaiting-a-reply-shows-nothing ()
  "#256 was the one PR of eleven not waiting on me, and that difference
was invisible."
  (should (equal "" (decknix--hub-reply-icon '((needs_reply . nil))))))

(ert-deftest dk-lc--awaiting-my-reply-is-amber ()
  "It is my move."
  (should (eq 'warning (get-text-property
                        0 'face (decknix--hub-reply-icon '((needs_reply . t)))))))

(provide 'decknix-hub-lifecycle-test)
;;; decknix-hub-lifecycle-test.el ends here
