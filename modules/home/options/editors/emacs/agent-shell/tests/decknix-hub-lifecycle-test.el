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


;; --- one shape family, colour always the build ------------------------

(defun dk-lc--boldp (icon)
  (let ((f (get-text-property 0 'face icon)))
    (and (listp f) (eq 'bold (plist-get f :weight)))))

(ert-deftest dk-lc--shape-says-what-kind-of-thing-it-is ()
  "Worktree, draft, open, closed, conflict -- one family, so the full
circle can no longer mean both an approved PR and an active worktree."
  (let ((shapes (mapcar #'decknix-lifecycle-shape
                        '(worktree-new worktree draft-pr open closed conflict))))
    (should (equal shapes (delete-dups (copy-sequence shapes))))))

(ert-deftest dk-lc--an-open-pr-is-a-full-circle ()
  (should (equal "●" (dk-lc--glyph (decknix--hub-primary-status-icon
                                    '((review_decision . "REVIEW_REQUIRED")
                                      (ci . ((status . "pass"))))
                                    'wip)))))

(ert-deftest dk-lc--a-draft-is-a-half-circle ()
  "Half way to an open PR, one stage past a worktree."
  (should (equal "◐" (dk-lc--glyph (decknix--hub-primary-status-icon
                                    '((draft . t) (ci . ((status . "pass"))))
                                    'wip)))))

(ert-deftest dk-lc--a-conflict-is-a-marker-not-a-shape ()
  "As a shape it REPLACED how far along the PR was, so a conflicted draft
and a conflicted open PR rendered identically.  As a marker both facts
survive."
  (should (string-match-p "!" (decknix--hub-conflict-icon
                               '((mergeable . "CONFLICTING")))))
  (should (equal "" (decknix--hub-conflict-icon '((mergeable . "MERGEABLE"))))))

(ert-deftest dk-lc--a-conflicted-draft-still-reads-as-a-draft ()
  (should (equal "◐" (dk-lc--glyph (decknix--hub-primary-status-icon
                                    '((draft . t) (mergeable . "CONFLICTING"))
                                    'wip)))))

(ert-deftest dk-lc--a-conflicted-open-pr-still-reads-as-open ()
  (should (equal "●" (dk-lc--glyph (decknix--hub-primary-status-icon
                                    '((mergeable . "CONFLICTING")) 'wip)))))

(ert-deftest dk-lc--a-conflict-does-not-recolour-the-build ()
  "A conflicted PR can build perfectly well and still be unmergeable, so
the colour keeps reporting the build and the marker carries the rest."
  (should (eq 'success (dk-lc--face (decknix--hub-primary-status-icon
                                     '((mergeable . "CONFLICTING")
                                       (ci . ((status . "pass"))))
                                     'wip)))))

(ert-deftest dk-lc--the-conflict-marker-is-red ()
  "Nothing lands until the author rebases."
  (should (eq 'error (get-text-property
                      0 'face (decknix--hub-conflict-icon
                               '((mergeable . "CONFLICTING")))))))

(ert-deftest dk-lc--a-closed-pr-is-a-square ()
  (should (equal "■" (dk-lc--glyph (decknix--hub-primary-status-icon
                                    '((state . "MERGED")) 'wip)))))

(ert-deftest dk-lc--a-happy-build-is-green-whatever-the-shape ()
  "The expectation the previous scheme broke: colour meant whose move, so
a passing build on an unreviewed PR rendered grey."
  (dolist (item '(((review_decision . "REVIEW_REQUIRED") (ci . ((status . "pass"))))
                  ((draft . t) (ci . ((status . "pass"))))))
    (should (eq 'success (dk-lc--face (decknix--hub-primary-status-icon item 'wip))))))

(ert-deftest dk-lc--a-building-pr-is-yellow ()
  (should (eq 'warning (dk-lc--face (decknix--hub-primary-status-icon
                                     '((ci . ((status . "running")))) 'wip)))))

(ert-deftest dk-lc--a-failing-build-is-red ()
  (should (eq 'error (dk-lc--face (decknix--hub-primary-status-icon
                                   '((ci . ((status . "fail")))) 'wip)))))

(ert-deftest dk-lc--no-ci-at-all-is-grey ()
  "Rare -- 2 PRs of 42 measured -- and genuinely unknown rather than fine."
  (should (eq 'shadow (dk-lc--face (decknix--hub-primary-status-icon
                                    '((review_decision . "REVIEW_REQUIRED"))
                                    'wip)))))

(ert-deftest dk-lc--approved-is-bold ()
  "Shape says what KIND of thing it is and colour how its build goes, so
approval rides on the one channel left."
  (should (dk-lc--boldp (decknix--hub-primary-status-icon
                         '((approvers . ("x")) (ci . ((status . "pass")))) 'wip))))

(ert-deftest dk-lc--unapproved-is-not-bold ()
  (should-not (dk-lc--boldp (decknix--hub-primary-status-icon
                             '((review_decision . "REVIEW_REQUIRED")
                               (ci . ((status . "pass")))) 'wip))))

(ert-deftest dk-lc--approved-and-still-building-says-both ()
  "The case with no representation when one channel carried both facts:
bold says approved, yellow says building."
  (let ((icon (decknix--hub-primary-status-icon
               '((approvers . ("x")) (ci . ((status . "running")))) 'wip)))
    (should (equal "●" (dk-lc--glyph icon)))
    (should (dk-lc--boldp icon))))

(ert-deftest dk-lc--approved-with-a-failing-build-stays-red-and-bold ()
  "Both facts survive: it IS approved, and it does NOT build."
  (let ((icon (decknix--hub-primary-status-icon
               '((approvers . ("x")) (ci . ((status . "fail")))) 'wip)))
    (should (dk-lc--boldp icon))))

(ert-deftest dk-lc--changes-requested-keeps-its-own-shape ()
  "A blocker, not a degree of progress."
  (should (equal "⊖" (dk-lc--glyph (decknix--hub-primary-status-icon
                                    '((review_decision . "CHANGES_REQUESTED"))
                                    'wip)))))

(ert-deftest dk-lc--colour-no-longer-depends-on-whose-pr-it-is ()
  "Which court it is in is carried by the SECTION."
  (let ((item '((review_decision . "REVIEW_REQUIRED") (ci . ((status . "pass"))))))
    (should (eq (dk-lc--face (decknix--hub-primary-status-icon item 'wip))
                (dk-lc--face (decknix--hub-primary-status-icon item 'review))))))

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


;; --- an approval a push has invalidated -------------------------------

(ert-deftest dk-lc--a-push-after-the-review-unapproves-it ()
  "Reported: PRs read as approved while GitHub disagreed, the approval
having been invalidated by updates pushed since.

GitHub only formally DISMISSES a review when branch protection says to,
so `approvers\=' can still name somebody while the approval means nothing.
`review_stale\=' is the hub\='s own signal -- a commit landed after the
latest review -- and it was not consulted at all."
  (should-not (decknix--hub-pr-approved-p
               '((approvers . ("abatten187")) (review_stale . t)))))

(ert-deftest dk-lc--a-stale-decision-is-also-not-an-approval ()
  (should-not (decknix--hub-pr-approved-p
               '((review_decision . "APPROVED") (review_stale . t)))))

(ert-deftest dk-lc--a-fresh-approval-still-counts ()
  "The guard must not swallow real approvals."
  (should (decknix--hub-pr-approved-p
           '((approvers . ("x")) (review_stale . nil)))))

(ert-deftest dk-lc--a-stale-approval-is-not-silently-unapproved ()
  "The work HAS been reviewed; what it needs is a RE-review, not a first
one.  Dropping it to plain unapproved would lose that."
  (should (decknix--hub-pr-stale-approval-p
           '((approvers . ("x")) (review_stale . t))))
  (should (string-match-p "↻" (decknix--hub-stale-approval-icon
                               '((approvers . ("x")) (review_stale . t))))))

(ert-deftest dk-lc--a-never-reviewed-pr-is-not-a-stale-approval ()
  "Stale means an approval was invalidated, not that none exists."
  (should-not (decknix--hub-pr-stale-approval-p '((review_stale . t))))
  (should (equal "" (decknix--hub-stale-approval-icon '((review_stale . t))))))

(ert-deftest dk-lc--a-stale-approval-is-not-bold ()
  "Weight means approved, and this one no longer is."
  (let ((icon (decknix--hub-primary-status-icon
               '((approvers . ("x")) (review_stale . t)
                 (ci . ((status . "pass"))))
               'wip)))
    (should-not (dk-lc--boldp icon))))

(provide 'decknix-hub-lifecycle-test)
;;; decknix-hub-lifecycle-test.el ends here
